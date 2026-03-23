#!/bin/bash
# dashboard.sh — Auto-generate team dashboard from tasks.md + pipeline.json
# Zero-token: pure bash + python3, no LLM calls.
# Usage: source lib/dashboard.sh; aau_update_dashboard

# Requires: common.sh already sourced

# Generate team/dashboard.md from current project state
aau_update_dashboard() {
    local team_dir="$AAU_PROJECT_ROOT/team"
    local dashboard="$team_dir/dashboard.md"
    local pipeline="$team_dir/pipeline.json"
    local project_name="${AAU_PROJECT_NAME:-$(basename "$AAU_PROJECT_ROOT")}"

    # Collect member list
    local members=""
    for m in $(aau_team_members); do
        members="${members}${m} "
    done

    python3 - "$AAU_PROJECT_ROOT" "$dashboard" "$pipeline" "$project_name" $members << 'PYEOF'
import sys, re, json, os
from datetime import datetime
from pathlib import Path

project_root = Path(sys.argv[1])
dashboard_path = sys.argv[2]
pipeline_path = sys.argv[3]
project_name = sys.argv[4]
members = sys.argv[5:]

team_dir = project_root / "team"
now = datetime.now().strftime("%Y-%m-%d %H:%M")

# --- Per-member task status ---
def get_member_status(member):
    tasks_file = team_dir / member / "tasks.md"
    if not tasks_file.exists():
        return ("—", "—", "IDLE")
    content = tasks_file.read_text()
    lines = content.split("\n")
    # Priority: IN_PROGRESS > NEEDS_EVIDENCE > PENDING > BLOCKED > IDLE
    for status_label in ["IN_PROGRESS", "NEEDS_EVIDENCE", "PENDING", "BLOCKED"]:
        for line in lines:
            if not line.startswith("### TASK-"):
                continue
            tag = f"[{status_label}]"
            if tag in line or (status_label == "BLOCKED" and "[BLOCKED" in line):
                m = re.search(r'###\s+(TASK-\S+):?\s*(.*?)\s*\[', line)
                if m:
                    summary = m.group(2).strip().rstrip(':').strip()[:50]
                    if not summary:
                        # Try extracting from bracket content after status
                        # e.g., ### TASK-018: アート試作 [STATUS]
                        # or look for first **目的** line after this task header
                        idx = lines.index(line)
                        for j in range(idx+1, min(idx+10, len(lines))):
                            if lines[j].startswith("**目的**") or lines[j].startswith("**背景**"):
                                summary = re.sub(r'\*\*.*?\*\*:?\s*', '', lines[j])[:40]
                                break
                    return (m.group(1), summary if summary else m.group(1), status_label)
    return ("—", "—", "IDLE")

rows = []
for member in members:
    if member == "director":
        continue
    tid, summary, status = get_member_status(member)
    rows.append(f"| {member.capitalize()} | {tid} | {summary} | {status} |")

# --- Pipeline info (optional) ---
phase_section = ""
progress_section = ""
pipeline_view = ""
has_pipeline = os.path.exists(pipeline_path)

if has_pipeline:
    try:
        with open(pipeline_path) as f:
            pipe = json.load(f)
        current = pipe.get("current_phase", "?")
        phases = pipe.get("phases", {})
        if current in phases:
            info = phases[current]
            phase_name = info.get("name", "不明")
            phase_section = f"**Phase {current} — {phase_name}**"

            # Progress
            tasks = info.get("tasks", {})
            total = len(tasks)
            done = sum(1 for t in tasks.values() if t.get("status") == "DONE")
            pct = int(done / total * 100) if total > 0 else 0
            bar_filled = int(pct / 100 * 30)
            bar = "█" * bar_filled + " " * (30 - bar_filled)
            progress_section = f"完了タスク: {done} / {total}\n[{bar}] {pct}%"

        # Pipeline view
        lines = []
        for pid, pinfo in phases.items():
            s = pinfo.get("status", "WAITING")
            if s == "DONE":
                icon = "✅ DONE"
            elif pid == current:
                icon = "◀ 現在"
            else:
                icon = "待機"
            lines.append(f"[Phase {pid}  {pinfo.get('name', '')}]  {icon}")
        pipeline_view = "\n".join(lines)
    except Exception:
        has_pipeline = False

# Fallback: use roadmap.md
if not phase_section:
    roadmap = team_dir / "director" / "roadmap.md"
    if roadmap.exists():
        rm_content = roadmap.read_text()
        # Find current phase line (◀ or 現在 or IN_PROGRESS)
        for line in rm_content.split("\n"):
            if "現在" in line or "◀" in line or "IN_PROGRESS" in line:
                phase_section = line.strip().lstrip("#").lstrip(" ").lstrip("|").strip()
                break
        if not phase_section:
            # Fallback: first ## heading
            for line in rm_content.split("\n"):
                if line.startswith("## "):
                    phase_section = line[3:].strip()
                    break
    if not phase_section:
        phase_section = "(フェーズ情報なし)"

# --- Status.md fallback for phase ---
if phase_section == "(フェーズ情報なし)":
    status_file = team_dir / "director" / "status.md"
    if status_file.exists():
        for line in status_file.read_text().split("\n"):
            if "フェーズ" in line or "phase" in line.lower():
                phase_section = line.strip().lstrip("#").strip()
                break

# --- Blockers ---
blockers = []
for member in members:
    if member == "director":
        continue
    tasks_file = team_dir / member / "tasks.md"
    if tasks_file.exists():
        for line in tasks_file.read_text().split("\n"):
            if re.match(r'^###\s+TASK-.*\[BLOCKED', line):
                blockers.append(f"- **{member}**: {line.strip()}")

blocker_text = "\n".join(blockers) if blockers else "なし"

# --- Approvals ---
approval_text = ""
approvals_file = team_dir / "director" / "approvals.md"
if approvals_file.exists():
    content = approvals_file.read_text()
    pending = [l for l in content.split("\n") if l.startswith("## AP-")]
    pending_entries = []
    lines_list = content.split("\n")
    for i, line in enumerate(lines_list):
        if line.startswith("## AP-"):
            # Check next line for status
            if i + 1 < len(lines_list) and "PENDING" in lines_list[i + 1]:
                pending_entries.append(line[3:].strip())
    if pending_entries:
        approval_text = "\n\n---\n\n## 承認待ち\n\n" + "\n".join(f"- {e}" for e in pending_entries)

# --- Generate dashboard ---
dashboard = f"""# {project_name} チームダッシュボード

> **最終更新**: {now}
> **更新者**: auto (aau_update_dashboard)

---

## 現在のフェーズ

{phase_section}

---

## チーム状態

| エージェント | タスクID | 内容 | ステータス |
|------------|---------|------|----------|
{chr(10).join(rows)}

---

## ブロッカー

{blocker_text}{approval_text}"""

if progress_section:
    dashboard += f"""

---

## フェーズ進捗

```
{progress_section}
```"""

if pipeline_view:
    dashboard += f"""

---

## パイプライン

```
{pipeline_view}
```"""

Path(dashboard_path).write_text(dashboard + "\n")
PYEOF

    aau_log "dashboard updated: $dashboard"
}

