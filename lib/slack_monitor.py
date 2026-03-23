#!/usr/bin/env python3
"""
AAU Slack Monitor
Slackチャンネルを監視し、プロデューサーのメッセージをDirectorのinbox.mdに転記する。
Claudeを一切使わない。launchdから1分ごとに起動される。

Usage:
    python3 slack_monitor.py /path/to/project
"""

import hashlib
import json
import os
import re
import subprocess
import sys

# Add lib dir to path for schedule module
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import urllib.request
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

# ── 設定読み込み ─────────────────────────────────────────────────────
def load_config(project_path: str) -> dict:
    """aau.yaml と .env から設定を読み込む。"""
    root = Path(project_path)
    cfg = {
        "project_root": root,
        "project_name": "",
        "prefix": "",
        "slack_token": "",
        "slack_channel": "",
        "producer_id": "",
        "bot_id": "",
        "ollama_url": "http://localhost:11434/api/generate",
        "ollama_model": "gemma2:9b",
        "ollama_timeout": 30,
        "llm_enabled": False,
        "members": [],
    }

    # Parse aau.yaml
    yaml_file = root / "aau.yaml"
    if yaml_file.exists():
        text = yaml_file.read_text()
        in_project = False
        in_runtime = False
        in_members = False
        in_local_llm = False
        in_slack = False
        for line in text.splitlines():
            stripped = line.strip()
            # Top-level sections
            if line and not line[0].isspace() and stripped.endswith(":"):
                in_project = stripped == "project:"
                in_runtime = stripped == "runtime:"
                in_members = False
                in_local_llm = stripped == "local_llm:"
                in_slack = stripped == "slack:"
                continue
            if "members:" in stripped and not stripped.startswith("#"):
                in_members = True
                continue
            if in_project and stripped.startswith("name:"):
                cfg["project_name"] = stripped.split(":", 1)[1].strip().strip('"')
            if in_runtime and stripped.startswith("prefix:"):
                cfg["prefix"] = stripped.split(":", 1)[1].strip().strip('"')
            if in_members:
                if stripped.startswith("- name:"):
                    cfg["members"].append(stripped.split(":", 1)[1].strip())
                elif stripped and not stripped.startswith("role:") and not stripped.startswith("timeout:") and not stripped.startswith("max_turns:") and not stripped.startswith("interval:") and not stripped.startswith("-"):
                    in_members = False
            if in_local_llm:
                if stripped.startswith("enabled:"):
                    cfg["llm_enabled"] = stripped.split(":", 1)[1].strip() == "true"
                if stripped.startswith("url:"):
                    cfg["ollama_url"] = stripped.split(":", 1)[1].strip().strip('"')
                if stripped.startswith("classifier_model:"):
                    cfg["ollama_model"] = stripped.split(":", 1)[1].strip().strip('"')
                if stripped.startswith("classifier_timeout:"):
                    cfg["ollama_timeout"] = int(stripped.split(":", 1)[1].strip())
            if in_slack:
                if stripped.startswith("producer_id:"):
                    cfg["producer_id"] = stripped.split(":", 1)[1].strip().strip('"')
                if stripped.startswith("bot_id:"):
                    cfg["bot_id"] = stripped.split(":", 1)[1].strip().strip('"')
                if stripped.startswith("record_keyword:"):
                    cfg["record_keyword"] = stripped.split(":", 1)[1].strip().strip('"')

    # Load .env
    env_file = root / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                k, v = k.strip(), v.strip()
                if k == "SLACK_TOKEN":
                    cfg["slack_token"] = v
                elif k == "SLACK_CHANNEL":
                    cfg["slack_channel"] = v
                elif k == "SLACK_PRODUCER_ID":
                    cfg["producer_id"] = v
                elif k == "SLACK_BOT_ID":
                    cfg["bot_id"] = v

    return cfg


