#!/usr/bin/env python3
"""AAU Web Server — Multi-project Monitoring Dashboard + Setup Wizard."""

import http.server
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time
import threading
import webbrowser
from datetime import datetime, timezone, timedelta

PORT = 7700
AAU_ROOT = pathlib.Path(__file__).resolve().parent.parent
WEB_DIR = AAU_ROOT / "web"
CLAUDE_DIR = pathlib.Path.home() / ".claude"
STATE_FILE = WEB_DIR / ".last_project"

# ─── Multi-project state ─────────────────────────────────────
_projects = {}  # key -> project_data
_projects_lock = threading.Lock()
_active_project = None  # key of "primary" project for settings


def _parse_project(project_path: pathlib.Path) -> dict | None:
    """Parse a single project's aau.yaml and return project data."""
    yaml_file = project_path / "aau.yaml"
    if not yaml_file.exists():
        return None
    text = yaml_file.read_text()

    proj_name = None
    proj_prefix = None
    in_project = False
    in_runtime = False
    for line in text.splitlines():
        stripped = line.strip()
        if line and not line[0].isspace() and stripped.endswith(":"):
            in_project = stripped == "project:"
            in_runtime = stripped == "runtime:"
            continue
        if in_project and stripped.startswith("name:"):
            proj_name = stripped.split(":", 1)[1].strip().strip('"')
        if in_runtime and stripped.startswith("prefix:"):
            proj_prefix = stripped.split(":", 1)[1].strip().strip('"')

    members = []
    in_members = False
    for line in text.splitlines():
        stripped = line.strip()
        if "members:" in stripped and not stripped.startswith("#"):
            in_members = True
            continue
        if in_members:
            if stripped.startswith("- name:"):
                members.append({"name": stripped.split(":", 1)[1].strip()})
            elif stripped.startswith("role:") and members:
                members[-1]["role"] = stripped.split(":", 1)[1].strip().strip('"')
            elif stripped and not stripped.startswith("-") and not stripped.startswith(
                ("role:", "timeout:", "max_turns:", "interval:", "tools:")
            ):
                in_members = False

    name = proj_name or project_path.name
    jobs = [
        f"ai.{name}.task-monitor",
        f"ai.{name}.health-monitor",
        f"ai.{name}.director-autonomous",
        f"ai.{name}.director-responder",
    ]
    for m in members:
        jobs.append(f"ai.{name}.agent-{m['name']}")

    return {
        "path": str(project_path),
        "name": name,
        "prefix": proj_prefix or "",
        "members": members,
        "launchd_jobs": jobs,
    }


def load_project(project_path: str) -> str | None:
    """Load a single project, return its key."""
    p = pathlib.Path(project_path)
    data = _parse_project(p)
    if not data:
        return None
    key = data["name"]
    with _projects_lock:
        _projects[key] = data
    print(f"  Loaded: {key} ({p}) — {[m['name'] for m in data['members']]}")
    return key


def scan_all_projects():
    """Scan ~/git/ for all directories containing aau.yaml."""
    git_root = pathlib.Path.home() / "git"
    if not git_root.exists():
        return
    for candidate in sorted(git_root.iterdir()):
        if candidate.is_dir() and (candidate / "aau.yaml").exists():
            load_project(str(candidate))


def _auto_detect_project() -> str | None:
    """Auto-detect a single project on startup (legacy compat)."""
    if STATE_FILE.exists():
        saved = STATE_FILE.read_text().strip()
        if saved and pathlib.Path(saved).joinpath("aau.yaml").exists():
            return saved
    git_root = pathlib.Path.home() / "git"
    if git_root.exists():
        candidates = sorted(
            git_root.glob("*/aau.yaml"), key=lambda f: f.stat().st_mtime, reverse=True
        )
        if candidates:
            return str(candidates[0].parent)
    return None


# ─── System Metrics (psutil optional) ────────────────────────
_prev_net = None


def get_system_metrics():
    global _prev_net
    try:
        import psutil
    except ImportError:
        return {"ts": datetime.now().strftime("%H:%M:%S"), "error": "psutil not installed"}

    cpu = psutil.cpu_percent(interval=0.5)
    mem = psutil.virtual_memory()
    disk = psutil.disk_usage("/")
    net = psutil.net_io_counters()

    sent_rate = recv_rate = 0
    if _prev_net:
        sent_rate = round((net.bytes_sent - _prev_net.bytes_sent) / 2.0 / 1024, 1)
        recv_rate = round((net.bytes_recv - _prev_net.bytes_recv) / 2.0 / 1024, 1)
    _prev_net = net

    top_procs = []
    for p in sorted(
        psutil.process_iter(["pid", "name", "cpu_percent", "memory_percent"]),
        key=lambda p: p.info.get("cpu_percent") or 0,
        reverse=True,
    )[:8]:
        try:
            top_procs.append({
                "pid": p.info["pid"],
                "name": p.info["name"],
                "cpu": round(p.info["cpu_percent"] or 0, 1),
                "mem": round(p.info["memory_percent"] or 0, 1),
            })
        except Exception:
            pass

    return {
        "ts": datetime.now().strftime("%H:%M:%S"),
        "cpu": cpu,
        "cpu_count": psutil.cpu_count(),
        "mem_used": round(mem.used / 1024**3, 2),
        "mem_total": round(mem.total / 1024**3, 2),
        "mem_percent": mem.percent,
        "disk_used": round(disk.used / 1024**3, 1),
        "disk_total": round(disk.total / 1024**3, 1),
        "disk_percent": disk.percent,
        "net_sent_total": round(net.bytes_sent / 1024**2, 1),
        "net_recv_total": round(net.bytes_recv / 1024**2, 1),
        "net_sent_rate": sent_rate,
        "net_recv_rate": recv_rate,
        "top_procs": top_procs,
    }


