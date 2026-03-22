#!/bin/bash
# task_decomposer.sh — Auto-decompose stalled tasks via local LLM
# Zero Claude-token: uses Ollama only.
# Usage: source lib/task_decomposer.sh; aau_decompose_stale_task <member>
# Returns: 0 if decomposed, 1 if failed

# Requires: common.sh already sourced

_DECOMPOSER_OLLAMA_URL="${AAU_LOCAL_LLM_URL:-http://localhost:11434/api/generate}"
_DECOMPOSER_OLLAMA_MODEL="${AAU_LOCAL_LLM_MODEL:-gemma2:9b}"

aau_decompose_stale_task() {
    local member="$1"
    local tasks_file="$AAU_PROJECT_ROOT/team/$member/tasks.md"
    local progress_file="$AAU_PROJECT_ROOT/team/$member/progress.md"

    if [[ ! -f "$tasks_file" ]]; then
        aau_log "decompose: tasks.md not found for $member"
        return 1
    fi

    # Extract the IN_PROGRESS task
    local stale_line
    stale_line=$(grep -E '^### TASK-[0-9]+.*\[IN_PROGRESS\]' "$tasks_file" | head -1)
    if [[ -z "$stale_line" ]]; then
        aau_log "decompose: no IN_PROGRESS task for $member"
        return 1
    fi

    local task_id
    task_id=$(echo "$stale_line" | grep -oE 'TASK-[0-9]+')
    local task_title
    task_title=$(echo "$stale_line" | sed -E 's/^### TASK-[0-9]+ //' | sed 's/ *\[IN_PROGRESS\].*//')

    # Extract task body (up to 30 lines between this header and next ### or EOF)
    local task_body
    task_body=$(sed -n "/^### ${task_id}/,/^### TASK-/{/^### TASK-/!p}" "$tasks_file" | head -30)

    aau_log "decompose: splitting $task_id ($task_title) for $member"

    # Call Ollama for decomposition
    local result
    result=$(python3 - "$_DECOMPOSER_OLLAMA_URL" "$_DECOMPOSER_OLLAMA_MODEL" \
        "$task_id" "$task_title" "$task_body" "$member" << 'PYEOF'
import json, sys, urllib.request, re, time

url = sys.argv[1]
model = sys.argv[2]
task_id = sys.argv[3]
task_title = sys.argv[4]
task_body = sys.argv[5]
member = sys.argv[6]

prompt = f"""以下のタスクが大きすぎて1セッションで完了できません。2-3個のサブタスクに分割してください。

元タスク: {task_id} {task_title}
内容:
{task_body[:500]}

ルール:
- 各サブタスクは~15-20ターン（10分以内）で完了できるサイズ
- 1サブタスク=1つの明確な成果物
- 担当者: {member}
- 出力形式（1行1サブタスク、厳守）:
SUBTASK: タスク名 (~Nt)

例:
SUBTASK: DBマイグレーション作成 (~15t)
SUBTASK: APIエンドポイント実装 (~20t)
SUBTASK: テスト作成・実行 (~15t)
"""

body = json.dumps({{"model": model, "prompt": prompt, "stream": False}}).encode()
req = urllib.request.Request(url, data=body, headers={{"Content-Type": "application/json"}})
try:
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read())
    raw = data.get("response", "")
    subtasks = []
    for line in raw.strip().splitlines():
        m = re.match(r'SUBTASK:\s*(.+)', line.strip())
        if m:
            subtasks.append(m.group(1).strip())
    if not subtasks:
        print("ERROR:no_subtasks")
        sys.exit(1)

    # Generate task entries
    now = int(time.time())
    entries = []
    for i, st in enumerate(subtasks[:3]):  # max 3 subtasks
        new_id = f"TASK-{now + i}"
        entries.append(f"### {new_id} {task_id}-Part{i+1}: {st} [PENDING]")
        entries.append(f"**元タスク**: {task_id} ({task_title})")
        entries.append(f"**担当**: {member}")
        entries.append("")

    print("OK")
    for e in entries:
        print(e)
except Exception as e:
    print(f"ERROR:{e}")
    sys.exit(1)
PYEOF
    )

    if [[ -z "$result" ]] || echo "$result" | head -1 | grep -q "^ERROR:"; then
        aau_log "decompose: Ollama failed: $(echo "$result" | head -1)"
        aau_jlog "warn" "decompose_failed" "\"member\":\"$member\",\"task\":\"$task_id\""
        return 1
    fi

    # Mark original task as [DECOMPOSED]
    if [[ "$AAU_PLATFORM" == "Darwin" ]]; then
        sed -i '' "s/### ${task_id}.*\[IN_PROGRESS\]/### ${task_id} ${task_title} [DECOMPOSED]/" "$tasks_file"
    else
        sed -i "s/### ${task_id}.*\[IN_PROGRESS\]/### ${task_id} ${task_title} [DECOMPOSED]/" "$tasks_file"
    fi

    # Append new subtasks (skip first "OK" line)
    echo "$result" | tail -n +2 >> "$tasks_file"

    # Update progress.md
    echo "[$(date '+%Y-%m-%d %H:%M')] ${task_id} auto-decomposed into subtasks" >> "$progress_file"

    local subtask_count
    subtask_count=$(echo "$result" | grep -c '### TASK-')
    aau_log "decompose: $task_id → $subtask_count subtasks"
    aau_jlog "info" "decompose_success" "\"member\":\"$member\",\"task\":\"$task_id\",\"subtasks\":$subtask_count"
    return 0
}
