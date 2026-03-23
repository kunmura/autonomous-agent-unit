#!/bin/bash
# pipeline.sh — Phase-based project pipeline management
# Zero-token: pure bash + python3, no LLM calls.
# Optional: only activates when team/pipeline.json exists.
# Usage: source lib/pipeline.sh

# Requires: common.sh already sourced

_AAU_PIPELINE_FILE="$AAU_PROJECT_ROOT/team/pipeline.json"

# Check if pipeline is available
aau_pipeline_exists() {
    [[ -f "$_AAU_PIPELINE_FILE" ]]
}

# Returns: phase_id|phase_name|status|done_count|total_count
aau_pipeline_status() {
    if ! aau_pipeline_exists; then
        echo "none|no pipeline|N/A|0|0"
        return 1
    fi

    python3 - "$_AAU_PIPELINE_FILE" "$AAU_PROJECT_ROOT" << 'PYEOF'
import sys, json, re
from pathlib import Path

pipeline_path = sys.argv[1]
project_root = Path(sys.argv[2])
team_dir = project_root / "team"

pipe = json.load(open(pipeline_path))
cur = pipe.get("current_phase", "?")
phases = pipe.get("phases", {})

if cur not in phases:
    print(f"{cur}|不明|ERROR|0|0")
    sys.exit(0)

info = phases[cur]
name = info.get("name", "不明")
status = info.get("status", "WAITING")
tasks = info.get("tasks", {})

# Count done tasks by checking actual tasks.md files (source of truth)
total = len(tasks)
done = 0
for member_key, task_info in tasks.items():
    tid = task_info.get("id", "")
    if not tid:
        continue
    # Find the member name (strip _1, _2 suffixes)
    member = re.sub(r'_\d+$', '', member_key)
    tasks_file = team_dir / member / "tasks.md"
    if tasks_file.exists():
        content = tasks_file.read_text()
        # Check if this task is DONE in tasks.md
        pattern = rf'^###\s+{re.escape(tid)}.*\[DONE\]'
        if re.search(pattern, content, re.MULTILINE):
            done += 1

print(f"{cur}|{name}|{status}|{done}|{total}")
PYEOF
}

# Returns 0 if current phase is complete (all tasks DONE), 1 otherwise
aau_pipeline_check_complete() {
    if ! aau_pipeline_exists; then
        return 1
    fi

    local result
    result=$(aau_pipeline_status)
    local done total
    done=$(echo "$result" | cut -d'|' -f4)
    total=$(echo "$result" | cut -d'|' -f5)

    [[ "$total" -gt 0 && "$done" -ge "$total" ]]
}

# Advance pipeline to next phase
# Updates pipeline.json, creates tasks in members' tasks.md, notifies
aau_pipeline_advance() {
    if ! aau_pipeline_exists; then
        aau_log "pipeline: no pipeline.json, skip advance"
        return 1
    fi

    python3 - "$_AAU_PIPELINE_FILE" "$AAU_PROJECT_ROOT" << 'PYEOF'
import sys, json, re
from pathlib import Path
from datetime import datetime

pipeline_path = sys.argv[1]
project_root = Path(sys.argv[2])
team_dir = project_root / "team"

pipe = json.load(open(pipeline_path))
cur = pipe["current_phase"]
phases = pipe["phases"]
phase_keys = list(phases.keys())

if cur not in phases:
    print("ERROR: current phase not found")
    sys.exit(1)

# Mark current phase DONE
phases[cur]["status"] = "DONE"
phases[cur]["completed_at"] = datetime.now().isoformat(timespec="minutes")

# Collect done task IDs
done_ids = []
for task_info in phases[cur].get("tasks", {}).values():
    tid = task_info.get("id", "")
    if tid:
        done_ids.append(tid)
phases[cur]["tasks_done"] = done_ids

# Find next phase
cur_idx = phase_keys.index(cur)
if cur_idx + 1 >= len(phase_keys):
    print("FINAL: no next phase")
    with open(pipeline_path, "w") as f:
        json.dump(pipe, f, ensure_ascii=False, indent=2)
    sys.exit(0)

next_key = phase_keys[cur_idx + 1]
phases[next_key]["status"] = "IN_PROGRESS"
pipe["current_phase"] = next_key

# Create tasks for next phase in members' tasks.md
next_tasks = phases[next_key].get("tasks", {})
for member_key, task_info in next_tasks.items():
    summary = task_info.get("summary", "")
    if not summary:
        continue
    # Derive member name (strip _1, _2 suffixes)
    member = re.sub(r'_\d+$', '', member_key)
    tasks_file = team_dir / member / "tasks.md"

    # Generate task ID
    import time
    tid = f"TASK-{int(time.time())}"
    task_info["id"] = tid
    task_info["status"] = "PENDING"
    time.sleep(1)  # Ensure unique IDs

    # Append to tasks.md
    phase_name = phases[next_key].get("name", "")
    entry = f"\n---\n\n### {tid}: 【Phase {next_key}】{summary} [PENDING]\n**Phase**: {next_key} — {phase_name}\n**Priority**: P0\n"

    if tasks_file.exists():
        content = tasks_file.read_text()
        # Check if this summary already exists (prevent duplicates)
        if summary[:30] in content:
            continue
    else:
        tasks_file.parent.mkdir(parents=True, exist_ok=True)
        content = f"# {member} Tasks\n"

    with open(tasks_file, "a") as f:
        f.write(entry)

    print(f"CREATED: {tid} → {member} ({summary[:40]})")

with open(pipeline_path, "w") as f:
    json.dump(pipe, f, ensure_ascii=False, indent=2)

print(f"ADVANCED: {cur} → {next_key}")
PYEOF

    local result=$?
    if [[ "$result" -eq 0 ]]; then
        aau_log "pipeline advanced"
        aau_jlog "info" "pipeline_advanced"
    fi
    return $result
}

# Sync pipeline.json task statuses from tasks.md (source of truth)
aau_pipeline_sync() {
    if ! aau_pipeline_exists; then
        return 1
    fi

    python3 - "$_AAU_PIPELINE_FILE" "$AAU_PROJECT_ROOT" << 'PYEOF'
import sys, json, re
from pathlib import Path

pipeline_path = sys.argv[1]
project_root = Path(sys.argv[2])
team_dir = project_root / "team"

pipe = json.load(open(pipeline_path))
cur = pipe.get("current_phase", "")
if cur not in pipe.get("phases", {}):
    sys.exit(0)

tasks = pipe["phases"][cur].get("tasks", {})
changed = False

for member_key, task_info in tasks.items():
    tid = task_info.get("id", "")
    if not tid:
        continue
    member = re.sub(r'_\d+$', '', member_key)
    tasks_file = team_dir / member / "tasks.md"
    if not tasks_file.exists():
        continue
    content = tasks_file.read_text()
    for status in ["DONE", "IN_PROGRESS", "PENDING", "BLOCKED", "NEEDS_EVIDENCE"]:
        pattern = rf'^###\s+{re.escape(tid)}.*\[{status}\]'
        if re.search(pattern, content, re.MULTILINE):
            if task_info.get("status") != status:
                task_info["status"] = status
                changed = True
            break

if changed:
    with open(pipeline_path, "w") as f:
        json.dump(pipe, f, ensure_ascii=False, indent=2)
    print("synced")
PYEOF
}
