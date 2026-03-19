#!/usr/bin/env python3
"""
health_monitor.py — Agent health monitoring with rule-based detection + optional LLM.
Configurable via aau.yaml. No hardcoded paths or team members.
"""

import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone, timedelta
from pathlib import Path

# ─── Config loading ──────────────────────────────────────────────────────

def _parse_yaml_simple(text: str) -> dict:
    """Minimal YAML parser for aau.yaml — no external dependencies.
    Handles: top-level sections, nested keys, list items (- value, - key: value)."""
    result = {}
    section = None       # e.g. "project", "runtime", "team"
    subsection = None    # e.g. "members", "max_turns", "critical_patterns"
    current_member = None

    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        indent = len(line) - len(line.lstrip())

        # Top-level section (indent 0)
        if indent == 0 and stripped.endswith(":") and not stripped.startswith("-"):
            section = stripped[:-1].strip()
            subsection = None
            current_member = None
            if section not in result:
                result[section] = {}
            continue

        if section is None:
            continue

        # List item
        if stripped.startswith("- "):
            item = stripped[2:].strip()
            if subsection == "members":
                # "- name: foo"
                if ":" in item:
                    k, v = item.split(":", 1)
                    k, v = k.strip(), v.strip().strip('"').strip("'")
                    current_member = {"name": v} if k == "name" else {k: v}
                    if "members" not in result.get(section, {}):
                        result[section]["members"] = []
                    result[section]["members"].append(current_member)
            elif subsection:
                # Simple list: "- "some pattern""
                val = item.strip('"').strip("'")
                target = result.get(section, {})
                if subsection not in target:
                    target[subsection] = []
                if isinstance(target[subsection], list):
                    target[subsection].append(val)
            continue

        # Continuation of member dict (role:, timeout:, etc.)
        if current_member is not None and indent >= 6 and ":" in stripped:
            k, v = stripped.split(":", 1)
            k, v = k.strip(), v.strip().strip('"').strip("'")
            current_member[k] = v
            continue

        if ":" not in stripped:
            continue

        key, _, value = stripped.partition(":")
        key = key.strip()
        value = value.strip().strip('"').strip("'")

        if not value:
            # Subsection
            subsection = key
            current_member = None
            if isinstance(result.get(section), dict) and key not in result[section]:
                # Known list subsections get initialized as lists
                if key in ("members", "critical_patterns", "warning_patterns"):
                    result[section][key] = []
                else:
                    result[section][key] = {}
            continue

        # Regular key: value
        current_member = None
        if subsection and isinstance(result.get(section), dict):
            sub = result[section].get(subsection)
            if isinstance(sub, dict):
                sub[key] = value
            elif isinstance(sub, list):
                # Key after a list subsection — belongs to section, not subsection
                subsection = None
                result[section][key] = value
            elif sub is None:
                result[section][subsection] = {key: value}
        elif isinstance(result.get(section), dict):
            result[section][key] = value

    # Post-process: ensure list fields are lists
    for section_name in ["health"]:
        sec = result.get(section_name, {})
        for list_key in ["critical_patterns", "warning_patterns"]:
            v = sec.get(list_key)
            if isinstance(v, dict):
                sec[list_key] = list(v.values())
            elif isinstance(v, str):
                sec[list_key] = [v]
            elif v is None:
                sec[list_key] = []

    return result


def load_config_simple() -> tuple[dict, Path]:
    """Load aau.yaml without any external dependencies."""
    search_dirs = [Path.cwd(), Path(__file__).resolve().parent.parent]
    for start in search_dirs:
        d = start
        while d != d.parent:
            cfg_path = d / "aau.yaml"
            if cfg_path.exists():
                return _parse_yaml_simple(cfg_path.read_text()), d
            d = d.parent
    # Fallback: environment variable
    cfg_env = os.environ.get("AAU_CONFIG_FILE")
    if cfg_env and Path(cfg_env).exists():
        p = Path(cfg_env)
        return _parse_yaml_simple(p.read_text()), p.parent
    print("ERROR: aau.yaml not found", file=sys.stderr)
    sys.exit(1)


# ─── Main ────────────────────────────────────────────────────────────────