# ─── Token Stats ─────────────────────────────────────────────
MODEL_PRICING = {
    "claude-opus-4-6":           {"input": 15.0, "output": 75.0, "cache_read": 1.50, "cache_write": 18.75},
    "claude-sonnet-4-6":         {"input": 3.0,  "output": 15.0, "cache_read": 0.30, "cache_write": 3.75},
    "claude-haiku-4-5-20251001": {"input": 0.80, "output": 4.0,  "cache_read": 0.08, "cache_write": 1.00},
    "claude-haiku-4-5":          {"input": 0.80, "output": 4.0,  "cache_read": 0.08, "cache_write": 1.00},
}

JST = timezone(timedelta(hours=9))

_token_cache = {"data": None, "at": 0}
_token_lock = threading.Lock()


def _calc_cost(model, inp, out, cache_read, cache_write):
    p = MODEL_PRICING.get(model)
    if not p:
        return None
    M = 1_000_000
    return round(
        inp * p["input"] / M + out * p["output"] / M +
        cache_read * p["cache_read"] / M + cache_write * p["cache_write"] / M, 4
    )


def _today_start_utc():
    now_jst = datetime.now(JST)
    return now_jst.replace(hour=0, minute=0, second=0, microsecond=0).astimezone(timezone.utc)


def _parse_ts(ts_raw):
    try:
        if isinstance(ts_raw, (int, float)):
            return datetime.fromtimestamp(ts_raw / 1000, tz=timezone.utc)
        return datetime.fromisoformat(str(ts_raw).replace("Z", "+00:00"))
    except Exception:
        return None


def _compute_token_stats():
    import glob as g
    today_start = _today_start_utc()
    cutoff = today_start.timestamp()
    by_model = {}

    # Build project dir mappings
    with _projects_lock:
        project_dirs = {}
        for key, proj in _projects.items():
            pp = proj.get("path", "")
            if pp:
                project_dirs[key] = pp.lstrip("/").replace("/", "-")

    by_model_per_project = {k: {} for k in project_dirs}
    session_ids = set()
    session_ids_per_project = {k: set() for k in project_dirs}

    files = g.glob(str(CLAUDE_DIR / "projects" / "**" / "*.jsonl"), recursive=True)
    for f in files:
        try:
            if os.path.getmtime(f) < cutoff:
                continue
            # Determine which project this file belongs to
            file_projects = []
            for key, dir_name in project_dirs.items():
                if dir_name and dir_name in f:
                    file_projects.append(key)

            with open(f, errors="ignore") as fp:
                for line in fp:
                    try:
                        d = json.loads(line)
                        msg = d.get("message", {})
                        if not isinstance(msg, dict) or msg.get("role") != "assistant":
                            continue
                        usage = msg.get("usage")
                        if not usage:
                            continue
                        ts = _parse_ts(d.get("timestamp"))
                        if ts is None or ts < today_start:
                            continue
                        model = msg.get("model", "unknown")
                        sid = d.get("sessionId")
                        inp = usage.get("input_tokens", 0)
                        out = usage.get("output_tokens", 0)
                        cr = usage.get("cache_read_input_tokens", 0)
                        cw = usage.get("cache_creation_input_tokens", 0)

                        # Global total
                        if model not in by_model:
                            by_model[model] = {"input": 0, "output": 0, "cache_read": 0, "cache_creation": 0, "calls": 0}
                        m = by_model[model]
                        m["input"] += inp
                        m["output"] += out
                        m["cache_read"] += cr
                        m["cache_creation"] += cw
                        m["calls"] += 1
                        if sid:
                            session_ids.add(sid)

                        # Per-project
                        for pk in file_projects:
                            pmodel = by_model_per_project[pk]
                            if model not in pmodel:
                                pmodel[model] = {"input": 0, "output": 0, "cache_read": 0, "cache_creation": 0, "calls": 0}
                            mp = pmodel[model]
                            mp["input"] += inp
                            mp["output"] += out
                            mp["cache_read"] += cr
                            mp["cache_creation"] += cw
                            mp["calls"] += 1
                            if sid:
                                session_ids_per_project[pk].add(sid)
                    except Exception:
                        pass
        except Exception:
            pass

    def _build_totals(model_dict, sid_set):
        totals = {"input": 0, "output": 0, "cache_read": 0, "cache_creation": 0}
        models_list = []
        for model, m in sorted(model_dict.items()):
            cost = _calc_cost(model, m["input"], m["output"], m["cache_read"], m["cache_creation"])
            for k in totals:
                totals[k] += m[k]
            models_list.append({
                "model": model, "input": m["input"], "output": m["output"],
                "cache_read": m["cache_read"], "cache_creation": m["cache_creation"],
                "calls": m["calls"], "cost_usd": cost,
            })
        totals["sessions"] = len(sid_set)
        totals["by_model"] = models_list
        return totals

    result = {"today": _build_totals(by_model, session_ids), "per_project": {}}
    for pk in project_dirs:
        result["per_project"][pk] = _build_totals(
            by_model_per_project[pk], session_ids_per_project[pk]
        )
    return result


def get_token_stats():
    with _token_lock:
        now = time.time()
        if _token_cache["data"] is None or now - _token_cache["at"] > 30:
            _token_cache["data"] = _compute_token_stats()
            _token_cache["at"] = now
        return _token_cache["data"]


