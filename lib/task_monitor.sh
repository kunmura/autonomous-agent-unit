#!/bin/bash
# task_monitor.sh — Scan team task files and create trigger files
# Zero-token operation: pure bash, no LLM calls.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
aau_init_logging "task_monitor"

aau_log "=== task_monitor start ==="
aau_jlog "info" "start"

TEAM_DIR="$AAU_PROJECT_ROOT/team"

# ── Stale IN_PROGRESS cleanup (runs even during approval gate) ────────
# Reset IN_PROGRESS tasks to PENDING if progress.md hasn't been updated
# within STALE_INPROGRESS_THRESHOLD seconds. This prevents task accumulation.
STALE_INPROGRESS_THRESHOLD="${AAU_STALE_INPROGRESS_THRESHOLD:-3600}"
_NOW=$(date +%s)

for MEMBER in $(aau_team_members); do
    TASKS_FILE="$TEAM_DIR/$MEMBER/tasks.md"
    PROGRESS_FILE="$TEAM_DIR/$MEMBER/progress.md"

    if [[ ! -f "$TASKS_FILE" ]]; then
        continue
    fi

    IP_COUNT=$(grep -cE '^### TASK-.*\[IN_PROGRESS\]' "$TASKS_FILE" 2>/dev/null || true)
    if [[ "$IP_COUNT" -gt 3 ]]; then
        # >3 IN_PROGRESS is always abnormal — check time OR count threshold
        PROG_AGE=0
        if [[ -f "$PROGRESS_FILE" ]]; then
            PROG_AGE=$(( _NOW - $(aau_file_mtime "$PROGRESS_FILE") ))
        fi
        # Reset if: stale (>1h) OR excessive (>5 IN_PROGRESS regardless of time)
        if [[ "$PROG_AGE" -ge "$STALE_INPROGRESS_THRESHOLD" || "$IP_COUNT" -gt 5 ]]; then
            RESET_COUNT=$(python3 - "$TASKS_FILE" << 'PYEOF'
import sys, re
tasks_file = sys.argv[1]
with open(tasks_file, 'r') as f:
    lines = f.read().split('\n')
ip_indices = [i for i, l in enumerate(lines) if re.match(r'^###\s+TASK-\d+.*\[IN_PROGRESS\]', l)]
if len(ip_indices) <= 1:
    print(0)
    sys.exit(0)
keep = ip_indices[-1]
count = 0
for idx in ip_indices:
    if idx != keep:
        lines[idx] = lines[idx].replace('[IN_PROGRESS]', '[PENDING]')
        count += 1
with open(tasks_file, 'w') as f:
    f.write('\n'.join(lines))
print(count)
PYEOF
            )
            if [[ "${RESET_COUNT:-0}" -gt 0 ]]; then
                aau_log "$MEMBER: reset $RESET_COUNT stale IN_PROGRESS → PENDING (was $IP_COUNT)"
                aau_jlog "info" "stale_inprogress_reset" "\"member\":\"$MEMBER\",\"reset\":$RESET_COUNT,\"was\":$IP_COUNT"
            fi
        fi
    fi
done

# ── Approval gate (scoped) ──────────────────────────────────────────────
# Approval pending only blocks NEW task creation (enforced in task_lifecycle.sh
# and director templates). Existing PENDING tasks should still be executed by agents.
STATUS_FILE="$TEAM_DIR/director/status.md"
if [[ -f "$STATUS_FILE" ]] && grep -qiE '承認待ち|approval pending' "$STATUS_FILE" 2>/dev/null; then
    aau_log "APPROVAL GATE: active (new task creation blocked, existing tasks allowed)"
    aau_jlog "info" "approval_gate_active"
    # Do NOT clear triggers — agents should process existing PENDING tasks
fi

# ── promised.md PENDING → auto-convert (DISABLED: causes junk task spam) ──
# Re-enable only after promise detection in slack_monitor is fixed.
if false; then
# ── promised.md PENDING → auto-convert to assistant tasks ──────────
PROMISED="$TEAM_DIR/director/promised.md"
# Find the first member to use as promise assignee (prefer "assistant", fallback to first member)
PROMISE_ASSIGNEE=""
for _m in $(aau_team_members); do
    if [[ "$_m" == "assistant" ]]; then
        PROMISE_ASSIGNEE="assistant"
        break
    fi
    [[ -z "$PROMISE_ASSIGNEE" ]] && PROMISE_ASSIGNEE="$_m"
done

