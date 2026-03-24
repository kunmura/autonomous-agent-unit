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
# Enhanced: reports deliverables (output files, screenshots) to Slack
aau_followup_done() {
    local team_dir="$AAU_PROJECT_ROOT/team"
    local roadmap="$team_dir/director/roadmap.md"
    local status_file="$team_dir/director/status.md"
    local reported_file="${AAU_TMP}/${AAU_PREFIX}_reported_done_tasks"

    # Identify NEWLY completed tasks (not previously reported)
    local new_done_json
    new_done_json=$(python3 - "$AAU_PROJECT_ROOT" "$reported_file" << 'PYDETECT'
import re, sys, json
from pathlib import Path

root = Path(sys.argv[1])
reported_path = Path(sys.argv[2])
team_dir = root / "team"

# Load already-reported task IDs
reported = set()
if reported_path.exists():
    reported = set(reported_path.read_text().strip().splitlines())

# Scan for DONE tasks and find new ones
new_tasks = []
all_done_ids = []
for member_dir in sorted(team_dir.iterdir()):
    if not member_dir.is_dir() or member_dir.name == "director":
        continue
    tf = member_dir / "tasks.md"
    if not tf.exists():
        continue
    member = member_dir.name
    for line in tf.read_text(errors="ignore").splitlines():
        m = re.match(r'^### (TASK-\d+)\s+(.+?)\s*\[DONE\]', line)
        if not m:
            continue
        task_id = m.group(1)
        title = m.group(2).strip()
        key = f"{member}/{task_id}"
        all_done_ids.append(key)
        if key in reported:
            continue
        # Find output files
        out_dir = member_dir / "output"
        images = []
        texts = []
        other = []
        md_summary = ""
        if out_dir.is_dir():
            for f in sorted(out_dir.iterdir()):
                if not f.name.startswith(task_id):
                    continue
                ext = f.suffix.lower()
                if ext in ('.png', '.jpg', '.jpeg', '.gif', '.webp'):
                    images.append(str(f))
                elif ext == '.md':
                    texts.append(str(f))
                    # Extract summary (first 5 content lines)
                    try:
                        lines = [l.strip() for l in f.read_text(errors="ignore").splitlines()
                                 if l.strip() and not l.strip().startswith('#') and not l.strip().startswith('---')]
                        md_summary = " ".join(lines[:3])[:200]
                    except:
                        pass
                elif ext in ('.pptx', '.pdf', '.xlsx'):
                    other.append(str(f))
            # Also check for screenshot subdirectories
            ss_dir = out_dir / f"{task_id}_screenshots"
            if ss_dir.is_dir():
                for f in sorted(ss_dir.iterdir()):
                    if f.suffix.lower() in ('.png', '.jpg', '.jpeg'):
                        images.append(str(f))
        new_tasks.append({
            "member": member,
            "task_id": task_id,
            "title": title,
            "key": key,
            "images": images[:5],
            "texts": texts,
            "other": other,
            "md_summary": md_summary,
        })

print(json.dumps({"new": new_tasks, "total_done": len(all_done_ids)}))
PYDETECT
    )

    local total_done new_count
    total_done=$(echo "$new_done_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['total_done'])" 2>/dev/null || echo 0)
    new_count=$(echo "$new_done_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['new']))" 2>/dev/null || echo 0)

    if [[ "$total_done" -eq 0 ]]; then
        aau_log "followup_done: no DONE tasks found"
        return 0
    fi

    if [[ "$new_count" -eq 0 ]]; then
        aau_log "followup_done: $total_done DONE tasks, all already reported"
        return 0
    fi

    local done_count="$new_count"

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

    # Build detailed notification with deliverables
    local msg="[完了報告] ${new_count}件完了"
    local all_images=""
    local reported_keys=""

    # Parse each new task and build message
    while IFS= read -r task_json; do
        [[ -z "$task_json" ]] && continue
        local t_member t_id t_title t_summary t_images t_texts t_other
        t_member=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['member'])" 2>/dev/null)
        t_id=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['task_id'])" 2>/dev/null)
        t_title=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])" 2>/dev/null)
        t_summary=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['md_summary'])" 2>/dev/null)
        t_images=$(echo "$task_json" | python3 -c "import sys,json; print('\n'.join(json.load(sys.stdin)['images']))" 2>/dev/null)
        t_texts=$(echo "$task_json" | python3 -c "import sys,json; print('\n'.join(json.load(sys.stdin)['texts']))" 2>/dev/null)
        t_other=$(echo "$task_json" | python3 -c "import sys,json; print('\n'.join(json.load(sys.stdin)['other']))" 2>/dev/null)
        local t_key="${t_member}/${t_id}"

        msg="${msg}\n\n*${t_member}*: ${t_id} ${t_title}"

        # Add summary from .md files
        if [[ -n "$t_summary" ]]; then
            msg="${msg}\n　${t_summary:0:200}"
        fi

        # List text deliverables
        if [[ -n "$t_texts" ]]; then
            while IFS= read -r tf; do
                [[ -n "$tf" ]] && msg="${msg}\n　:page_facing_up: $(basename "$tf")"
            done <<< "$t_texts"
        fi

        # List image deliverables
        local img_count=0
        if [[ -n "$t_images" ]]; then
            local img_names=""
            while IFS= read -r img; do
                [[ -n "$img" ]] || continue
                img_names="${img_names} $(basename "$img")"
                all_images="${all_images}${img}|${t_id} $(basename "$img")\n"
                img_count=$((img_count + 1))
            done <<< "$t_images"
            if [[ "$img_count" -gt 0 ]]; then
                msg="${msg}\n　:frame_with_picture: ${img_count}枚 —${img_names}"
            fi
        fi

        # List other deliverables
        if [[ -n "$t_other" ]]; then
            while IFS= read -r of; do
                [[ -n "$of" ]] && msg="${msg}\n　:file_folder: $(basename "$of")"
            done <<< "$t_other"
        fi

        reported_keys="${reported_keys}${t_key}\n"
    done < <(echo "$new_done_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data['new']:
    print(json.dumps(t))
" 2>/dev/null)

    if [[ "${new_tasks_created:-0}" -gt 0 ]]; then
        msg="${msg}\n\n次タスク${new_tasks_created}件をロードマップから自動配分しました"
    fi

    # Post text notification
    aau_notify "$msg"

    # Upload images to Slack (max 10 total)
    local upload_count=0
    local upload_max=10
    if [[ -n "$all_images" ]]; then
        while IFS='|' read -r img_path img_title; do
            [[ -z "$img_path" || "$upload_count" -ge "$upload_max" ]] && continue
            if aau_upload_file "$img_path" "$img_title"; then
                upload_count=$((upload_count + 1))
                aau_log "followup_done: uploaded $img_title"
            fi
        done < <(echo -e "$all_images")
    fi

    # Mark tasks as reported
    if [[ -n "$reported_keys" ]]; then
        echo -e "$reported_keys" | grep -v '^$' >> "$reported_file"
    fi

    aau_jlog "info" "followup_done_zero_token" "\"new_done\":$new_count,\"total_done\":$total_done,\"created\":${new_tasks_created:-0},\"uploaded\":$upload_count"
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

if not active_sprint:
    # No ### SPRINT: formatted sprint found — roadmap uses a different format
    print("NO_SPRINT_FORMAT")
    sys.exit(0)

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

    if [[ "$result" == "NO_SPRINT_FORMAT" ]]; then
        # Roadmap exists but doesn't use ### SPRINT: format — wait for director/producer
        aau_log "idle_all: roadmap has no SPRINT-format sections, waiting for instructions"
        aau_jlog "info" "idle_all_no_sprint_format"
        # No notification — heartbeat covers "system alive" status.
        # Sending "waiting" messages repeatedly annoys the producer.
        return 0
    fi

    if [[ "$result" == "SPRINT_COMPLETE" ]]; then
        source "$SCRIPT_DIR/approval.sh"
        # Dedup: skip if the last approval was created within cooldown (default 1h)
        local _approval_cooldown="${AAU_APPROVAL_DEDUP_COOLDOWN:-3600}"
        local _last_created
        _last_created=$(grep -E '^created:' "$_AAU_APPROVALS_FILE" 2>/dev/null | tail -1 | sed 's/created: //')
        if [[ -n "$_last_created" ]]; then
            local _last_ts
            _last_ts=$(date -j -f "%Y-%m-%d %H:%M" "$_last_created" +%s 2>/dev/null || date -d "$_last_created" +%s 2>/dev/null || echo 0)
            local _now_ts
            _now_ts=$(date +%s)
            local _age=$(( _now_ts - _last_ts ))
            if [[ "$_age" -lt "$_approval_cooldown" ]]; then
                aau_log "idle_all: sprint complete but last approval was ${_age}s ago (cooldown=${_approval_cooldown}s), skipping"
                aau_jlog "info" "idle_all_approval_dedup" "\"age\":$_age,\"cooldown\":$_approval_cooldown"
                return 0
            fi
        fi
        # Register approval (PENDING in approvals.md)
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
        aau_log "idle_all: all roadmap items already assigned"
    fi
}