# ─── Claude Processes ────────────────────────────────────────
def get_claude_processes():
    try:
        import psutil
    except ImportError:
        return []
    procs = []
    for p in psutil.process_iter(["pid", "name", "cmdline", "cpu_percent", "memory_percent", "create_time"]):
        try:
            name = p.info["name"] or ""
            cmdline = " ".join(p.info["cmdline"] or [])
            if "claude" not in name.lower() and "claude" not in cmdline.lower():
                continue
            if "grep" in cmdline:
                continue
            age_min = round((time.time() - p.info["create_time"]) / 60)
            procs.append({
                "pid": p.info["pid"], "name": name,
                "cpu": round(p.info["cpu_percent"] or 0, 1),
                "mem": round(p.info["memory_percent"] or 0, 1),
                "age_min": age_min,
            })
        except Exception:
            pass
    return procs


# ─── Per-project data functions ──────────────────────────────
def get_launchd_jobs(proj: dict) -> list:
    job_labels = list(proj.get("launchd_jobs", []))
    prefix = proj.get("prefix", "")
    name = proj.get("name", "")

    if not job_labels:
        return []

    try:
        out = subprocess.check_output(
            ["launchctl", "list"], stderr=subprocess.DEVNULL, timeout=5
        ).decode()
    except Exception:
        out = ""

    running = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            pid, status, label = parts
            running[label] = {"pid": pid, "status": status}

    jobs = []
    for label in job_labels:
        info = running.get(label, {})
        pid = info.get("pid", "-")
        is_running = pid != "-"
        short = label.replace(f"ai.{name}.", "") if name else label

        log_line = ""
        log_path = f"/tmp/{prefix}_{short.replace('-', '_')}.log" if prefix else ""
        try:
            if log_path and os.path.exists(log_path):
                result = subprocess.check_output(
                    ["tail", "-1", log_path], timeout=2
                ).decode().strip()
                log_line = result[-80:] if result else ""
        except Exception:
            pass

        jobs.append({
            "label": label, "short": short, "running": is_running,
            "pid": pid, "log": log_line,
        })
    return jobs


def get_task_status(proj: dict) -> list:
    project_path = proj.get("path")
    members = list(proj.get("members", []))
    if not project_path:
        return []

    result = []
    for m in members:
        name = m["name"]
        role = m.get("role", "")
        tasks_file = pathlib.Path(project_path) / "team" / name / "tasks.md"
        progress_file = pathlib.Path(project_path) / "team" / name / "progress.md"

        pending = in_progress = done = needs_evidence = blocked = 0
        try:
            if tasks_file.exists():
                content = tasks_file.read_text()
                for line in content.splitlines():
                    upper = line.upper()
                    if "[NEEDS_EVIDENCE]" in upper:
                        needs_evidence += 1
                    elif "[BLOCKED]" in upper:
                        blocked += 1
                    elif "[PENDING]" in upper:
                        pending += 1
                    elif "[IN_PROGRESS]" in upper:
                        in_progress += 1
                    elif "[DONE]" in upper:
                        done += 1
        except Exception:
            pass

        last_progress = ""
        try:
            if progress_file.exists():
                mtime = os.path.getmtime(str(progress_file))
                ago = int(time.time() - mtime)
                if ago < 60:
                    last_progress = f"{ago}s ago"
                elif ago < 3600:
                    last_progress = f"{ago // 60}m ago"
                else:
                    last_progress = f"{ago // 3600}h ago"
        except Exception:
            pass

        result.append({
            "name": name, "role": role,
            "pending": pending, "in_progress": in_progress, "done": done,
            "needs_evidence": needs_evidence, "blocked": blocked,
            "last_progress": last_progress,
        })
    return result


def get_inbox_entries(proj: dict) -> list:
    project_path = proj.get("path")
    if not project_path:
        return []

    inbox_file = pathlib.Path(project_path) / "team" / "director" / "inbox.md"
    if not inbox_file.exists():
        return []

    try:
        text = inbox_file.read_text()
    except Exception:
        return []

    entries = []
    current = None
    for line in text.splitlines():
        if line.startswith("## ["):
            if current:
                entries.append(current)
            header = line[3:].strip()
            current = {"header": header, "lines": [], "status": ""}
        elif current is not None:
            if line.startswith("ステータス:") or line.startswith("Status:"):
                current["status"] = line.split(":", 1)[1].strip()
            else:
                current["lines"].append(line)
    if current:
        entries.append(current)

    entries.reverse()
    return entries[:10]