# ── インテント定義 ────────────────────────────────────────────────────
# Intent types
INTENT_STATUS   = "status"    # System status query → auto-reply without Claude
INTENT_REACTION = "reaction"  # Short reaction/emoji → skip
INTENT_RECORD   = "record"    # Recording request → trigger file (configurable)
INTENT_TASK     = "task"      # Instruction/request/question → requires Claude
INTENT_EMERGENCY = "emergency"  # Emergency override → force active hours
INTENT_APPROVAL = "approval"    # AP-XXX approval/rejection → update approvals.md

APPROVAL_ID_PATTERN = re.compile(r'AP-(\d+)\s*(承認|却下|approve|reject)', re.IGNORECASE)

STATUS_QUERY_PHRASES = [
    "システム状態", "システムの状態", "状態教えて", "状況教えて", "状況",
    "どうなってる", "進捗教えて", "進捗", "ステータス", "今どうなってる",
    "チームの状況", "タスクどうなった", "何してる", "動いてる",
    "status", "progress",
]

REACTION_PHRASES = [
    "ok", "ｏｋ", "了解", "ありがとう", "いいね", "👍", "🙏", "✅",
    "なるほど", "わかった", "わかりました", "承知", "おｋ",
]

APPROVAL_PHRASES = [
    "okです", "ok です", "いいです", "承認", "進めて", "問題ない",
]

EMERGENCY_PHRASES = [
    "緊急稼働", "緊急対応", "emergency override", "今すぐ動け", "起きろ",
]

PROMISE_PHRASES = [
    "のちほど作成", "のちほど報告", "後で作成", "後ほど作成", "後ほど報告",
    "あとで作成", "お送りします", "送ります", "報告します", "報告いたします",
    "作成します", "作ります", "即着手", "着手します",
    "動かします", "起動します", "完成次第", "できたらお送り",
]

PROMISE_EXCLUDE = [
    "ディレクターが後ほど対応します",
    "確認します。ディレクターが",
]

# Record trigger keyword (set in aau.yaml via slack.record_keyword, default: "録画")
RECORD_KEYWORD = "録画"


# ── ユーティリティ ────────────────────────────────────────────────────
_cfg = {}
_log_file = None
_jsonl_file = None


def init(cfg: dict):
    global _cfg, _log_file, _jsonl_file
    _cfg = cfg
    prefix = cfg["prefix"]
    _log_file = Path(f"/tmp/{prefix}_slack_monitor.log")
    _jsonl_file = Path(f"/tmp/{prefix}_slack_monitor.jsonl")


def log(msg: str):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(_log_file, "a") as f:
        f.write(f"[{ts}] {msg}\n")


def jlog(level: str, event: str, **kwargs):
    record = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "level": level, "event": event, **kwargs,
    }
    with open(_jsonl_file, "a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def slack_get(endpoint: str, params: dict) -> dict:
    qs = urllib.parse.urlencode(params)
    url = f"https://slack.com/api/{endpoint}?{qs}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {_cfg['slack_token']}"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


def slack_post(text: str):
    payload = json.dumps({"channel": _cfg["slack_channel"], "text": text}).encode()
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=payload,
        headers={"Authorization": f"Bearer {_cfg['slack_token']}",
                 "Content-Type": "application/json"},
    )
    urllib.request.urlopen(req, timeout=10)