# Compact dashboard summary for Slack notifications
aau_dashboard_summary() {
    local max_chars="${1:-${AAU_NOTIFICATION_REPORT_MAX_CHARS:-200}}"
    local team_dir="$AAU_PROJECT_ROOT/team"
    local pipeline="$team_dir/pipeline.json"

    local members=""
    for m in $(aau_team_members); do
        [[ "$m" == "director" ]] && continue
        members="${members}${m} "
    done

    python3 - "$AAU_PROJECT_ROOT" "$pipeline" "$max_chars" $members << 'PYEOF'
import sys, re, json, os
from pathlib import Path

project_root = Path(sys.argv[1])
pipeline_path = sys.argv[2]
max_chars = int(sys.argv[3])
members = sys.argv[4:]

team_dir = project_root / "team"
parts = []

# Phase info
if os.path.exists(pipeline_path):
    try:
        pipe = json.load(open(pipeline_path))
        cur = pipe["current_phase"]
        info = pipe["phases"][cur]
        tasks = info.get("tasks", {})
        total = len(tasks)
        done = sum(1 for t in tasks.values() if t.get("status") == "DONE")
        parts.append(f"Phase {cur} {info['name']} ({done}/{total})")
    except Exception:
        pass

# Per-member one-liner
for member in members:
    tasks_file = team_dir / member / "tasks.md"
    if not tasks_file.exists():
        parts.append(f"{member}: IDLE")
        continue
    content = tasks_file.read_text()
    for status in ["IN_PROGRESS", "PENDING", "BLOCKED"]:
        tag = f"[{status}]"
        found = False
        for line in content.split("\n"):
            if line.startswith("### TASK-") and tag in line:
                m = re.search(r'TASK-\S+:?\s*(.*?)\s*\[', line)
                summary = m.group(1)[:25] if m else ""
                parts.append(f"{member}: {summary} [{status}]")
                found = True
                break
        if found:
            break
    else:
        parts.append(f"{member}: IDLE")

result = " | ".join(parts)
if len(result) > max_chars:
    result = result[:max_chars-3] + "..."
print(result)
PYEOF
}