def get_activity_feed(proj: dict) -> list:
    project_path = proj.get("path")
    members = [m["name"] for m in proj.get("members", [])]
    prefix = proj.get("prefix", "")

    if not project_path:
        return []

    events = []
    team_dir = pathlib.Path(project_path) / "team"

    # Task completion from output files
    for member in members:
        output_dir = team_dir / member / "output"
        if not output_dir.exists():
            continue
        try:
            for f in output_dir.iterdir():
                if f.is_file() and not f.name.startswith("."):
                    mtime = f.stat().st_mtime
                    events.append({"ts": mtime, "type": "done", "text": f"{member}: {f.name}"})
        except Exception:
            pass

    # Inbox events
    inbox_file = team_dir / "director" / "inbox.md"
    if inbox_file.exists():
        try:
            text = inbox_file.read_text()
            for line in text.splitlines():
                if line.startswith("## ["):
                    header = line[4:].strip()
                    bracket_end = header.find("]")
                    if bracket_end > 0:
                        ts_str = header[:bracket_end]
                        desc = header[bracket_end + 1:].strip()
                        try:
                            dt = datetime.strptime(ts_str, "%Y-%m-%d %H:%M")
                            dt = dt.replace(tzinfo=JST)
                            events.append({"ts": dt.timestamp(), "type": "slack", "text": desc[:80]})
                        except ValueError:
                            pass
        except Exception:
            pass

    # Agent JSONL logs
    if prefix:
        import glob as g
        for log_file in g.glob(f"/tmp/{prefix}_agent_*.jsonl"):
            try:
                member_name = pathlib.Path(log_file).stem.replace(f"{prefix}_agent_", "")
                with open(log_file, errors="ignore") as fp:
                    lines = fp.readlines()[-20:]
                for line in lines:
                    try:
                        d = json.loads(line)
                        evt = d.get("event") or d.get("msg", "")
                        ts = d.get("ts", 0)
                        if evt == "claude_launch":
                            events.append({"ts": ts, "type": "active", "text": f"{member_name}: Claude起動"})
                        elif evt in ("session_succeeded", "session_complete"):
                            events.append({"ts": ts, "type": "done", "text": f"{member_name}: セッション完了"})
                    except Exception:
                        pass
            except Exception:
                pass

        for log_type in ["director_autonomous", "director_responder"]:
            log_file = f"/tmp/{prefix}_{log_type}.jsonl"
            if os.path.exists(log_file):
                try:
                    with open(log_file, errors="ignore") as fp:
                        lines = fp.readlines()[-20:]
                    for line in lines:
                        try:
                            d = json.loads(line)
                            evt = d.get("event") or d.get("msg", "")
                            ts = d.get("ts", 0)
                            if evt == "claude_launch":
                                events.append({"ts": ts, "type": "active", "text": "director: Claude起動"})
                            elif evt in ("session_succeeded", "session_complete"):
                                action = d.get("action", "")
                                events.append({"ts": ts, "type": "done", "text": f"director: {action} 完了"})
                        except Exception:
                            pass
                except Exception:
                    pass

    def _ts_float(e):
        ts = e.get("ts", 0)
        if isinstance(ts, str):
            try:
                return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
            except Exception:
                return 0
        return float(ts) if ts else 0

    events.sort(key=_ts_float, reverse=True)
    for e in events[:50]:
        try:
            ts = _ts_float(e)
            if ts > 1e9:  # epoch seconds
                dt = datetime.fromtimestamp(ts, tz=JST)
            else:
                dt = datetime.now(JST)
            e["time"] = dt.strftime("%H:%M:%S")
            e["date"] = dt.strftime("%m/%d")
        except Exception:
            e["time"] = "–"
            e["date"] = "–"
    return events[:50]


# ─── Promised status ─────────────────────────────────────────
def get_promised_status(proj: dict) -> dict:
    project_path = proj.get("path")
    if not project_path:
        return {"pending": 0, "in_queue": 0, "done": 0}
    promised = pathlib.Path(project_path) / "team" / "director" / "promised.md"
    if not promised.exists():
        return {"pending": 0, "in_queue": 0, "done": 0}
    try:
        text = promised.read_text()
        return {
            "pending": text.count("[PENDING]"),
            "in_queue": text.count("[IN_QUEUE]"),
            "done": text.count("[DONE]"),
        }
    except Exception:
        return {"pending": 0, "in_queue": 0, "done": 0}


# ─── Ollama ──────────────────────────────────────────────────
def get_ollama_status():
    try:
        import urllib.request
        with urllib.request.urlopen("http://localhost:11434/api/tags", timeout=2) as r:
            data = json.loads(r.read())
        all_models = [m["name"] for m in data.get("models", [])]
        loaded = []
        try:
            with urllib.request.urlopen("http://localhost:11434/api/ps", timeout=2) as r2:
                ps = json.loads(r2.read())
            for m in ps.get("models", []):
                size_gb = round(m.get("size_vram", 0) / 1024**3, 1)
                loaded.append({"name": m["name"], "size_gb": size_gb})
        except Exception:
            pass
        return {"running": True, "all_models": all_models, "loaded": loaded}
    except Exception:
        return {"running": False, "all_models": [], "loaded": []}


# ─── Health summary per project ──────────────────────────────
def get_health_summary(proj: dict) -> str:
    """Return quick health: 'healthy', 'warning', 'critical', or 'unknown'."""
    prefix = proj.get("prefix", "")
    if not prefix:
        return "unknown"
    state_file = pathlib.Path(f"/tmp/{prefix}_health_state.json")
    if not state_file.exists():
        return "unknown"
    try:
        state = json.loads(state_file.read_text())
        for key, val in state.items():
            if "_notified" in key:
                if "critical" in str(val).lower() or "rule" in str(val).lower():
                    return "critical"
                if "warn" in str(val).lower():
                    return "warning"
        return "healthy"
    except Exception:
        return "unknown"


# ─── AI Status (combined SSE — multi-project) ────────────────
def get_ai_status():
    tokens = get_token_stats()
    claude_procs = get_claude_processes()
    ollama = get_ollama_status()

    with _projects_lock:
        projects_snapshot = dict(_projects)

    projects_data = {}
    for key, proj in projects_snapshot.items():
        tasks = get_task_status(proj)
        # Summary counts
        total_pending = sum(t["pending"] for t in tasks)
        total_active = sum(t["in_progress"] for t in tasks)
        total_done = sum(t["done"] for t in tasks)
        total_blocked = sum(t.get("blocked", 0) for t in tasks)

        projects_data[key] = {
            "name": proj["name"],
            "path": proj["path"],
            "prefix": proj.get("prefix", ""),
            "members": proj["members"],
            "tasks": tasks,
            "launchd": get_launchd_jobs(proj),
            "inbox": get_inbox_entries(proj),
            "activity": get_activity_feed(proj),
            "promised": get_promised_status(proj),
            "health": get_health_summary(proj),
            "summary": {
                "pending": total_pending,
                "active": total_active,
                "done": total_done,
                "blocked": total_blocked,
                "members": len(proj["members"]),
            },
        }

    return {
        "ts": datetime.now().strftime("%H:%M:%S"),
        "projects": projects_data,
        "tokens": tokens,
        "claude_procs": claude_procs,
        "ollama": ollama,
    }


