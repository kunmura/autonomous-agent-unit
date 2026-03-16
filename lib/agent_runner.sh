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

# No trigger → zero-token exit
if [[ ! -f "$TRIGGER" ]]; then
    aau_log "no trigger, exit"
    aau_jlog "info" "no_trigger_exit"
    exit 0
fi

TRIGGER_CONTENT=$(cat "$TRIGGER")
rm -f "$TRIGGER"
aau_log "trigger: $TRIGGER_CONTENT"

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

# Render prompt
PROMPT=$(aau_render_prompt "agent_poll_tasks.txt" "member=$MEMBER")
if [[ -z "$PROMPT" ]]; then
    # Fallback prompt if template not found
    PROMPT="team/${MEMBER}/tasks.md を読み、PENDINGタスクを処理せよ。完了したらステータスをDONEに更新し、progress.mdに結果を記録せよ。"
fi

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
    aau_run_with_timeout "$TIMEOUT" "$OUTFILE" "$AAU_CLAUDE" \
        $AGENT_FLAG \
        --model "$AAU_MODEL" \
        --print \
        --permission-mode "$AAU_PERM" \
        --max-turns "$MAX_TURNS" \
        $TOOL_FLAGS \
        "$PROMPT"
else
    aau_run_with_timeout "$TIMEOUT" "$OUTFILE" "$AAU_CLAUDE" \
        --model "$AAU_MODEL" \
        --print \
        --permission-mode "$AAU_PERM" \
        --max-turns "$MAX_TURNS" \
        $TOOL_FLAGS \
        "$PROMPT"
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
fi

aau_log "=== done (exit=$EXIT_CODE) ==="
aau_jlog "info" "done" "\"exit\":$EXIT_CODE"