# ── インテント判定 ────────────────────────────────────────────────────
def detect_intent(text: str) -> str:
    text_lower = text.lower().strip()

    # Emergency override — highest priority
    if any(p in text_lower for p in EMERGENCY_PHRASES):
        return INTENT_EMERGENCY

    # Approval ID pattern: "AP-001 承認" or "AP-002 却下"
    if APPROVAL_ID_PATTERN.search(text):
        return INTENT_APPROVAL

    # Natural language approval/rejection → check if any AP is PENDING
    # "承認", "進めて", "OK" etc. auto-resolve the pending AP
    if any(p in text_lower for p in APPROVAL_PHRASES) or text_lower.strip() in ("ok", "ｏｋ", "okay"):
        approvals_path = _cfg["project_root"] / "team/director/approvals.md" if _cfg else None
        if approvals_path and approvals_path.exists():
            ap_content = approvals_path.read_text()
            if "status: PENDING" in ap_content:
                return INTENT_APPROVAL
        return INTENT_TASK

    # Short reactions (≤10 chars and contains reaction keyword)
    if len(text) <= 10 and any(p in text_lower for p in REACTION_PHRASES):
        return INTENT_REACTION
    # Emoji-only messages (only emoji, no CJK/kana/numbers)
    # Exclude: Japanese text, numbered choices (①②③), short instructions
    import unicodedata
    has_text_char = any(
        unicodedata.category(c).startswith(("L", "N"))  # Letter or Number
        for c in text if not c.isspace()
    )
    if len(text) <= 3 and not has_text_char:
        return INTENT_REACTION

    # Status query
    if any(p in text for p in STATUS_QUERY_PHRASES):
        return INTENT_STATUS

    # Record trigger (configurable keyword)
    record_kw = _cfg.get("record_keyword", RECORD_KEYWORD) if _cfg else RECORD_KEYWORD
    if record_kw and record_kw in text:
        return INTENT_RECORD

    return INTENT_TASK


# ── Ollama分類 ────────────────────────────────────────────────────────
def ollama_classify(text: str) -> dict:
    if not _cfg.get("llm_enabled"):
        return {
            "importance": "medium",
            "summary": text[:50],
            "auto_reply": "確認します。ディレクターが後ほど対応します。",
        }

    prompt = f"""You are a simple Slack notification bot.
A message was sent by the producer (your boss).

Message: {text[:400]}

Respond with JSON only:
{{
  "importance": "high",
  "summary": "日本語で1文の要約（50字以内）",
  "auto_reply": "確認します。ディレクターが後ほど対応します。"
}}

Rules:
- "high": questions, requests, instructions
- "medium": general chat
- "low": simple reactions ("OK", "了解", emoji)
- auto_reply for high/medium: EXACTLY "確認します。ディレクターが後ほど対応します。"
- auto_reply for low: EXACTLY "👍"
"""
    body = json.dumps({
        "model": _cfg["ollama_model"], "prompt": prompt, "stream": False
    }).encode()
    req = urllib.request.Request(
        _cfg["ollama_url"], data=body,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=_cfg["ollama_timeout"]) as resp:
            data = json.loads(resp.read())
        raw = data.get("response", "{}")
        match = re.search(r"\{.*\}", raw, re.DOTALL)
        if match:
            return json.loads(match.group())
    except Exception as e:
        log(f"ollama error: {e}")
    return {
        "importance": "medium",
        "summary": text[:50],
        "auto_reply": "確認します。ディレクターが後ほど対応します。",
    }


# ── システム状態収集 ──────────────────────────────────────────────────
def gather_system_status() -> str:
    root = _cfg["project_root"]
    name = _cfg["project_name"]
    lines = []

    # launchd
    try:
        result = subprocess.run(["launchctl", "list"], capture_output=True, text=True)
        services = [l for l in result.stdout.splitlines() if f"ai.{name}" in l]
        running = sum(1 for l in services if l.split("\t")[0] != "-")
        lines.append(f"launchd: {len(services)} services ({running} running)")
    except Exception:
        lines.append("launchd: unavailable")

    # Triggers
    prefix = _cfg["prefix"]
    triggers = [t.name.replace(f"{prefix}_trigger_", "")
                for t in Path("/tmp").glob(f"{prefix}_trigger_*")]
    lines.append(f"Queue: {', '.join(triggers)}" if triggers else "Queue: empty (all idle)")

    # Team members
    for member in _cfg["members"]:
        tasks_path = root / f"team/{member}/tasks.md"
        if not tasks_path.exists():
            continue
        try:
            task_lines = tasks_path.read_text().splitlines()
            in_prog = [l.strip() for l in task_lines if "[IN_PROGRESS]" in l]
            pending = [l.strip() for l in task_lines if "[PENDING]" in l]
            done = [l.strip() for l in task_lines if "[DONE]" in l]

            if in_prog or pending:
                parts = []
                for t in in_prog[:2]:
                    parts.append(f"  🔄 {t[:60]}")
                for t in pending[:3]:
                    parts.append(f"  ⏳ {t[:60]}")
                lines.append(f"{member}:")
                lines.extend(parts)
            else:
                last = done[-1][:50] if done else "none"
                lines.append(f"{member}: ✅ all done (last: {last})")
        except Exception:
            lines.append(f"{member}: error reading tasks")

    # Director inbox
    inbox_path = root / "team/director/inbox.md"
    if inbox_path.exists():
        try:
            inbox_text = inbox_path.read_text()
            unread = inbox_text.count("ステータス: UNREAD") + inbox_text.count("ステータス: PROCESSING")
            lines.append(f"director: {unread} unread inbox" if unread else "director: inbox clear")
        except Exception:
            pass

    return "\n".join(lines)