# ─── HTTP Handler ────────────────────────────────────────────
class AAUHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WEB_DIR), **kwargs)

    def do_GET(self):
        if self.path == "/":
            with _projects_lock:
                has_project = len(_projects) > 0
            self._serve_file("monitor.html" if has_project else "index.html")
        elif self.path == "/setup":
            self._serve_file("index.html")
        elif self.path == "/settings":
            self._serve_file("settings.html")
        elif self.path == "/monitor":
            self._serve_file("monitor.html")
        elif self.path == "/metrics":
            self._serve_sse(get_system_metrics, interval=2)
        elif self.path == "/ai":
            self._serve_sse(get_ai_status, interval=5)
        elif self.path == "/api/projects":
            self._handle_list_projects()
        elif self.path.startswith("/api/config"):
            self._handle_get_config()
        else:
            super().do_GET()

    def do_POST(self):
        if self.path == "/api/setup":
            self._handle_setup()
        elif self.path == "/api/detect":
            self._handle_detect()
        elif self.path == "/api/team":
            self._handle_team_update()
        elif self.path == "/api/config":
            self._handle_save_config()
        elif self.path == "/api/rescan":
            self._handle_rescan()
        elif self.path == "/api/scan-folders":
            self._handle_scan_folders()
        else:
            self.send_error(404)

    def _serve_file(self, filename):
        filepath = WEB_DIR / filename
        if not filepath.exists():
            self.send_error(404)
            return
        data = filepath.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", len(data))
        self.end_headers()
        self.wfile.write(data)

    def _serve_sse(self, data_fn, interval=2):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        try:
            while True:
                payload = json.dumps(data_fn())
                self.wfile.write(f"data: {payload}\n\n".encode())
                self.wfile.flush()
                time.sleep(interval)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def _handle_detect(self):
        claude_path = shutil.which("claude") or "/opt/homebrew/bin/claude"
        platform = "macOS" if sys.platform == "darwin" else "Linux"
        self._json_response({"claude_cli": claude_path, "platform": platform})

    def _handle_list_projects(self):
        with _projects_lock:
            projects = {k: {"name": v["name"], "path": v["path"], "members": len(v["members"])}
                        for k, v in _projects.items()}
        self._json_response({"ok": True, "projects": projects})

    def _handle_scan_folders(self):
        """Scan ~/git/ for candidate project directories."""
        git_root = pathlib.Path.home() / "git"
        folders = []
        if git_root.exists():
            for d in sorted(git_root.iterdir()):
                if not d.is_dir() or d.name.startswith("."):
                    continue
                has_aau = (d / "aau.yaml").exists()
                has_git = (d / ".git").exists()
                # Detect project type
                ptype = "unknown"
                if (d / "package.json").exists():
                    ptype = "node"
                elif (d / "Cargo.toml").exists():
                    ptype = "rust"
                elif (d / "go.mod").exists():
                    ptype = "go"
                elif (d / "requirements.txt").exists() or (d / "pyproject.toml").exists():
                    ptype = "python"
                elif (d / "project.godot").exists():
                    ptype = "godot"
                elif (d / "Gemfile").exists():
                    ptype = "ruby"
                elif has_git:
                    ptype = "git"
                folders.append({
                    "name": d.name,
                    "path": str(d),
                    "has_aau": has_aau,
                    "has_git": has_git,
                    "type": ptype,
                })
        self._json_response({"ok": True, "folders": folders})

    def _handle_rescan(self):
        scan_all_projects()
        with _projects_lock:
            count = len(_projects)
        self._json_response({"ok": True, "count": count})

    def _handle_get_config(self):
        # Parse query param: ?project=key
        project_key = None
        if "?" in self.path:
            from urllib.parse import parse_qs, urlparse
            qs = parse_qs(urlparse(self.path).query)
            project_key = qs.get("project", [None])[0]

        with _projects_lock:
            if project_key and project_key in _projects:
                project_path = _projects[project_key]["path"]
            elif _projects:
                # Default to first project
                first_key = next(iter(_projects))
                project_path = _projects[first_key]["path"]
            else:
                self._json_response({"ok": False, "error": "No project loaded"}, status=404)
                return

        try:
            result = read_project_config(project_path)
            self._json_response({"ok": True, **result})
        except Exception as e:
            self._json_response({"ok": False, "error": str(e)}, status=500)

    def _handle_save_config(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length))
        try:
            result = save_project_config(body)
            # Reload the project
            pp = body.get("project_path", "")
            if pp:
                load_project(pp)
            self._json_response({"ok": True, **result})
        except Exception as e:
            self._json_response({"ok": False, "error": str(e)}, status=500)

    def _handle_team_update(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length))
        try:
            project_key = body.get("project")
            with _projects_lock:
                if project_key and project_key in _projects:
                    proj = _projects[project_key]
                elif _projects:
                    proj = next(iter(_projects.values()))
                else:
                    raise ValueError("No project loaded")
            result = update_team(body.get("members", []), proj["path"])
            load_project(proj["path"])
            self._json_response({"ok": True, **result})
        except Exception as e:
            self._json_response({"ok": False, "error": str(e)}, status=500)

    def _handle_setup(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length))
        try:
            result = run_setup(body)
            load_project(result["project_path"])
            # Save as last project
            try:
                STATE_FILE.write_text(result["project_path"])
            except Exception:
                pass
            self._json_response({"ok": True, **result})
        except Exception as e:
            self._json_response({"ok": False, "error": str(e)}, status=500)

    def _json_response(self, data, status=200):
        payload = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(payload))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        if args and str(args[0]).startswith(("POST", "GET /api", "GET /metrics", "GET /ai")):
            print(f"  {fmt % args}")

    def log_error(self, fmt, *args):
        print(f"  ERROR: {fmt % args}", file=sys.stderr)


