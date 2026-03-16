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

def load_config() -> dict:
    """Load aau.yaml from project root."""
    # Find aau.yaml by walking up from script location or CWD
    search_dirs = [Path.cwd(), Path(__file__).resolve().parent.parent]
    for start in search_dirs:
        d = start
        while d != d.parent:
            cfg = d / "aau.yaml"
            if cfg.exists():
                import yaml
                return yaml.safe_load(cfg.read_text()), d
            d = d.parent
    # Fallback: try environment
    cfg_path = os.environ.get("AAU_CONFIG_FILE")
    if cfg_path and Path(cfg_path).exists():
        import yaml
        p = Path(cfg_path)
        return yaml.safe_load(p.read_text()), p.parent
    print("ERROR: aau.yaml not found", file=sys.stderr)
    sys.exit(1)


def load_config_simple() -> tuple[dict, Path]:
    """Load config without yaml dependency (JSON-subset fallback)."""
    try:
        return load_config()
    except ImportError:
        # yaml not available — parse with python3 subprocess
        search = Path.cwd()
        while search != search.parent:
            cfg = search / "aau.yaml"
            if cfg.exists():
                result = subprocess.run(
                    ["python3", "-c",
                     f"import yaml,json; print(json.dumps(yaml.safe_load(open('{cfg}'))))"],
                    capture_output=True, text=True
                )
                if result.returncode == 0:
                    return json.loads(result.stdout), search
            search = search.parent
        print("ERROR: aau.yaml not found or PyYAML not installed", file=sys.stderr)
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
    stale_threshold = health_cfg.get("stale_threshold", 1500)

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

    def rule_check(log_tail: str, inprogress: list, log_path: Path) -> dict:
        log_lower = log_tail.lower()
        for p in critical_patterns:
            if p.lower() in log_lower:
                return {"problem": True, "severity": "critical",
                        "summary": f"Agent stopped: {p[:40]}", "reason": f"rule: {p}"}
        if inprogress and log_path.exists():
            age = time.time() - log_path.stat().st_mtime
            if age > stale_threshold:
                mins = int(age // 60)
                return {"problem": True, "severity": "critical",
                        "summary": f"IN_PROGRESS but no log update for {mins}min",
                        "reason": f"stale: {mins}min"}
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

    # ─── Run checks ──────────────────────────────────────────────────────
    log("=== health_monitor start ===")
    jlog("info", "start")
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

        result = rule_check(log_tail, inprogress, log_path)
        if result["problem"]:
            norm_reason = "stale" if result["reason"].startswith("stale") else result["reason"]
            notified_key = f"{member}_notified"
            if state.get(notified_key) != norm_reason:
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