def format_status_report(raw: str) -> str:
    """Format system status into a structured Slack message."""
    lines = raw.splitlines()

    services_line = next((l for l in lines if "launchd" in l.lower()), "")
    queue_line = next((l for l in lines if "Queue" in l or "キュー" in l), "")

    # Build member sections
    member_blocks = {}
    current_member = None
    for line in lines:
        for m in _cfg.get("members", []):
            if line.startswith(f"{m}:"):
                current_member = m
                member_blocks[m] = [line.split(":", 1)[1].strip()]
                break
        else:
            if current_member and line.startswith("  "):
                member_blocks[current_member].append(line.strip())

    report_parts = [
        f"*System Status* ({datetime.now().strftime('%H:%M')})",
    ]
    if services_line:
        report_parts.append(f"🖥️ {services_line}")
    if queue_line:
        report_parts.append(f"📥 {queue_line}")

    for m in _cfg.get("members", []):
        parts = member_blocks.get(m, [])
        if not parts:
            continue
        summary = parts[0]
        if "all done" in summary or "全完了" in summary:
            report_parts.append(f"✅ *{m}*: {summary}")
        elif "BLOCKED" in summary:
            report_parts.append(f"⚠️ *{m}*: {summary}")
        else:
            header = f"🔄 *{m}*: {summary}"
            details = "\n".join(f"　　{p}" for p in parts[1:])
            report_parts.append(f"{header}\n{details}" if details else header)

    # Director inbox
    director_parts = member_blocks.get("director", [])
    if director_parts:
        report_parts.append(f"📋 *director*: {director_parts[0]}")

    report_parts.append(f"— _by Bot (auto)_")
    return "\n".join(filter(None, report_parts)).strip()


# ── State管理 ────────────────────────────────────────────────────────
def state_file() -> Path:
    return _cfg["project_root"] / "team/director/last_check.md"


def read_state() -> dict:
    import time as _time
    state = {"slack_ts": "0"}
    sf = state_file()
    if not sf.exists():
        # No state file = fresh start. Use current time to skip all history.
        state["slack_ts"] = str(_time.time())
        write_state(state)
        log("No last_check.md found — initialized to current time (skip history)")
        return state
    content = sf.read_text()
    ts_match = re.search(r"last_ts:\s*([\d.]+)", content)
    if ts_match:
        state["slack_ts"] = ts_match.group(1)
    for member in _cfg["members"]:
        for ftype in ["tasks", "progress"]:
            key = f"{member}_{ftype}"
            m = re.search(rf"{key}:\s*(\d+)", content)
            if m:
                state[key] = int(m.group(1))
    return state


def write_state(state: dict):
    lines = [
        "# Last Check State\n",
        "<!-- Slack Monitor auto-updates this file. -->\n\n",
        "## Slack\n",
        f"last_ts: {state['slack_ts']}\n\n",
        "## Files\n",
    ]
    for member in _cfg["members"]:
        for ftype in ["tasks", "progress"]:
            key = f"{member}_{ftype}"
            if key in state:
                lines.append(f"{key}: {state[key]}\n")
    state_file().write_text("".join(lines))