if [[ -f "$PROMISED" && -n "$PROMISE_ASSIGNEE" ]]; then
    ASSIGNEE_TASKS="$TEAM_DIR/$PROMISE_ASSIGNEE/tasks.md"
    PROMISE_COUNT=$(grep -cE '^\#\# \[PENDING\]' "$PROMISED" 2>/dev/null || echo 0)
    if [[ "$PROMISE_COUNT" -gt 0 ]]; then
        while IFS= read -r line; do
            # Extract content from "## [PENDING] YYYY-MM-DD HH:MM — content"
            CONTENT=$(echo "$line" | sed 's/^## \[PENDING\] [0-9-]* [0-9:]* — //')
            if [[ -n "$CONTENT" ]] && ! grep -qF "$CONTENT" "$ASSIGNEE_TASKS" 2>/dev/null; then
                TASK_ID="TASK-$(date +%s)"
                printf '\n### %s: [Promise] %s [PENDING]\n**Priority**: P0 — Director promised but not yet fulfilled\n**Deadline**: ASAP\nComplete the promised action and update promised.md entry to DONE.\n' \
                    "$TASK_ID" "$CONTENT" >> "$ASSIGNEE_TASKS"
                # Update promised.md: PENDING → IN_QUEUE
                LINE_NUM=$(grep -n '^\#\# \[PENDING\]' "$PROMISED" | grep -F "$CONTENT" | head -1 | cut -d: -f1)
                if [[ -n "$LINE_NUM" ]]; then
                    if [[ "$(uname -s)" == "Darwin" ]]; then
                        sed -i '' "${LINE_NUM}s/\[PENDING\]/[IN_QUEUE]/" "$PROMISED" 2>/dev/null || true
                    else
                        sed -i "${LINE_NUM}s/\[PENDING\]/[IN_QUEUE]/" "$PROMISED" 2>/dev/null || true
                    fi
                fi
                aau_log "promise → $PROMISE_ASSIGNEE task: $CONTENT"
                aau_jlog "info" "promise_to_task" "\"assignee\":\"$PROMISE_ASSIGNEE\",\"content\":\"${CONTENT:0:60}\""
            fi
        done < <(grep -E '^\#\# \[PENDING\]' "$PROMISED")
    fi
fi
fi  # end of disabled promise block

# ── Main trigger scan ─────────────────────────────────────────────────
for MEMBER in $(aau_team_members); do
    TASKS_FILE="$TEAM_DIR/$MEMBER/tasks.md"
    TRIGGER="${AAU_TMP}/${AAU_PREFIX}_trigger_${MEMBER}"

    if [[ ! -f "$TASKS_FILE" ]]; then
        continue
    fi

    # Count statuses only from task header lines (### TASK-XXX ... [STATUS])
    # Prevents false matches from body text like "ステータスを[IN_PROGRESS]→[DONE]に更新"
    PENDING=$(grep -cE '^### TASK-.*\[PENDING\]' "$TASKS_FILE" 2>/dev/null || true)
    INPROGRESS=$(grep -cE '^### TASK-.*\[IN_PROGRESS\]' "$TASKS_FILE" 2>/dev/null || true)
    NEEDS_EVIDENCE=$(grep -cE '^### TASK-.*\[NEEDS_EVIDENCE\]' "$TASKS_FILE" 2>/dev/null || true)
    BLOCKED=$(grep -cE '^### TASK-.*\[BLOCKED\]' "$TASKS_FILE" 2>/dev/null || true)

    # Exclude self-study/learning tasks from pending count (prevent unnecessary agent launch)
    REAL_PENDING=$(grep -E '^### TASK-.*\[PENDING\]' "$TASKS_FILE" 2>/dev/null | grep -v "自主学習" | wc -l | tr -d ' ')

    if [[ "$BLOCKED" -gt 0 ]]; then
        aau_log "$MEMBER: $BLOCKED BLOCKED task(s) detected"
        aau_jlog "warn" "blocked_detected" "\"member\":\"$MEMBER\",\"blocked\":$BLOCKED"
    fi

    if [[ "$REAL_PENDING" -gt 0 || "$INPROGRESS" -gt 0 || "$NEEDS_EVIDENCE" -gt 0 ]]; then
        echo "pending=${REAL_PENDING} inprogress=${INPROGRESS} needs_evidence=${NEEDS_EVIDENCE} blocked=${BLOCKED}" > "$TRIGGER"
        aau_log "$MEMBER: trigger created (pending=$REAL_PENDING, inprogress=$INPROGRESS, needs_evidence=$NEEDS_EVIDENCE, blocked=$BLOCKED)"
        aau_jlog "info" "trigger_created" "\"member\":\"$MEMBER\",\"pending\":$REAL_PENDING,\"inprogress\":$INPROGRESS,\"needs_evidence\":$NEEDS_EVIDENCE,\"blocked\":$BLOCKED"
    else
        # Clear stale trigger if no actionable tasks
        if [[ -f "$TRIGGER" ]]; then
            rm -f "$TRIGGER"
            aau_log "$MEMBER: trigger cleared (no actionable tasks)"
            aau_jlog "info" "trigger_cleared" "\"member\":\"$MEMBER\""
        fi
    fi
done

aau_log "=== done ==="
aau_jlog "info" "done"