# ─── Default Tools Per Role ────────────────────────────────────
ROLE_DEFAULT_TOOLS = {
    "researcher": "Read,Write,Edit,Bash,WebSearch,WebFetch",
    "analyst": "Read,Write,Edit,Bash",
    "writer": "Read,Write,Edit",
    "critic": "Read,Write,Edit,WebSearch,WebFetch",
    "coder": "Read,Write,Edit,Bash,Grep,Glob",
    "qa": "Read,Write,Edit,Bash,Grep,Glob",
    "frontend": "Read,Write,Edit,Bash,Grep,Glob",
    "backend": "Read,Write,Edit,Bash,Grep,Glob",
    "designer": "Read,Write,Edit,Bash",
    "planner": "Read,Write,Edit",
    "artist": "Read,Write,Edit,Bash",
    "assistant": "Read,Write,Edit,Bash",
    "docs": "Read,Write,Edit,Bash",
    "research": "Read,Write,Edit,Bash,WebSearch,WebFetch",
}
DEFAULT_TOOLS = "Read,Write,Edit,Bash"


def _default_tools_for(name, role=""):
    name_lower = name.lower()
    if name_lower in ROLE_DEFAULT_TOOLS:
        return ROLE_DEFAULT_TOOLS[name_lower]
    role_lower = role.lower()
    for key in ROLE_DEFAULT_TOOLS:
        if key in role_lower:
            return ROLE_DEFAULT_TOOLS[key]
    return DEFAULT_TOOLS


def _parse_schedule_config(yaml_text: str) -> dict:
    """Parse schedule: block from aau.yaml text."""
    result = {
        "schedule_timezone": "",
        "schedule_active_hours": "",
        "schedule_breaks": [],
        "schedule_weekend_mode": "",
        "schedule_weekend_active_hours": "",
        "schedule_director_active_hours": "",
        "schedule_agents_active_hours": "",
    }
    in_schedule = False
    sub = ""  # "weekend", "overrides", "director", "agents", "breaks"
    for line in yaml_text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if indent == 0 and stripped.endswith(":"):
            in_schedule = stripped == "schedule:"
            sub = ""
            continue
        if not in_schedule:
            continue
        # Sub-sections
        if indent == 2 and stripped.endswith(":"):
            sub = stripped[:-1]
            continue
        if indent == 4 and stripped.endswith(":"):
            sub = stripped[:-1]  # "director" or "agents" under overrides
            continue
        # Values
        if stripped.startswith("- "):
            if sub == "breaks" or (sub == "" and "breaks" in (line[:indent] + "breaks")):
                result["schedule_breaks"].append(stripped[2:].strip().strip('"'))
            continue
        if ":" not in stripped:
            continue
        k, v = stripped.split(":", 1)
        k, v = k.strip(), v.strip().strip('"')
        if sub == "" or sub == "schedule":
            if k == "timezone": result["schedule_timezone"] = v
            elif k == "active_hours": result["schedule_active_hours"] = v
            elif k == "breaks": sub = "breaks"  # list follows
        elif sub == "weekend":
            if k == "mode": result["schedule_weekend_mode"] = v
            elif k == "active_hours": result["schedule_weekend_active_hours"] = v
        elif sub == "director":
            if k == "active_hours": result["schedule_director_active_hours"] = v
        elif sub == "agents":
            if k == "active_hours": result["schedule_agents_active_hours"] = v
    return result


def _build_schedule_breaks(breaks):
    if not breaks or not isinstance(breaks, list):
        return "    # - \"12:00-13:00\"\n"
    return "".join(f'    - "{b}"\n' for b in breaks if b)


def _build_member_yaml(members):
    lines = []
    for m in members:
        name = m.get("name", "").strip()
        role = m.get("role", "General").strip()
        if not name:
            continue
        tools = m.get("tools", "") or _default_tools_for(name, role)
        lines.append(f"    - name: {name}")
        lines.append(f'      role: "{role}"')
        lines.append(f"      timeout: 600")
        lines.append(f"      max_turns: 30")
        lines.append(f"      interval: 300")
        lines.append(f'      tools: "{tools}"')
    return "\n".join(lines)