# ── inbox書き込み ────────────────────────────────────────────────────
def append_inbox(entry: str):
    inbox = _cfg["project_root"] / "team/director/inbox.md"
    with open(inbox, "a") as f:
        f.write(entry)


# ── Slack監視 ────────────────────────────────────────────────────────
def check_slack(state: dict) -> str:
    import time as _time
    last_ts = state.get("slack_ts", "0")
    # Safety: if ts is "0" or very old (>24h), reset to current time to avoid history flood
    if last_ts == "0" or (float(last_ts) < _time.time() - 86400):
        last_ts = str(_time.time())
        state["slack_ts"] = last_ts
        log(f"slack_ts was stale/zero — reset to current time")
    producer_id = _cfg.get("producer_id", "")

    if not producer_id:
        log("WARN: no producer_id configured, skip Slack check")
        return last_ts

    all_messages = []
    cursor = None
    for _ in range(5):
        params = {"channel": _cfg["slack_channel"], "limit": 100, "oldest": last_ts}
        if cursor:
            params["cursor"] = cursor
        try:
            data = slack_get("conversations.history", params)
        except Exception as e:
            log(f"Slack API error: {e}")
            return last_ts
        all_messages.extend(data.get("messages", []))
        if not data.get("has_more"):
            break
        cursor = data.get("response_metadata", {}).get("next_cursor")
        if not cursor:
            break

    producer_msgs = [m for m in all_messages if m.get("user") == producer_id]
    producer_msgs.sort(key=lambda m: float(m.get("ts", 0)))

    if not producer_msgs:
        return last_ts

    new_latest_ts = last_ts
    for msg in producer_msgs:
        ts = msg["ts"]
        text = msg.get("text", "")
        dt = datetime.fromtimestamp(float(ts)).strftime("%Y-%m-%d %H:%M")

        log(f"Slack message from producer: {text[:60]}")
        intent = detect_intent(text)
        log(f"  → intent: {intent}")
        jlog("info", "message_received", intent=intent, text_len=len(text))

        # EMERGENCY → create override file, force active hours
        if intent == INTENT_EMERGENCY:
            duration_match = re.search(r'(\d+)\s*分', text)
            duration_sec = int(duration_match.group(1)) * 60 if duration_match else 3600
            em_prefix = _cfg.get("prefix", "aau")
            override_path = Path(f"/tmp/{em_prefix}_emergency_override")
            override_path.write_text(str(duration_sec))
            try:
                slack_post(f"緊急稼働モード ON ({duration_sec // 60}分間)\nスケジュール制限を一時解除しました。")
                log(f"  → emergency override created ({duration_sec}s)")
                jlog("info", "emergency_override", duration=duration_sec)
            except Exception as e:
                log(f"  → emergency reply error: {e}")
            new_latest_ts = ts
            continue

        # APPROVAL → update approvals.md (zero-token, no Claude)
        if intent == INTENT_APPROVAL:
            match = APPROVAL_ID_PATTERN.search(text)
            approvals_path = _cfg["project_root"] / "team/director/approvals.md"
            ap_id = None
            ap_status = None

            if match:
                # Explicit: "AP-001 承認"
                ap_id = f"AP-{match.group(1)}"
                ap_action_word = match.group(2)
                ap_status = "APPROVED" if "承認" in ap_action_word or "approve" in ap_action_word.lower() else "REJECTED"
            else:
                # Natural language: "承認", "進めて", "OK" → resolve first PENDING AP
                text_lower_ap = text.lower().strip()
                is_reject = any(w in text_lower_ap for w in ["却下", "reject", "やめ", "だめ", "ダメ", "やり直"])
                ap_status = "REJECTED" if is_reject else "APPROVED"
                if approvals_path.exists():
                    ap_content = approvals_path.read_text()
                    pending_match = re.search(r'## (AP-\d+) .+\nstatus: PENDING', ap_content)
                    if pending_match:
                        ap_id = pending_match.group(1)

            if ap_id and approvals_path.exists():
                content = approvals_path.read_text()
                updated = re.sub(
                    rf'(## {re.escape(ap_id)} .+\n)status: PENDING',
                    rf'\1status: {ap_status}',
                    content
                )
                if ap_status == "APPROVED":
                    updated = re.sub(
                        rf'(## {re.escape(ap_id)} .+\nstatus: APPROVED\ncreated: .+)',
                        rf'\1\napproved: {datetime.now().strftime("%Y-%m-%d %H:%M")}',
                        updated
                    )
                approvals_path.write_text(updated)
                log(f"  → {ap_id} {ap_status}")
                jlog("info", "approval_decision", id=ap_id, status=ap_status)
                status_word = "承認しました" if ap_status == "APPROVED" else "却下しました"
                # Extract AP summary for human-readable message
                summary_match = re.search(rf'## {re.escape(ap_id)} (.+)', content)
                ap_summary = summary_match.group(1) if summary_match else ""
                try:
                    slack_post(f"[by Bot] {ap_summary}を{status_word} 作業を再開します。")
                except Exception:
                    pass
            elif not ap_id:
                log("  → no PENDING approval found for natural language approval")
            else:
                log(f"  → approvals.md not found, skipping")

            new_latest_ts = ts
            entry = f"""
## [{dt}] Slack: Producer — 承認回答
> {text}

**承認ID**: {ap_id or "?"}
**結果**: {ap_status or "?"}
ステータス: UNREAD

"""
            append_inbox(entry)
            continue

        # REACTION → skip
        if intent == INTENT_REACTION:
            log("  → reaction, skipped")
            jlog("info", "reaction_skipped")
            new_latest_ts = ts
            continue

        # RECORD → create trigger file (no Claude)
        if intent == INTENT_RECORD:
            record_kw = _cfg.get("record_keyword", RECORD_KEYWORD) if _cfg else RECORD_KEYWORD
            duration_match = re.search(rf'{re.escape(record_kw)}\s*(\d+)', text)
            duration = int(duration_match.group(1)) if duration_match else 60
            prefix = _cfg.get("prefix", "aau")
            trigger_path = Path(f"/tmp/{prefix}_trigger_record")
            trigger_path.write_text(str(duration))
            try:
                slack_post(f"📹 Record request accepted ({duration}s).\n— _by Bot (auto)_")
                log(f"  → record trigger created (duration={duration}s)")
                jlog("info", "record_trigger_created", duration=duration)
            except Exception as e:
                log(f"  → record reply error: {e}")
            new_latest_ts = ts
            continue

        # STATUS → auto-reply with system status (no Claude)
        if intent == INTENT_STATUS:
            log("  → status query, auto-reply")
            jlog("info", "status_query_auto")
            raw = gather_system_status()
            reply = format_status_report(raw)
            try:
                slack_post(reply)
                log("  → status reply posted")
            except Exception as e:
                log(f"  → status reply error: {e}")
            new_latest_ts = ts
            continue

        # (Auto-approval now handled in INTENT_APPROVAL above via approvals.md)

        # TASK → classify → inbox → director-responder handles
        classification = ollama_classify(text)
        summary = classification.get("summary", text[:50])
        auto_reply = classification.get("auto_reply", "確認します。ディレクターが後ほど対応します。")

        # Auto-reply with agent name tag
        try:
            slack_post(f"[by Bot] {auto_reply}")
            log("  → auto reply posted")
        except Exception as e:
            log(f"  → auto reply error: {e}")

        # Write to inbox
        entry = f"""
## [{dt}] Slack: Producer 🔴 **[Action Required]**
> {text}

**Summary**: {summary}
**Auto-reply**: {auto_reply[:100]}
ステータス: UNREAD

"""
        append_inbox(entry)
        log("  → written to inbox as UNREAD")
        jlog("info", "task_written_to_inbox", summary=summary[:80])
        new_latest_ts = ts

    return new_latest_ts


