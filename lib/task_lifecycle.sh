#!/bin/bash
# task_lifecycle.sh — Zero-token task lifecycle management
# Replaces Claude-powered DONE_FOLLOWUP and IDLE_ALL with bash+python3.
# Usage: source lib/task_lifecycle.sh; aau_followup_done / aau_idle_all

# Requires: common.sh already sourced

# Check if any approval is pending (returns 0 if pending, 1 if clear)
_aau_approval_pending() {
    local approvals_file="$AAU_PROJECT_ROOT/team/director/approvals.md"
    [[ -f "$approvals_file" ]] && grep -q '^status: PENDING' "$approvals_file" 2>/dev/null
}

# ─── DONE_FOLLOWUP (zero-token) ─────────────────────────────────────
# Detect completed tasks, update roadmap, create next tasks from roadmap
aau_followup_done() {
    local team_dir="$AAU_PROJECT_ROOT/team"
    local roadmap="$team_dir/director/roadmap.md"
    local status_file="$team_dir/director/status.md"

    # Collect completed task info
    local done_summary=""
    local done_count=0
    for _member in $(aau_team_members); do
        local tf="$team_dir/$_member/tasks.md"
        [[ -f "$tf" ]] || continue
        local member_done
        member_done=$(grep -cE '^### TASK-.*\[DONE\]' "$tf" 2>/dev/null || true)
        if [[ "${member_done:-0}" -gt 0 ]]; then
            done_count=$(( done_count + member_done ))
            # Get latest done task titles for notification
            local latest
            latest=$(grep -E '^### TASK-.*\[DONE\]' "$tf" | tail -1 | sed -E 's/^### TASK-[0-9]+ //' | sed 's/ \[DONE\].*//')
            done_summary="${done_summary}${_member}: ${latest}\n"
        fi
    done

    if [[ "$done_count" -eq 0 ]]; then
        aau_log "followup_done: no DONE tasks found"
        return 0
    fi

    # Update roadmap checkboxes (if roadmap exists)
    local new_tasks_created=0
    if [[ -f "$roadmap" ]]; then
        new_tasks_created=$(python3 - "$AAU_PROJECT_ROOT" << 'PYEOF'
import re, sys, time
from pathlib import Path

root = Path(sys.argv[1])
roadmap_path = root / "team/director/roadmap.md"
roadmap = roadmap_path.read_text(errors="ignore")
team_dir = root / "team"

# Find all DONE task titles to match against roadmap
done_titles = {}
for member_dir in sorted(team_dir.iterdir()):
    if not member_dir.is_dir() or member_dir.name == "director":
        continue
    tf = member_dir / "tasks.md"
    if not tf.exists():
        continue
    for line in tf.read_text(errors="ignore").splitlines():
        m = re.match(r'^### (TASK-\d+)\s+(.+?)\s*\[DONE\]', line)
        if m:
            done_titles[m.group(1)] = (member_dir.name, m.group(2).strip())

# Check off roadmap items that match done tasks
updated = False
lines = roadmap.split('\n')
for i, line in enumerate(lines):
    if line.strip().startswith('- [ ]'):
        for task_id, (member, title) in done_titles.items():
            # Match by task ID or partial title
            if task_id in line or any(w in line for w in title.split()[:3] if len(w) > 3):
                lines[i] = line.replace('- [ ]', '- [x]', 1)
                updated = True
                break

if updated:
    roadmap_path.write_text('\n'.join(lines))

# Check approval gate
status_path = root / "team/director/status.md"
approval_pending = False
if status_path.exists():
    st = status_path.read_text()
    approval_pending = "承認待ち" in st or "approval pending" in st.lower()

if approval_pending:
    print(0)  # No new tasks created during approval
    sys.exit(0)

# Find next unchecked items in active sprint and create tasks
created = 0
active_sprint = None
in_schedule = False
current_member_map = {}  # item text → assigned member

for line in lines:
    sp = re.match(r'^### SPRINT:\s*(.+)', line)
    st = re.match(r'^status:\s*(.+)', line.strip())
    if sp:
        active_sprint = sp.group(1).strip()
    elif st and st.group(1).strip() == "IN_PROGRESS" and active_sprint:
        in_schedule = True
    elif line.strip().startswith('- [ ]') and in_schedule:
        # Parse: "- [ ] Description → member (~Nt)"
        item = line.strip()[5:].strip()  # Remove "- [ ] "
        member_match = re.search(r'→\s*(\w+)', item)
        if member_match:
            member = member_match.group(1)
            task_desc = re.sub(r'\s*→\s*\w+.*$', '', item).strip()

            # Check if task already exists in member's tasks.md
            mtf = team_dir / member / "tasks.md"
            if mtf.exists() and task_desc[:30] in mtf.read_text():
                continue

            # Create task
            task_id = f"TASK-{int(time.time()) + created}"
            turns = ""
            turns_match = re.search(r'\(~(\d+)t\)', item)
            if turns_match:
                turns = f" (~{turns_match.group(1)}t)"

            entry = f"\n### {task_id} {task_desc}{turns} [PENDING]\n**ロードマップ**: {active_sprint}\n**担当**: {member}\n\n"
            with open(mtf, "a") as f:
                f.write(entry)
            created += 1
    elif line.strip().startswith('- [x]') and in_schedule:
        continue  # Skip completed items
    elif re.match(r'^###\s', line) and in_schedule and not line.strip().startswith('- '):
        in_schedule = False  # Left the active sprint

print(created)
PYEOF
        )
        aau_log "followup_done: roadmap updated, $new_tasks_created new tasks created"
    fi

    # Notify
    local msg="[完了報告] ${done_count}件完了"
    if [[ -n "$done_summary" ]]; then
        msg="${msg}\n$(echo -e "$done_summary" | head -5)"
    fi
    if [[ "${new_tasks_created:-0}" -gt 0 ]]; then
        msg="${msg}\n次タスク${new_tasks_created}件をロードマップから自動配分しました"
    fi
    aau_notify "$msg"
    aau_jlog "info" "followup_done_zero_token" "\"done\":$done_count,\"created\":${new_tasks_created:-0}"
}

