#!/bin/bash
# task_monitor.sh — Scan team task files and create trigger files
# Zero-token operation: pure bash, no LLM calls.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
aau_init_logging "task_monitor"

aau_log "=== task_monitor start ==="
aau_jlog "info" "start"

TEAM_DIR="$AAU_PROJECT_ROOT/team"

# ── Approval gate: if status.md has "承認待ち", block ALL triggers ──
STATUS_FILE="$TEAM_DIR/director/status.md"
if [[ -f "$STATUS_FILE" ]] && grep -qiE '承認待ち|approval pending' "$STATUS_FILE" 2>/dev/null; then
    aau_log "APPROVAL GATE: status.md has approval pending — blocking all triggers"
    aau_jlog "info" "approval_gate_block"
    # Clear all existing triggers
    for _m in $(aau_team_members); do
        rm -f "${AAU_TMP}/${AAU_PREFIX}_trigger_${_m}"
    done
    aau_log "=== done (approval gate) ==="
    aau_jlog "info" "done" "\"reason\":\"approval_gate\""
    exit 0
fi

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

for MEMBER in $(aau_team_members); do
    TASKS_FILE="$TEAM_DIR/$MEMBER/tasks.md"
    TRIGGER="${AAU_TMP}/${AAU_PREFIX}_trigger_${MEMBER}"

    if [[ ! -f "$TASKS_FILE" ]]; then
        continue
    fi

    # Support both [STATUS] and **Status**: STATUS formats
    PENDING=$(grep -cE '\[PENDING\]|\*\*Status\*\*:\s*PENDING' "$TASKS_FILE" 2>/dev/null || true)
    INPROGRESS=$(grep -cE '\[IN_PROGRESS\]|\*\*Status\*\*:\s*IN_PROGRESS' "$TASKS_FILE" 2>/dev/null || true)
    NEEDS_EVIDENCE=$(grep -c '\[NEEDS_EVIDENCE\]' "$TASKS_FILE" 2>/dev/null || true)
    BLOCKED=$(grep -cE '\[BLOCKED\]|\*\*Status\*\*:\s*BLOCKED' "$TASKS_FILE" 2>/dev/null || true)

    # Exclude self-study/learning tasks from pending count (prevent unnecessary agent launch)
    REAL_PENDING=$(grep -E '\[PENDING\]|\*\*Status\*\*:\s*PENDING' "$TASKS_FILE" 2>/dev/null | grep -v "自主学習" | wc -l | tr -d ' ')

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