# ── チームファイル監視 ────────────────────────────────────────────────
def check_team_files(state: dict) -> dict:
    root = _cfg["project_root"]
    updates = {}

    for member in _cfg["members"]:
        for ftype in ["tasks", "progress"]:
            key = f"{member}_{ftype}"
            path = root / f"team/{member}/{ftype}.md"
            if not path.exists():
                continue
            mtime = int(path.stat().st_mtime)
            last_mtime = state.get(key, 0)

            if mtime <= last_mtime:
                updates[key] = last_mtime
                continue

            try:
                lines = path.read_text().splitlines()[:100]
            except Exception:
                updates[key] = mtime
                continue

            blocked = [l.strip() for l in lines if "[BLOCKED]" in l]
            if blocked:
                dt = datetime.now().strftime("%Y-%m-%d %H:%M")
                entry = f"""
## [{dt}] ⚠️ BLOCKED: {member} ({ftype})
{blocked[-1][:80]}
ステータス: UNREAD

"""
                append_inbox(entry)
                log(f"  → BLOCKED detected: {member}/{ftype}")

            updates[key] = mtime

    return updates


# ── Bot約束追跡 ──────────────────────────────────────────────────────
def scan_bot_promises(state: dict):
    # Disabled: promise detection causes massive junk task generation
    # because bot replies contain phrases like "お送りします", "即着手可能"
    # that match PROMISE_PHRASES. Re-enable only with much stricter filtering.
    return

    bot_id = _cfg.get("bot_id", "")
    if not bot_id:
        return

    last_ts = state.get("slack_ts", "0")
    try:
        data = slack_get("conversations.history", {
            "channel": _cfg["slack_channel"], "limit": 100, "oldest": last_ts,
        })
    except Exception:
        return

    promised_path = _cfg["project_root"] / "team/director/promised.md"
    existing = ""
    try:
        existing = promised_path.read_text()
    except Exception:
        pass

    for msg in data.get("messages", []):
        if msg.get("user") != bot_id:
            continue
        text = msg.get("text", "")
        ts = msg.get("ts", "0")
        dt = datetime.fromtimestamp(float(ts)).strftime("%Y-%m-%d %H:%M")

        if any(ex in text for ex in PROMISE_EXCLUDE):
            continue

        for phrase in PROMISE_PHRASES:
            if phrase in text:
                if ts in existing:
                    break
                idx = text.find(phrase)
                promise_text = text[max(0, idx - 15):idx + 40].strip()
                entry = f"\n## [PENDING] {dt} — {promise_text[:80]}\n> {text[:120]}\n\n"
                with open(promised_path, "a") as f:
                    f.write(entry)
                log(f"  → promise detected: {promise_text[:40]}")
                break