# ─── Team Update Logic ────────────────────────────────────────
def update_team(members: list, project_path: str = None) -> dict:
    import re

    if not project_path:
        raise ValueError("No project path")

    target = pathlib.Path(project_path)
    yaml_file = target / "aau.yaml"
    if not yaml_file.exists():
        raise ValueError(f"aau.yaml not found in {target}")

    new_members_block = _build_member_yaml(members)
    text = yaml_file.read_text()
    pattern = r"(  members:\n)((?:    .*\n)*)"
    replacement = f"  members:\n{new_members_block}\n"
    new_text = re.sub(pattern, replacement, text, count=1)
    yaml_file.write_text(new_text)

    for m in members:
        name = m.get("name", "").strip()
        if not name:
            continue
        member_dir = target / "team" / name
        if not member_dir.exists():
            member_dir.mkdir(parents=True, exist_ok=True)
            (member_dir / "tasks.md").write_text(
                f"# {name} — Task Queue\n\n"
                f"<!-- Status: PENDING | IN_PROGRESS | DONE | BLOCKED | CANCELLED -->\n\n"
                f"## Active Tasks\n\n"
            )
            (member_dir / "progress.md").write_text(f"# {name} — Progress Log\n\n")

    install_output = ""
    if sys.platform == "darwin":
        gen = AAU_ROOT / "platform" / "launchd" / "generate_plists.sh"
        inst = AAU_ROOT / "platform" / "launchd" / "install.sh"
        r1 = subprocess.run(["bash", str(gen)], capture_output=True, text=True, cwd=str(target))
        r2 = subprocess.run(["bash", str(inst)], capture_output=True, text=True, cwd=str(target))
        install_output = r1.stdout + r1.stderr + r2.stdout + r2.stderr

    valid_members = [m["name"].strip() for m in members if m.get("name", "").strip()]
    return {"members": valid_members, "install_output": install_output}


# ─── Config Read/Write ────────────────────────────────────────
def read_project_config(project_path: str) -> dict:
    root = pathlib.Path(project_path)
    yaml_file = root / "aau.yaml"
    env_file = root / ".env"

    if not yaml_file.exists():
        raise ValueError("aau.yaml not found")

    text = yaml_file.read_text()

    def get_val(section, key):
        in_section = False
        for line in text.splitlines():
            stripped = line.strip()
            if line and not line[0].isspace() and stripped.endswith(":"):
                in_section = stripped == f"{section}:"
                continue
            if in_section and stripped.startswith(f"{key}:"):
                return stripped.split(":", 1)[1].strip().strip('"')
        return ""

    members = []
    in_members = False
    current = None
    for line in text.splitlines():
        stripped = line.strip()
        if "members:" in stripped and not stripped.startswith("#"):
            in_members = True
            continue
        if in_members:
            if stripped.startswith("- name:"):
                current = {"name": stripped.split(":", 1)[1].strip()}
                members.append(current)
            elif stripped.startswith("role:") and current:
                current["role"] = stripped.split(":", 1)[1].strip().strip('"')
            elif stripped and not stripped.startswith("-") and not stripped.startswith(
                ("role:", "timeout:", "max_turns:", "interval:", "tools:")
            ):
                in_members = False

    env = {}
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()

    return {
        "project_path": str(root),
        "project_name": get_val("project", "name"),
        "claude_cli": get_val("runtime", "claude_cli"),
        "claude_model": get_val("runtime", "claude_model"),
        "prefix": get_val("runtime", "prefix"),
        "language": get_val("prompts", "language"),
        "notify_plugin": get_val("notification", "plugin"),
        **_parse_schedule_config(text),
        "llm_enabled": get_val("local_llm", "enabled") == "true",
        "slack_producer_id": get_val("slack", "producer_id"),
        "slack_bot_id": get_val("slack", "bot_id"),
        "members": members,
        "slack_token": env.get("SLACK_TOKEN", ""),
        "slack_app_token": env.get("SLACK_APP_TOKEN", ""),
        "slack_channel": env.get("SLACK_CHANNEL", ""),
        "webhook_url": env.get("WEBHOOK_URL", ""),
    }


def save_project_config(cfg: dict) -> dict:
    project_path = cfg.get("project_path")
    if not project_path:
        raise ValueError("No project_path in config")

    target = pathlib.Path(project_path)
    notify_plugin = cfg.get("notify_plugin", "none")
    members = cfg.get("members", [])
    member_yaml = _build_member_yaml(members)

    yaml_content = f"""\
project:
  name: "{cfg.get("project_name", "")}"

runtime:
  claude_cli: "{cfg.get("claude_cli", "/opt/homebrew/bin/claude")}"
  claude_model: "{cfg.get("claude_model", "claude-sonnet-4-6")}"
  permission_mode: "bypassPermissions"
  tmp_dir: "/tmp"
  prefix: "{cfg.get("prefix", "")}"

team:
  members:
{member_yaml}

director:
  autonomous_interval: 1800
  responder_interval: 120
  timeout: 600
  max_turns:
    report: 15
    followup: 20
    stale: 10
    idle: 25
    respond: 40
  report_interval: 7200
  stale_threshold: 1800
  daily_max_invocations: 20
  daily_max_invocations: 20

scheduling:
  task_monitor_interval: 300
  health_monitor_interval: 600

locks:
  max_age: 1800

retry:
  max_retries: 3
  backoff_base: 300

notification:
  plugin: "{notify_plugin}"
  report_style: "short"
  report_max_chars: 50

local_llm:
  enabled: {"true" if cfg.get("llm_enabled") else "false"}
  url: "http://localhost:11434/api/generate"
  classifier_model: "gemma2:9b"
  drafter_model: "qwen2.5-coder:32b"
  classifier_timeout: 30
  drafter_timeout: 300

prompts:
  language: "{cfg.get("language", "ja")}"

health:
  critical_patterns:
    - "Reached max turns"
    - "max turns exceeded"
    - "permission denied"
    - "Edit not allowed"
    - "Tool not allowed"
    - "Write not allowed"
  warning_patterns:
    - "TESTS FAILED"
    - "assert failed"
    - "Error: "
    - "BLOCKED"
    - "Traceback (most recent"
  stale_threshold: 1500
  relaunch_window_min: 60
  relaunch_critical_count: 5

schedule:
  timezone: "{cfg.get("schedule_timezone", "Asia/Tokyo")}"
  active_hours: "{cfg.get("schedule_active_hours", "08:00-23:00")}"
  breaks:
{_build_schedule_breaks(cfg.get("schedule_breaks", []))}  weekend:
    mode: "{cfg.get("schedule_weekend_mode", "normal")}"
    active_hours: "{cfg.get("schedule_weekend_active_hours", "")}"
  overrides:
    director:
      active_hours: "{cfg.get("schedule_director_active_hours", "")}"
    agents:
      active_hours: "{cfg.get("schedule_agents_active_hours", "")}"

slack:
  producer_id: "{cfg.get("slack_producer_id", "")}"
  bot_id: "{cfg.get("slack_bot_id", "")}"
"""
    (target / "aau.yaml").write_text(yaml_content)

    env_lines = []
    if cfg.get("slack_token"):
        env_lines.append(f'SLACK_TOKEN={cfg["slack_token"]}')
    if cfg.get("slack_app_token"):
        env_lines.append(f'SLACK_APP_TOKEN={cfg["slack_app_token"]}')
    if cfg.get("slack_channel"):
        env_lines.append(f'SLACK_CHANNEL={cfg["slack_channel"]}')
    if cfg.get("slack_producer_id"):
        env_lines.append(f'SLACK_PRODUCER_ID={cfg["slack_producer_id"]}')
    if cfg.get("slack_bot_id"):
        env_lines.append(f'SLACK_BOT_ID={cfg["slack_bot_id"]}')
    if cfg.get("webhook_url"):
        env_lines.append(f'WEBHOOK_URL={cfg["webhook_url"]}')
    if env_lines:
        (target / ".env").write_text("\n".join(env_lines) + "\n")

    for m in members:
        name = m.get("name", "").strip()
        if not name:
            continue
        member_dir = target / "team" / name
        if not member_dir.exists():
            member_dir.mkdir(parents=True, exist_ok=True)
            (member_dir / "tasks.md").write_text(f"# {name} — Task Queue\n\n## Active Tasks\n\n")
            (member_dir / "progress.md").write_text(f"# {name} — Progress Log\n\n")

    install_output = ""
    if sys.platform == "darwin":
        gen = AAU_ROOT / "platform" / "launchd" / "generate_plists.sh"
        inst = AAU_ROOT / "platform" / "launchd" / "install.sh"
        r1 = subprocess.run(["bash", str(gen)], capture_output=True, text=True, cwd=str(target))
        r2 = subprocess.run(["bash", str(inst)], capture_output=True, text=True, cwd=str(target))
        install_output = r1.stdout + r1.stderr + r2.stdout + r2.stderr

    return {"install_output": install_output}


