#!/bin/bash
# task_summarizer.sh — Generate human-readable task summaries using local LLM
# Zero Claude-token: uses Ollama only.
# Usage: source lib/task_summarizer.sh; aau_task_summary [cache_ttl_seconds]
# Output: prints task summary lines to stdout

# Requires: common.sh already sourced (for AAU_PROJECT_ROOT, AAU_TMP, AAU_PREFIX)

_AAU_SUMMARIZER_CACHE="${AAU_TMP}/${AAU_PREFIX}_task_summaries"
_AAU_SUMMARIZER_OLLAMA_URL="${AAU_LOCAL_LLM_URL:-http://localhost:11434/api/generate}"
_AAU_SUMMARIZER_OLLAMA_MODEL="${AAU_LOCAL_LLM_MODEL:-gemma2:9b}"

# Main: extract active tasks, summarize via Ollama, output formatted lines
# All logic in python3 to avoid bash variable collisions and parsing issues
aau_task_summary() {
    local cache_ttl="${1:-600}"
    local _now=$(date +%s)

    # Check cache
    if [[ -f "$_AAU_SUMMARIZER_CACHE" ]]; then
        local _cache_age=$(( _now - $(aau_file_mtime "$_AAU_SUMMARIZER_CACHE") ))
        if [[ "$_cache_age" -lt "$cache_ttl" ]]; then
            cat "$_AAU_SUMMARIZER_CACHE"
            return 0
        fi
    fi

    python3 - "$AAU_PROJECT_ROOT" "$_AAU_SUMMARIZER_OLLAMA_URL" "$_AAU_SUMMARIZER_OLLAMA_MODEL" "$_AAU_SUMMARIZER_CACHE" << 'PYEOF'
import json, os, re, sys, urllib.request
from pathlib import Path

project_root = Path(sys.argv[1])
ollama_url = sys.argv[2]
ollama_model = sys.argv[3]
cache_file = sys.argv[4]

team_dir = project_root / "team"
if not team_dir.exists():
    Path(cache_file).write_text("(タスクなし)")
    print("(タスクなし)")
    sys.exit(0)

# Extract ACTIVE tasks only (PENDING, IN_PROGRESS, NEEDS_EVIDENCE, BLOCKED)
ACTIVE_STATES = {"PENDING", "IN_PROGRESS", "NEEDS_EVIDENCE", "BLOCKED"}
tasks = []  # (member, task_id, state, title)

for member_dir in sorted(team_dir.iterdir()):
    if not member_dir.is_dir() or member_dir.name == "director":
        continue
    tf = member_dir / "tasks.md"
    if not tf.exists():
        continue
    for line in tf.read_text(errors="ignore").splitlines():
        m = re.match(r'^###\s+(TASK-\d+)\s+(.*?)(\[(.*?)\])', line)
        if not m:
            continue
        task_id = m.group(1)
        title = m.group(2).strip()
        state = m.group(4) or "UNKNOWN"
        if state not in ACTIVE_STATES:
            continue
        tasks.append((member_dir.name, task_id, state, title))

if not tasks:
    Path(cache_file).write_text("(アクティブタスクなし)")
    print("(アクティブタスクなし)")
    sys.exit(0)

# Build Ollama input — only active tasks, much smaller
ollama_input = "\n".join(f"{t[1]}: {t[3]}" for t in tasks)

# Call Ollama for short summaries
summaries = {}
try:
    prompt = f"""以下のタスク一覧の各タスクを15文字以内の日本語で要約せよ。
1行1タスク、「TASK-XXX: 要約」の形式のみ出力。他の説明は不要。

{ollama_input}"""

    body = json.dumps({"model": ollama_model, "prompt": prompt, "stream": False}).encode()
    req = urllib.request.Request(ollama_url, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read())
    raw = data.get("response", "")
    for line in raw.strip().splitlines():
        m2 = re.match(r'(TASK-\d+)\s*[:：]\s*(.+)', line.strip())
        if m2:
            summaries[m2.group(1)] = m2.group(2).strip()[:20]
except Exception:
    pass  # Fallback to title truncation

# Build output
lines = []
for member, task_id, state, title in tasks:
    short = summaries.get(task_id, title[:15])
    lines.append(f"{member} {task_id}[{state}] {short}")

output = "\n".join(lines)
Path(cache_file).write_text(output)
print(output)
PYEOF
}

# Compact summary for Slack (one-liner per member)
aau_task_summary_compact() {
    local _full
    _full=$(aau_task_summary "${1:-600}")
    if [[ "$_full" == *"タスクなし"* ]]; then
        echo "$_full"
        return 0
    fi
    echo "$_full" | awk '{
        member = $1
        sub(/^[^ ]+ /, "")
        if (member in lines) lines[member] = lines[member] ", " $0
        else lines[member] = $0
    }
    END {
        for (m in lines) print m ": " lines[m]
    }'
}