# ── Slack通知キュー消費 ────────────────────────────────────────────────
def flush_slack_queue():
    """Read queued notifications, dedup by content hash, post with min interval."""
    prefix = _cfg.get("prefix", "aau")
    queue_path = Path(f"/tmp/{prefix}_slack_queue")
    if not queue_path.exists():
        return

    posted_hashes_path = Path(f"/tmp/{prefix}_slack_posted_hashes")
    min_interval = 600  # 10 minutes between similar messages

    # Read and clear queue atomically
    try:
        lines = queue_path.read_text().splitlines()
        queue_path.unlink()
    except Exception:
        return

    # Load recent post hashes
    recent_hashes = {}
    if posted_hashes_path.exists():
        try:
            for line in posted_hashes_path.read_text().splitlines():
                parts = line.split("|", 1)
                if len(parts) == 2:
                    recent_hashes[parts[1]] = int(parts[0])
        except Exception:
            pass

    now = int(datetime.now().timestamp())
    for line in lines:
        parts = line.split("|", 1)
        if len(parts) != 2:
            continue
        _ts, msg = parts[0], parts[1]
        content_hash = hashlib.md5(msg[:100].encode()).hexdigest()[:12]

        # Dedup: skip if same hash posted within min_interval
        if content_hash in recent_hashes:
            if now - recent_hashes[content_hash] < min_interval:
                log(f"  queue dedup: skipped ({msg[:40]})")
                continue

        try:
            slack_post(msg)
            recent_hashes[content_hash] = now
            log(f"  queue posted: {msg[:60]}")
        except Exception as e:
            log(f"  queue post error: {e}")

    # Save recent hashes (keep last 24h only)
    cutoff = now - 86400
    try:
        with open(posted_hashes_path, "w") as f:
            for h, t in recent_hashes.items():
                if t > cutoff:
                    f.write(f"{t}|{h}\n")
    except Exception:
        pass