# ─── Setup Logic ─────────────────────────────────────────────
def run_setup(cfg: dict) -> dict:
    target = pathlib.Path(cfg["project_path"]).expanduser().resolve()
    if not target.is_dir():
        target.mkdir(parents=True, exist_ok=True)

    project_name = cfg["project_name"]
    prefix = cfg.get("prefix", project_name[:10].lower().replace(" ", "_").replace("-", "_"))

    # Write config
    save_cfg = {**cfg, "prefix": prefix, "project_path": str(target)}
    save_project_config(save_cfg)

    # Write .gitignore
    notify_plugin = cfg.get("notify_plugin", "none")
    if notify_plugin != "none":
        gitignore = target / ".gitignore"
        if gitignore.exists():
            text = gitignore.read_text()
            if ".env" not in text.splitlines():
                gitignore.write_text(text.rstrip() + "\n.env\n")
        else:
            gitignore.write_text(".env\n")

    # Scaffold
    scaffold = AAU_ROOT / "init" / "scaffold.sh"
    result = subprocess.run(
        ["bash", str(scaffold), str(target)],
        capture_output=True, text=True, cwd=str(target),
    )
    scaffold_output = result.stdout + result.stderr

    # Install services
    install_output = ""
    if cfg.get("install_services", False):
        if sys.platform == "darwin":
            gen = AAU_ROOT / "platform" / "launchd" / "generate_plists.sh"
            inst = AAU_ROOT / "platform" / "launchd" / "install.sh"
        else:
            gen = AAU_ROOT / "platform" / "systemd" / "generate_units.sh"
            inst = AAU_ROOT / "platform" / "systemd" / "install.sh"
        r1 = subprocess.run(["bash", str(gen)], capture_output=True, text=True, cwd=str(target))
        r2 = subprocess.run(["bash", str(inst)], capture_output=True, text=True, cwd=str(target))
        install_output = r1.stdout + r1.stderr + r2.stdout + r2.stderr

    members = cfg.get("members", [{"name": "coder", "role": "Implementation"}])
    return {
        "project_path": str(target),
        "config_file": str(target / "aau.yaml"),
        "members": [m["name"] for m in members if m.get("name")],
        "scaffold_output": scaffold_output,
        "install_output": install_output,
    }


# ─── Server ──────────────────────────────────────────────────
class ThreadedServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    # Load projects: CLI arg > scan all
    if len(sys.argv) > 1:
        load_project(sys.argv[1])
    else:
        # Scan all projects in ~/git/
        print("Scanning for AAU projects...")
        scan_all_projects()

    with _projects_lock:
        project_count = len(_projects)

    if project_count == 0:
        print("  No projects found. Set up via web UI first.")
    else:
        print(f"  {project_count} project(s) loaded.")

    # Pre-compute token stats in background
    threading.Thread(target=get_token_stats, daemon=True).start()

    with ThreadedServer(("", PORT), AAUHandler) as httpd:
        url = f"http://localhost:{PORT}"
        print(f"AAU Server: {url}")
        print(f"  Dashboard: {url}/")
        print(f"  Setup:     {url}/setup")
        print(f"  Settings:  {url}/settings")
        webbrowser.open(url)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nShutting down.")
