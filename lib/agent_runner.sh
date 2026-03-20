#!/bin/bash
# agent_runner.sh — Run a team member agent when triggered
# Usage: agent_runner.sh <member_name>
# Zero-token when no trigger file exists.

MEMBER="${1:?Usage: agent_runner.sh <member_name>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
aau_init_logging "agent_${MEMBER}"

TRIGGER="${AAU_TMP}/${AAU_PREFIX}_trigger_${MEMBER}"
LOCK_NAME="agent_${MEMBER}"

aau_log "=== agent_runner start (${MEMBER}) ==="
aau_jlog "info" "start"

# ─── Quiet hours check ──────────────────────────────────────────────────
HOUR=$(date +%H)
QUIET_START="${AAU_DIRECTOR_QUIET_HOURS_START:-0}"
QUIET_END="${AAU_DIRECTOR_QUIET_HOURS_END:-8}"
if [[ "$HOUR" -ge "$QUIET_START" && "$HOUR" -lt "$QUIET_END" ]]; then
    aau_log "quiet hours (hour=$HOUR), skip"
    aau_jlog "info" "quiet_skip" "\"hour\":$HOUR"
    exit 0
fi

# ─── Daily invocation limit (shared with director) ──────────────────
TODAY=$(date +%Y-%m-%d)
DAILY_FILE="${AAU_TMP}/${AAU_PREFIX}_agent_daily_${MEMBER}_${TODAY}"
DAILY_MAX="${AAU_AGENT_DAILY_MAX:-50}"
DAILY_COUNT=0
if [[ -f "$DAILY_FILE" ]]; then
    DAILY_COUNT=$(cat "$DAILY_FILE" 2>/dev/null || echo 0)
fi
if [[ "$DAILY_COUNT" -ge "$DAILY_MAX" ]]; then
    aau_log "daily limit reached ($DAILY_COUNT/$DAILY_MAX), skip"
    aau_jlog "warn" "daily_limit" "\"count\":$DAILY_COUNT"
    exit 0
fi

# ─── Rapid relaunch cooldown ─────────────────────────────────────────
# If this agent launched N+ times in the last 30min with no task completion, cooldown
COOLDOWN_FILE="${AAU_TMP}/${AAU_PREFIX}_agent_${MEMBER}_cooldown"
COOLDOWN_LAUNCHES="${AAU_TMP}/${AAU_PREFIX}_agent_${MEMBER}_launches"
MAX_RAPID_LAUNCHES="${AAU_AGENT_MAX_RAPID_LAUNCHES:-4}"
NOW=$(date +%s)

if [[ -f "$COOLDOWN_FILE" ]]; then
    COOLDOWN_UNTIL=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
    if [[ "$NOW" -lt "$COOLDOWN_UNTIL" ]]; then
        REMAINING=$(( COOLDOWN_UNTIL - NOW ))
        aau_log "cooldown active (${REMAINING}s remaining), skip"
        aau_jlog "info" "cooldown_skip" "\"remaining\":$REMAINING"
        exit 0
    else
        rm -f "$COOLDOWN_FILE"
    fi
fi

# No trigger → zero-token exit
if [[ ! -f "$TRIGGER" ]]; then
    aau_log "no trigger, exit"
    aau_jlog "info" "no_trigger_exit"
    exit 0
fi

TRIGGER_CONTENT=$(cat "$TRIGGER")
rm -f "$TRIGGER"
aau_log "trigger: $TRIGGER_CONTENT"

# Track launch count for cooldown detection
echo "$NOW" >> "$COOLDOWN_LAUNCHES"
# Keep only entries from last 30 minutes
if [[ -f "$COOLDOWN_LAUNCHES" ]]; then
    CUTOFF=$(( NOW - 1800 ))
    RECENT_LAUNCHES=0
    while IFS= read -r ts; do
        if [[ "$ts" -ge "$CUTOFF" ]]; then
            RECENT_LAUNCHES=$(( RECENT_LAUNCHES + 1 ))
        fi
    done < "$COOLDOWN_LAUNCHES"
    if [[ "$RECENT_LAUNCHES" -ge "$MAX_RAPID_LAUNCHES" ]]; then
        aau_log "rapid relaunch detected ($RECENT_LAUNCHES in 30min), entering 30min cooldown"
        aau_jlog "warn" "cooldown_activated" "\"launches\":$RECENT_LAUNCHES"
        echo $(( NOW + 1800 )) > "$COOLDOWN_FILE"
        > "$COOLDOWN_LAUNCHES"
        exit 0
    fi
fi

# Acquire lock
if ! aau_acquire_lock "$LOCK_NAME"; then
    exit 0
fi

# Get member-specific config
TIMEOUT=$(aau_member_attr "$MEMBER" "timeout")
TIMEOUT="${TIMEOUT:-600}"
MAX_TURNS=$(aau_member_attr "$MEMBER" "max_turns")
MAX_TURNS="${MAX_TURNS:-30}"
TOOLS=$(aau_member_attr "$MEMBER" "tools")
TOOLS="${TOOLS:-Read,Write,Edit,Bash}"

# Check for draft.md (local LLM pre-draft)
DRAFT_FILE="$AAU_PROJECT_ROOT/team/${MEMBER}/draft.md"
DRAFT_HINT=""
if [[ -f "$DRAFT_FILE" ]]; then
    DRAFT_SIZE=$(wc -c < "$DRAFT_FILE" 2>/dev/null || echo 0)
    if [[ "$DRAFT_SIZE" -gt 10 ]]; then
        DRAFT_HINT="