# ── メイン ────────────────────────────────────────────────────────────
def _is_quiet_hours(cfg: dict) -> bool:
    """Check if current time is within quiet hours using centralized schedule."""
    try:
        from schedule import is_active as _sched_active
        # Build a config dict that schedule.py can understand
        sched_cfg = {}
        root = cfg.get("project_root")
        if root:
            yaml_file = root / "aau.yaml"
            if yaml_file.exists():
                sched_cfg = _parse_yaml_for_schedule(yaml_file)
        prefix = cfg.get("prefix", "aau")
        return not _sched_active(sched_cfg, "", "/tmp", prefix)
    except Exception:
        return False


def _parse_yaml_for_schedule(yaml_file: Path) -> dict:
    """Parse aau.yaml to extract schedule and director config for schedule.py."""
    text = yaml_file.read_text()
    result = {"director": {}, "schedule": {}}
    section = ""
    sub_section = ""
    breaks = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if indent == 0 and stripped.endswith(":"):
            section = stripped[:-1]
            sub_section = ""
            continue
        if section == "schedule":
            if indent <= 2 and stripped.endswith(":"):
                sub_section = stripped[:-1]
                continue
            if ":" in stripped and not stripped.startswith("-"):
                k, v = stripped.split(":", 1)
                k, v = k.strip(), v.strip().strip('"')
                if sub_section == "weekend":
                    result["schedule"].setdefault("weekend", {})[k] = v
                elif sub_section == "overrides":
                    pass  # handled below
                elif sub_section:
                    result["schedule"].setdefault("overrides", {}).setdefault(sub_section, {})[k] = v
                else:
                    result["schedule"][k] = v
            elif stripped.startswith("- "):
                breaks.append(stripped[2:].strip().strip('"'))
        elif section == "director":
            if ":" in stripped:
                k, v = stripped.split(":", 1)
                result["director"][k.strip()] = v.strip().strip('"')
    if breaks:
        result["schedule"]["breaks"] = breaks
    return result


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} /path/to/project")
        sys.exit(1)

    project_path = sys.argv[1]
    cfg = load_config(project_path)

    if not cfg["slack_token"] or not cfg["slack_channel"]:
        print("WARN: SLACK_TOKEN or SLACK_CHANNEL not configured, exiting.")
        sys.exit(0)

    init(cfg)
    log("=== slack_monitor start ===")

    # Quiet hours: still track messages (update last_ts) but don't write inbox or reply
    quiet = _is_quiet_hours(cfg)
    if quiet:
        log("quiet hours — tracking only, no inbox writes or replies")

    state = read_state()

    if quiet:
        # During quiet hours: only update last_ts to avoid re-ingesting messages later
        last_ts = state.get("slack_ts", "0")
        producer_id = cfg.get("producer_id", "")
        if producer_id:
            try:
                data = slack_get("conversations.history", {
                    "channel": cfg["slack_channel"], "limit": 100, "oldest": last_ts,
                })
                msgs = data.get("messages", [])
                if msgs:
                    newest = max(float(m.get("ts", 0)) for m in msgs)
                    state["slack_ts"] = str(newest)
                    log(f"  quiet: skipped {len(msgs)} messages, updated ts to {newest}")
            except Exception as e:
                log(f"  quiet: Slack API error: {e}")
    else:
        new_ts = check_slack(state)
        state["slack_ts"] = new_ts

        scan_bot_promises(state)

        file_updates = check_team_files(state)
        state.update(file_updates)

    # Flush Slack notification queue (dedup, rate-limited)
    flush_slack_queue()

    write_state(state)
    log("=== done ===")


if __name__ == "__main__":
    main()