# ─── IDLE_ALL (zero-token) ───────────────────────────────────────────
# When all members are idle, auto-distribute next roadmap items or wait
aau_idle_all() {
    local team_dir="$AAU_PROJECT_ROOT/team"
    local roadmap="$team_dir/director/roadmap.md"

    # Approval gate check — silent wait (APPROVAL_REMINDER handles notifications)
    if _aau_approval_pending; then
        aau_log "idle_all: approval pending, silent wait (reminder handles notifications)"
        aau_jlog "info" "idle_all_approval_pending"
        return 0
    fi

    # No roadmap → wait for producer instructions
    if [[ ! -f "$roadmap" ]]; then
        aau_notify "待機中。プロデューサーの指示をお待ちしています。"
        aau_log "idle_all: no roadmap, waiting"
        aau_jlog "info" "idle_all_no_roadmap"
        return 0
    fi

    # Parse roadmap for unchecked items in active sprint
    local result
    result=$(python3 - "$AAU_PROJECT_ROOT" << 'PYEOF'
import re, sys, time
from pathlib import Path

root = Path(sys.argv[1])
roadmap = (root / "team/director/roadmap.md").read_text(errors="ignore")
team_dir = root / "team"

# Find unchecked items in IN_PROGRESS sprint
active_sprint = None
in_schedule = False
unchecked = []

for line in roadmap.splitlines():
    sp = re.match(r'^### SPRINT:\s*(.+)', line)
    st = re.match(r'^status:\s*(.+)', line.strip())
    if sp:
        active_sprint = sp.group(1).strip()
    elif st and st.group(1).strip() == "IN_PROGRESS" and active_sprint:
        in_schedule = True
    elif line.strip().startswith('- [ ]') and in_schedule:
        unchecked.append(line.strip()[5:].strip())
    elif re.match(r'^###\s', line) and in_schedule and not line.strip().startswith('- '):
        in_schedule = False

if not unchecked:
    print("SPRINT_COMPLETE")
    sys.exit(0)

# Create tasks for unchecked items
created = 0
for item in unchecked:
    member_match = re.search(r'→\s*(\w+)', item)
    if not member_match:
        continue
    member = member_match.group(1)
    task_desc = re.sub(r'\s*→\s*\w+.*$', '', item).strip()

    mtf = team_dir / member / "tasks.md"
    if not mtf.exists():
        continue
    if task_desc[:30] in mtf.read_text():
        continue

    task_id = f"TASK-{int(time.time()) + created}"
    turns = ""
    turns_match = re.search(r'\(~(\d+)t\)', item)
    if turns_match:
        turns = f" (~{turns_match.group(1)}t)"

    entry = f"\n### {task_id} {task_desc}{turns} [PENDING]\n**ロードマップ**: {active_sprint}\n**担当**: {member}\n\n"
    with open(mtf, "a") as f:
        f.write(entry)
    created += 1

print(f"CREATED:{created}")
PYEOF
    )

    if [[ "$result" == "SPRINT_COMPLETE" ]]; then
        # Register approval (PENDING in approvals.md)
        source "$SCRIPT_DIR/approval.sh"
        source "$SCRIPT_DIR/task_summarizer.sh"
        local _roadmap_info
        _roadmap_info=$(aau_roadmap_summary 2>/dev/null)
        aau_create_approval "スプリント完了 — 次フェーズ移行" "${_roadmap_info}"
        aau_log "idle_all: sprint complete, approval request created"
        aau_jlog "info" "idle_all_sprint_complete"
        # Signal director_autonomous to create PPT via Claude session
        echo "APPROVAL_PPT" > "${AAU_TMP}/${AAU_PREFIX}_trigger_approval_ppt"
        return 0
    fi

    local created_count
    created_count=$(echo "$result" | grep -oE 'CREATED:[0-9]+' | cut -d: -f2)
    if [[ "${created_count:-0}" -gt 0 ]]; then
        source "$SCRIPT_DIR/task_summarizer.sh" 2>/dev/null
        local summary
        summary=$(aau_task_summary_compact 1 2>/dev/null)
        aau_notify "[タスク配分] ロードマップから${created_count}件のタスクを配分しました\n${summary}"
        aau_log "idle_all: created $created_count tasks from roadmap"
        aau_jlog "info" "idle_all_tasks_created" "\"created\":$created_count"
    else
        aau_notify "待機中。ロードマップの全アイテムは配分済みです。"
        aau_log "idle_all: all roadmap items already assigned"
    fi
}
