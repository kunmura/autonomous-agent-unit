#!/bin/bash
# task_monitor.sh — Scan team task files and create trigger files
# Zero-token operation: pure bash, no LLM calls.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
aau_init_logging "task_monitor"

aau_log "=== task_monitor start ==="
aau_jlog "info" "start"

TEAM_DIR="$AAU_PROJECT_ROOT/team"

for MEMBER in $(aau_team_members); do
    TASKS_FILE="$TEAM_DIR/$MEMBER/tasks.md"
    TRIGGER="${AAU_TMP}/${AAU_PREFIX}_trigger_${MEMBER}"

    if [[ ! -f "$TASKS_FILE" ]]; then
        continue
    fi

    PENDING=$(grep -c '\[PENDING\]' "$TASKS_FILE" 2>/dev/null || true)
    INPROGRESS=$(grep -c '\[IN_PROGRESS\]' "$TASKS_FILE" 2>/dev/null || true)
    NEEDS_EVIDENCE=$(grep -c '\[NEEDS_EVIDENCE\]' "$TASKS_FILE" 2>/dev/null || true)

    if [[ "$PENDING" -gt 0 || "$INPROGRESS" -gt 0 || "$NEEDS_EVIDENCE" -gt 0 ]]; then
        if [[ ! -f "$TRIGGER" ]]; then
            echo "pending=${PENDING} inprogress=${INPROGRESS} needs_evidence=${NEEDS_EVIDENCE}" > "$TRIGGER"
            aau_log "$MEMBER: trigger created (pending=$PENDING, inprogress=$INPROGRESS, needs_evidence=$NEEDS_EVIDENCE)"
            aau_jlog "info" "trigger_created" "\"member\":\"$MEMBER\",\"pending\":$PENDING,\"inprogress\":$INPROGRESS,\"needs_evidence\":$NEEDS_EVIDENCE"
        fi
    fi
done

aau_log "=== done ==="
aau_jlog "info" "done"