def main() -> None:
    cfg, project_root = load_config_simple()

    prefix = cfg.get("runtime", {}).get("prefix", "aau")
    tmp_dir = Path(cfg.get("runtime", {}).get("tmp_dir", "/tmp"))
    members = [m["name"] for m in cfg.get("team", {}).get("members", [])]
    health_cfg = cfg.get("health", {})
    llm_cfg = cfg.get("local_llm", {})

    critical_patterns = health_cfg.get("critical_patterns", [
        "Reached max turns", "permission denied", "Edit not allowed"
    ])
    warning_patterns = health_cfg.get("warning_patterns", [
        "TESTS FAILED", "assert failed", "Error: "
    ])
    stale_threshold = int(health_cfg.get("stale_threshold", 1500))
    relaunch_window_min = int(health_cfg.get("relaunch_window_min", 60))
    relaunch_critical_count = int(health_cfg.get("relaunch_critical_count", 5))

    log_file = tmp_dir / f"{prefix}_health_monitor.log"
    jsonl_file = tmp_dir / f"{prefix}_health_monitor.jsonl"
    inbox = project_root / "team/director/inbox.md"
    state_file = tmp_dir / f"{prefix}_health_state.json"
    trigger_file = tmp_dir / f"{prefix}_trigger_director"

    def log(msg: str) -> None:
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(log_file, "a") as f:
            f.write(f"[{ts}] {msg}\n")

    def jlog(level: str, event: str, **kwargs) -> None:
        record = {
            "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "level": level, "event": event, **kwargs,
        }
        with open(jsonl_file, "a") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")

    def load_state() -> dict:
        try:
            return json.loads(state_file.read_text())
        except Exception:
            return {}

    def save_state(state: dict) -> None:
        state_file.write_text(json.dumps(state))

    def append_inbox(entry: str) -> None:
        with open(inbox, "a") as f:
            f.write(entry)

    def set_director_trigger(summary: str) -> None:
        if trigger_file.exists():
            age = time.time() - trigger_file.stat().st_mtime
            if age < 300:
                with open(trigger_file, "a") as f:
                    f.write(f"\n+ [health] {summary[:60]}")
                return
        trigger_file.write_text(f"health_alert=1\n{summary[:60]}")

    def get_log_tail(path: Path, lines: int = 50) -> str:
        if not path.exists():
            return ""
        try:
            all_lines = path.read_text().splitlines()
            return "\n".join(all_lines[-lines:])
        except Exception:
            return ""

    def count_recent_launches(log_path: Path, window_min: int = 60) -> tuple[int, int]:
        """Count launches and completions within the recent window."""
        if not log_path.exists():
            return 0, 0
        cutoff = datetime.now() - timedelta(minutes=window_min)
        launches, completes = 0, 0
        try:
            for line in log_path.read_text().splitlines():
                m = re.match(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]", line)
                if not m:
                    continue
                try:
                    ts = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
                except ValueError:
                    continue
                if ts < cutoff:
                    continue
                if "claude_launch" in line or "trigger consumed" in line or "launching Claude" in line:
                    launches += 1
                elif "session_succeeded" in line or "agent run complete" in line:
                    completes += 1
        except Exception:
            pass
        return launches, completes

    def scan_outfiles_for_errors(member: str) -> str:
        """Scan /tmp/{prefix}_agent_{member}_*.out for critical errors."""
        import glob as glob_mod
        pattern = f"{tmp_dir}/{prefix}_agent_{member}_*.out"
        now = time.time()
        found_error = ""
        for path_str in glob_mod.glob(pattern):
            p = Path(path_str)
            try:
                age = now - p.stat().st_mtime
                content = p.read_text(errors="replace")
                for cp in critical_patterns:
                    if cp.lower() in content.lower():
                        if not found_error:
                            found_error = f"{cp} (outfile: {p.name})"
                        break
                if age > 3600:
                    p.unlink(missing_ok=True)
            except Exception:
                pass
        return found_error

    def rule_check(log_tail: str, inprogress: list, log_path: Path, member: str = "") -> dict:
        log_lower = log_tail.lower()

        # Check outfiles for errors (catches errors not in main log)
        if member:
            out_error = scan_outfiles_for_errors(member)
            if out_error:
                return {"problem": True, "severity": "critical",
                        "summary": f"Session error: {out_error[:60]}", "reason": f"outfile: {out_error[:40]}"}

        # Relaunch loop detection
        if log_path.exists():
            launches, completes = count_recent_launches(log_path, relaunch_window_min)
            if launches >= relaunch_critical_count and completes == 0:
                return {"problem": True, "severity": "critical",
                        "summary": f"Relaunch loop: {launches} launches, 0 completions in {relaunch_window_min}min",
                        "reason": f"relaunch_loop: {launches}launches/{completes}completes"}

        # Critical pattern matching
        for p in critical_patterns:
            if p.lower() in log_lower:
                return {"problem": True, "severity": "critical",
                        "summary": f"Agent stopped: {p[:40]}", "reason": f"rule: {p}"}

        # Stale log detection
        if inprogress and log_path.exists():
            age = time.time() - log_path.stat().st_mtime
            if age > stale_threshold:
                mins = int(age // 60)
                return {"problem": True, "severity": "critical",
                        "summary": f"IN_PROGRESS but no log update for {mins}min",
                        "reason": f"stale: {mins}min"}

        # Warning patterns
        for p in warning_patterns:
            if p.lower() in log_lower:
                return {"problem": True, "severity": "warning",
                        "summary": f"Warning: {p[:40]}", "reason": f"warn: {p}"}
        return {"problem": False, "severity": "ok", "summary": "OK", "reason": "ok"}

    def try_self_heal(member: str, reason: str) -> tuple[bool, str]:
        lock_path = tmp_dir / f"{prefix}_agent_{member}.lock"
        trigger_path = tmp_dir / f"{prefix}_trigger_{member}"
        actions = []
        if lock_path.exists():
            try:
                pid = int(lock_path.read_text().strip())
                os.kill(pid, 0)
                return False, "lock_pid_alive"
            except (ValueError, ProcessLookupError):
                lock_path.unlink(missing_ok=True)
                actions.append("stale_lock_removed")
        if "rule" in reason and any(k in reason for k in ["max turns", "permission"]):
            trigger_path.write_text("pending=1 inprogress=0")
            actions.append("trigger_reset")
        elif "stale" in reason:
            trigger_path.write_text("pending=0 inprogress=1")
            actions.append("trigger_reset_stale")
        if actions:
            jlog("info", "self_heal", member=member, actions=actions)
            return True, ", ".join(actions)
        return False, "no_action"

    def read_jsonl_events(path: Path, minutes: int = 30) -> list[dict]:
        if not path.exists():
            return []
        cutoff = datetime.now(timezone.utc) - timedelta(minutes=minutes)
        events = []
        try:
            for line in path.read_text().splitlines():
                try:
                    ev = json.loads(line)
                    ts = datetime.fromisoformat(ev.get("ts", "").replace("Z", "+00:00"))
                    if ts >= cutoff:
                        events.append(ev)
                except Exception:
                    continue
        except Exception:
            pass
        return events

    # ─── Quiet hours check ────────────────────────────────────────────────
    quiet_start = int(cfg.get("director", {}).get("quiet_hours_start", 0))
    quiet_end = int(cfg.get("director", {}).get("quiet_hours_end", 8))
    current_hour = datetime.now().hour
    if quiet_start <= current_hour < quiet_end:
        # Still log but don't create alerts during quiet hours
        pass  # health_monitor runs but doesn't write to inbox

    in_quiet_hours = quiet_start <= current_hour < quiet_end

    # ─── Run checks ──────────────────────────────────────────────────────
    log("=== health_monitor start ===")
    jlog("info", "start")
    if in_quiet_hours:
        log("  quiet hours — monitoring only, no alerts")
        jlog("info", "quiet_hours", hour=current_hour)
    state = load_state()
    alerts = []

    # Check director JSONL logs
    for component in ["director", "director_autonomous"]:
        jsonl_path = tmp_dir / f"{prefix}_agent_{component}.jsonl"
        if component == "director_autonomous":
            jsonl_path = tmp_dir / f"{prefix}_{component}.jsonl"
        events = read_jsonl_events(jsonl_path, minutes=30)
        failures = [e for e in events if e.get("msg") == "session_failed"]
        if len(failures) >= 2:
            issue = f"{component}: {len(failures)} failures in 30min"
            log(f"  {issue}")
            alerts.append(issue)

    # Check each member
    for member in members:
        log_path = tmp_dir / f"{prefix}_agent_{member}.log"
        tasks_path = project_root / f"team/{member}/tasks.md"
        log_tail = get_log_tail(log_path)
        inprogress = []
        if tasks_path.exists():
            inprogress = [l.strip() for l in tasks_path.read_text().splitlines()
                          if "[IN_PROGRESS]" in l]

        if not log_tail:
            if inprogress:
                alerts.append(f"{member}: IN_PROGRESS but no log")
            continue

        result = rule_check(log_tail, inprogress, log_path, member)
        if result["problem"]:
            norm_reason = "stale" if result["reason"].startswith("stale") else result["reason"]
            notified_key = f"{member}_notified"
            if in_quiet_hours:
                # During quiet hours: log but don't write to inbox or trigger director
                log(f"  {member}: {result['severity']} — {result['summary']} (quiet hours, suppressed)")
                jlog("info", "problem_suppressed_quiet", member=member, severity=result["severity"])
                state[notified_key] = norm_reason
            elif state.get(notified_key) != norm_reason:
                summary = result["summary"]
                severity = result["severity"]
                log(f"  {member}: {severity} — {summary}")
                jlog("warn" if severity == "warning" else "error",
                     "problem", member=member, severity=severity, reason=result["reason"])

                heal_note = ""
                if severity == "critical":
                    healed, detail = try_self_heal(member, result["reason"])
                    heal_note = f"\n**Auto-heal**: {detail}" if healed else f"\n**Auto-heal**: failed ({detail})"

                icon = "🔴" if severity == "critical" else "🟡"
                dt = datetime.now().strftime("%Y-%m-%d %H:%M")
                entry = f"\n## [{dt}] {icon} Health: {member} [{severity.upper()}]\n**Issue**: {summary}{heal_note}\nステータス: UNREAD\n\n"
                append_inbox(entry)
                alerts.append(f"{member}: {summary}")
                state[notified_key] = norm_reason
                if severity == "critical":
                    set_director_trigger(f"[{member}] {summary}")
        else:
            state.pop(f"{member}_notified", None)

        state[f"{member}_fp"] = log_tail[-200:]

    if alerts:
        log(f"  → {len(alerts)} alert(s)")
        jlog("warn", "done", alert_count=len(alerts))
    else:
        log("  → all healthy")
        jlog("info", "done", alert_count=0)

    save_state(state)
    log("=== done ===")


if __name__ == "__main__":
    main()