IMPORTANT: team/${MEMBER}/draft.md にローカルLLMの下書きがあります。まずこれを確認し、品質が十分ならそのまま使用してください。使用・不使用に関わらず、処理後に draft.md を削除してください。"
        aau_log "draft.md found (${DRAFT_SIZE} bytes)"
        aau_jlog "info" "draft_found" "\"member\":\"$MEMBER\",\"size\":$DRAFT_SIZE"
    fi
fi

# Check for blocked tasks in trigger content
BLOCKED_HINT=""
if echo "$TRIGGER_CONTENT" | grep -q "blocked="; then
    BLOCKED_COUNT=$(echo "$TRIGGER_CONTENT" | grep -oE 'blocked=[0-9]+' | cut -d= -f2)
    if [[ "$BLOCKED_COUNT" -gt 0 ]]; then
        BLOCKED_HINT="

NOTE: ${BLOCKED_COUNT} task(s) are [BLOCKED]. Check prerequisites before working on them. If the blocking task is not yet [DONE], skip the blocked task."
    fi
fi

# Render prompt
PROMPT=$(aau_render_prompt "agent_poll_tasks.txt" "member=$MEMBER")
if [[ -z "$PROMPT" ]]; then
    # Fallback prompt if template not found
    PROMPT="team/${MEMBER}/tasks.md を読み、PENDINGタスクを処理せよ。完了したらステータスをDONEに更新し、progress.mdに結果を記録せよ。"
fi
PROMPT="${PROMPT}${DRAFT_HINT}${BLOCKED_HINT}"

aau_log "launching Claude (timeout=${TIMEOUT}s, max_turns=$MAX_TURNS)"
aau_jlog "info" "claude_launch" "\"member\":\"$MEMBER\",\"timeout\":$TIMEOUT,\"max_turns\":$MAX_TURNS"

OUTFILE="${AAU_TMP}/${AAU_PREFIX}_agent_${MEMBER}_$$.out"

cd "$AAU_PROJECT_ROOT"

# Check for agent definition file
AGENT_FLAG=""
AGENT_FILE="$AAU_PROJECT_ROOT/.claude/agents/${MEMBER}.md"
if [[ -f "$AGENT_FILE" ]]; then
    AGENT_FLAG="--agent $MEMBER"
fi

# Build tool flags
TOOL_FLAGS=""
if [[ -n "$TOOLS" ]]; then
    TOOL_FLAGS="--tools $TOOLS --allowedTools $TOOLS"
fi

aau_log "tools: $TOOLS"

if [[ -n "$AGENT_FLAG" ]]; then
    aau_run_with_timeout "$TIMEOUT" "$OUTFILE" "$PROMPT" "$AAU_CLAUDE" \
        $AGENT_FLAG \
        --model "$AAU_MODEL" \
        --print \
        --permission-mode "$AAU_PERM" \
        --max-turns "$MAX_TURNS" \
        $TOOL_FLAGS
else
    aau_run_with_timeout "$TIMEOUT" "$OUTFILE" "$PROMPT" "$AAU_CLAUDE" \
        --model "$AAU_MODEL" \
        --print \
        --permission-mode "$AAU_PERM" \
        --max-turns "$MAX_TURNS" \
        $TOOL_FLAGS
fi

EXIT_CODE=$?
cat "$OUTFILE" >> "$_AAU_LOG_FILE" 2>/dev/null
rm -f "$OUTFILE"

if [[ "$EXIT_CODE" -eq 124 ]]; then
    aau_log "session timed out after ${TIMEOUT}s"
    aau_jlog "error" "session_timeout" "\"member\":\"$MEMBER\""
elif [[ "$EXIT_CODE" -ne 0 ]]; then
    aau_log "session failed (exit=$EXIT_CODE)"
    aau_jlog "warn" "session_failed" "\"member\":\"$MEMBER\",\"exit\":$EXIT_CODE"
else
    aau_log "session succeeded"
    aau_jlog "info" "session_succeeded" "\"member\":\"$MEMBER\""

    # Reset rapid launch counter on success (not a loop)
    > "$COOLDOWN_LAUNCHES" 2>/dev/null

    # Increment daily counter
    echo $(( DAILY_COUNT + 1 )) > "$DAILY_FILE"

    # Clean old daily counters
    find "${AAU_TMP}" -name "${AAU_PREFIX}_agent_daily_${MEMBER}_*" -not -name "*${TODAY}" -delete 2>/dev/null

    # ─── Clean up draft.md if it was used ──────────────────────
    if [[ -f "$DRAFT_FILE" ]]; then
        rm -f "$DRAFT_FILE"
        aau_log "draft.md cleaned up after session"
    fi

    # ─── Evidence Validation Gate ──────────────────────────────
    # After successful session, validate that DONE tasks have proper evidence.
    # Tasks failing validation are reverted to [NEEDS_EVIDENCE].
    VALIDATOR="$SCRIPT_DIR/output_validator.sh"
    if [[ -f "$VALIDATOR" ]]; then
        bash "$VALIDATOR" "$MEMBER"
        VALID_EXIT=$?
        if [[ "$VALID_EXIT" -ne 0 ]]; then
            aau_log "evidence validation failed — tasks reverted to NEEDS_EVIDENCE"
            aau_jlog "warn" "evidence_gate_failed" "\"member\":\"$MEMBER\""
        fi
    fi

    # ─── Build Verification Gate ───────────────────────────────
    # Verify the project still builds after code changes.
    BUILD_CHECK="$SCRIPT_DIR/build_check.sh"
    if [[ -f "$BUILD_CHECK" ]]; then
        bash "$BUILD_CHECK" "$MEMBER"
    fi
fi

aau_log "=== done (exit=$EXIT_CODE) ==="
aau_jlog "info" "done" "\"exit\":$EXIT_CODE"
