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

# ─── Schedule check ──────────────────────────────────────────────────────
if ! aau_is_active "agents"; then
    aau_log "outside active hours ($(aau_schedule_status agents)), skip"
    aau_jlog "info" "schedule_skip"
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

# ─── Actionable task gate (zero-token) ────────────────────────────────
# Verify tasks.md has work to do: PENDING, IN_PROGRESS, or NEEDS_EVIDENCE.
# Skip only when there are truly no actionable tasks.
TASKS_FILE="$AAU_PROJECT_ROOT/team/${MEMBER}/tasks.md"
if [[ -f "$TASKS_FILE" ]]; then
    _REAL_PENDING=$(grep -E '^### TASK-.*\[PENDING\]' "$TASKS_FILE" 2>/dev/null | grep -v "自主学習" | wc -l | tr -d ' ')
    _NEEDS_EV=$(grep -cE '^### TASK-.*\[NEEDS_EVIDENCE\]' "$TASKS_FILE" 2>/dev/null || true)
    _IN_PROG=$(grep -cE '^### TASK-.*\[IN_PROGRESS\]' "$TASKS_FILE" 2>/dev/null || true)
    if [[ "${_REAL_PENDING:-0}" -eq 0 && "${_NEEDS_EV:-0}" -eq 0 && "${_IN_PROG:-0}" -eq 0 ]]; then
        aau_log "no actionable tasks (pending=${_REAL_PENDING}, in_progress=${_IN_PROG}, needs_evidence=${_NEEDS_EV}), zero-token exit"
        aau_jlog "info" "no_actionable_tasks" "\"pending\":${_REAL_PENDING},\"in_progress\":${_IN_PROG},\"needs_evidence\":${_NEEDS_EV}"
        exit 0
    fi
fi

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
RUNTIME=$(aau_member_attr "$MEMBER" "runtime")
RUNTIME="${RUNTIME:-claude}"  # "claude" (default) or "aider"
TIMEOUT=$(aau_member_attr "$MEMBER" "timeout")
TIMEOUT="${TIMEOUT:-600}"
MAX_TURNS=$(aau_member_attr "$MEMBER" "max_turns")
MAX_TURNS="${MAX_TURNS:-30}"
TOOLS=$(aau_member_attr "$MEMBER" "tools")
TOOLS="${TOOLS:-Read,Write,Edit,Bash}"

# Continuation boost: increase max_turns for continuation sessions
# so the agent has enough budget to finish instead of looping
MT_FILE="${AAU_TMP}/${AAU_PREFIX}_max_turns_${MEMBER}"
_PREV_MT_COUNT=0
[[ -f "$MT_FILE" ]] && _PREV_MT_COUNT=$(cat "$MT_FILE" 2>/dev/null || echo 0)
if [[ "$_PREV_MT_COUNT" -gt 0 ]]; then
    BOOST_FACTOR="${AAU_AGENT_CONTINUATION_BOOST:-15}"
    MAX_TURNS=$(( MAX_TURNS + BOOST_FACTOR ))
    TIMEOUT=$(( TIMEOUT + 300 ))
    aau_log "continuation boost: max_turns=$MAX_TURNS, timeout=${TIMEOUT}s (prev failures: $_PREV_MT_COUNT)"
fi

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

# Check for continuation (previous session hit max turns or timed out)
CONTINUATION_HINT=""
MT_FILE="${AAU_TMP}/${AAU_PREFIX}_max_turns_${MEMBER}"
MT_COUNT=0
[[ -f "$MT_FILE" ]] && MT_COUNT=$(cat "$MT_FILE" 2>/dev/null || echo 0)
if [[ "$MT_COUNT" -gt 0 ]]; then
    # Extract current IN_PROGRESS task info and recent progress
    _IP_TASK=$(grep -E '^### TASK-.*\[IN_PROGRESS\]' "$TASKS_FILE" 2>/dev/null | head -1)
    _RECENT_PROGRESS=""
    PROGRESS_FILE="$AAU_PROJECT_ROOT/team/${MEMBER}/progress.md"
    if [[ -f "$PROGRESS_FILE" ]]; then
        _RECENT_PROGRESS=$(tail -20 "$PROGRESS_FILE" 2>/dev/null)
    fi
    CONTINUATION_HINT="

## 継続セッション（重要）
前回のセッションがmax turnsで中断しました（${MT_COUNT}回連続）。
IN_PROGRESSタスク: ${_IP_TASK}

前回の途中経過（progress.md末尾）:
${_RECENT_PROGRESS}

**指示**:
- progress.md の途中経過を必ず確認し、**既に完了した作業を繰り返さないこと**
- 残作業のみに集中する
- ターン数を節約し、完了できなければ途中経過をprogress.mdに記録して正常終了する
- ${MT_COUNT}回連続中断 — あと$((MT_THRESHOLD - MT_COUNT))回でタスクが自動BLOCKEDになる"
    aau_log "continuation session: $MT_COUNT consecutive max turns"
fi

# Render prompt (use aider-specific template if runtime=aider)
if [[ "$RUNTIME" == "aider" ]]; then
    PROMPT=$(aau_render_prompt "agent_poll_tasks_aider.txt" "member=$MEMBER")
else
    PROMPT=$(aau_render_prompt "agent_poll_tasks.txt" "member=$MEMBER")
fi
if [[ -z "$PROMPT" ]]; then
    PROMPT="team/${MEMBER}/tasks.md を読み、PENDINGタスクを処理せよ。完了したらステータスをDONEに更新し、progress.mdに結果を記録せよ。"
fi
PROMPT="${PROMPT}${DRAFT_HINT}${BLOCKED_HINT}${CONTINUATION_HINT}"

OUTFILE="${AAU_TMP}/${AAU_PREFIX}_agent_${MEMBER}_$$.out"
cd "$AAU_PROJECT_ROOT"

if [[ "$RUNTIME" == "aider" ]]; then
    # ── aider + Ollama execution path ─────────────────────────────────
    AIDER_MODEL=$(aau_member_attr "$MEMBER" "aider_model")
    AIDER_MODEL="${AIDER_MODEL:-ollama_chat/qwen2.5-coder:32b}"
    AIDER_FILES=$(aau_member_attr "$MEMBER" "aider_files")
    AIDER_MAX_ROUNDS="${MAX_TURNS}"  # max_turns = max aider rounds for this runtime

    aau_log "launching aider (model=$AIDER_MODEL, timeout=${TIMEOUT}s, max_rounds=$AIDER_MAX_ROUNDS)"
    aau_jlog "info" "aider_launch" "\"member\":\"$MEMBER\",\"model\":\"$AIDER_MODEL\",\"timeout\":$TIMEOUT,\"max_rounds\":$AIDER_MAX_ROUNDS"

    source "$SCRIPT_DIR/aider_runner.sh"
    aau_run_aider "$MEMBER" "$PROMPT" "$TIMEOUT" "$AIDER_MAX_ROUNDS" \
        "$AIDER_MODEL" "$AIDER_FILES" "$OUTFILE"
else
    # ── Claude CLI execution path (default) ───────────────────────────
    aau_log "launching Claude (timeout=${TIMEOUT}s, max_turns=$MAX_TURNS)"
    aau_jlog "info" "claude_launch" "\"member\":\"$MEMBER\",\"timeout\":$TIMEOUT,\"max_turns\":$MAX_TURNS"

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
fi

EXIT_CODE=$?
cat "$OUTFILE" >> "$_AAU_LOG_FILE" 2>/dev/null
rm -f "$OUTFILE"

# ── Consecutive max-turns / timeout → auto-BLOCKED ─────────────────
_MAX_TURNS_HIT=false
if [[ "$EXIT_CODE" -eq 124 ]]; then
    _MAX_TURNS_HIT=true
elif [[ -f "$_AAU_LOG_FILE" ]] && tail -50 "$_AAU_LOG_FILE" 2>/dev/null | grep -qE "Reached max turns|max turns exceeded"; then
    _MAX_TURNS_HIT=true
fi

# Check if a task actually completed during this session (DONE transition)
# If so, max turns was productive — don't penalize
_TASK_COMPLETED=false
if [[ "$_MAX_TURNS_HIT" == "true" && -f "$TASKS_FILE" ]]; then
    # Check if there are NO active tasks left (all completed)
    _ACTIVE=$(grep -cE '^### TASK-.*\[(IN_PROGRESS|PENDING|NEEDS_EVIDENCE)\]' "$TASKS_FILE" 2>/dev/null || true)
    if [[ "${_ACTIVE:-0}" -eq 0 ]]; then
        _TASK_COMPLETED=true
        aau_log "max turns hit but task completed — not penalizing"
    fi
fi

if [[ "$_MAX_TURNS_HIT" == "true" && "$_TASK_COMPLETED" != "true" ]]; then
    MT_FILE="${AAU_TMP}/${AAU_PREFIX}_max_turns_${MEMBER}"
    MT_COUNT=0
    [[ -f "$MT_FILE" ]] && MT_COUNT=$(cat "$MT_FILE" 2>/dev/null || echo 0)
    MT_COUNT=$(( MT_COUNT + 1 ))
    echo "$MT_COUNT" > "$MT_FILE"

    MT_THRESHOLD="${AAU_AGENT_MAX_TURNS_BLOCK_THRESHOLD:-3}"
    if [[ "$MT_COUNT" -ge "$MT_THRESHOLD" ]]; then
        # Auto-BLOCKED: mark first active task as BLOCKED
        python3 - "$TASKS_FILE" << 'PYEOF'
import sys, re
tasks_file = sys.argv[1]
with open(tasks_file) as f:
    content = f.read()
# Find first IN_PROGRESS or PENDING task
for status in ["IN_PROGRESS", "PENDING"]:
    pattern = rf'(^### TASK-\S+.*?)\[{status}\]'
    m = re.search(pattern, content, re.MULTILINE)
    if m:
        old = m.group(0)
        new = old.replace(f"[{status}]", "[BLOCKED — auto: max turns exceeded]")
        content = content.replace(old, new, 1)
        with open(tasks_file, "w") as f:
            f.write(content)
        print(f"BLOCKED: {old.strip()}")
        break
PYEOF
        aau_log "AUTO-BLOCKED: $MEMBER — ${MT_COUNT} consecutive max turns"
        aau_jlog "warn" "auto_blocked" "\"member\":\"$MEMBER\",\"consecutive\":$MT_COUNT"
        aau_notify "[Auto-BLOCKED] ${MEMBER}: ${MT_COUNT}回連続max turns到達。タスクをBLOCKEDに変更しました。"
        echo 0 > "$MT_FILE"
    fi
elif [[ "$_TASK_COMPLETED" == "true" ]]; then
    # Task completed — reset counter
    MT_FILE="${AAU_TMP}/${AAU_PREFIX}_max_turns_${MEMBER}"
    echo 0 > "$MT_FILE" 2>/dev/null
fi

if [[ "$EXIT_CODE" -eq 124 ]]; then
    aau_log "session timed out after ${TIMEOUT}s"
    aau_jlog "error" "session_timeout" "\"member\":\"$MEMBER\""
elif [[ "$EXIT_CODE" -ne 0 ]]; then
    aau_log "session failed (exit=$EXIT_CODE)"
    aau_jlog "warn" "session_failed" "\"member\":\"$MEMBER\",\"exit\":$EXIT_CODE"

    # ── Consecutive failure tracking & escalation ─────────────────
    FAIL_FILE="${AAU_TMP}/${AAU_PREFIX}_fail_count_${MEMBER}"
    FAIL_COUNT=0
    [[ -f "$FAIL_FILE" ]] && FAIL_COUNT=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    echo "$FAIL_COUNT" > "$FAIL_FILE"

    FAIL_NOTIFY_THRESHOLD="${AAU_AGENT_FAIL_NOTIFY_THRESHOLD:-3}"
    FAIL_BACKOFF_THRESHOLD="${AAU_AGENT_FAIL_BACKOFF_THRESHOLD:-5}"

    # Extract error hint from output
    _FAIL_HINT=""
    if [[ -f "$_AAU_LOG_FILE" ]]; then
        _FAIL_HINT=$(tail -10 "$_AAU_LOG_FILE" 2>/dev/null | grep -iE 'timed out|error|refused|rate limit|overloaded|503|529' | tail -1)
    fi

    # Exponential backoff: 1→60s, 2→120s, 3→300s+notify, 4→600s, 5+→1800s+notify
    if [[ "$FAIL_COUNT" -ge "$FAIL_BACKOFF_THRESHOLD" ]]; then
        FAIL_COOLDOWN="${AAU_AGENT_FAIL_COOLDOWN:-1800}"
        echo $(( $(date +%s) + FAIL_COOLDOWN )) > "$COOLDOWN_FILE"
        aau_log "fail backoff: $FAIL_COUNT consecutive failures, entering ${FAIL_COOLDOWN}s cooldown"
        aau_jlog "warn" "fail_backoff" "\"member\":\"$MEMBER\",\"failures\":$FAIL_COUNT,\"cooldown\":$FAIL_COOLDOWN"
        aau_notify "[Fail-Backoff] ${MEMBER}: ${FAIL_COUNT}回連続失敗。${FAIL_COOLDOWN}秒クールダウンに入ります。${_FAIL_HINT:+原因: ${_FAIL_HINT}}"
    elif [[ "$FAIL_COUNT" -eq "$FAIL_NOTIFY_THRESHOLD" ]]; then
        # First notification + moderate cooldown
        local _MODERATE_COOLDOWN=$(( 60 * FAIL_COUNT ))  # 3→180s, 4→240s
        echo $(( $(date +%s) + _MODERATE_COOLDOWN )) > "$COOLDOWN_FILE"
        aau_log "fail escalation: $FAIL_COUNT failures, cooldown ${_MODERATE_COOLDOWN}s"
        aau_notify "[Warning] ${MEMBER}: ${FAIL_COUNT}回連続セッション失敗中。${_MODERATE_COOLDOWN}秒後にリトライ。${_FAIL_HINT:+原因: ${_FAIL_HINT}}"
    elif [[ "$FAIL_COUNT" -ge 2 ]]; then
        # Progressive cooldown: 2→120s, 3→180s, 4→240s (before threshold)
        local _PROG_COOLDOWN=$(( 60 * FAIL_COUNT ))
        echo $(( $(date +%s) + _PROG_COOLDOWN )) > "$COOLDOWN_FILE"
        aau_log "progressive backoff: $FAIL_COUNT failures, cooldown ${_PROG_COOLDOWN}s"
    fi
else
    aau_log "session succeeded"
    aau_jlog "info" "session_succeeded" "\"member\":\"$MEMBER\""

    # Reset max-turns counter ONLY if max turns was NOT hit
    # (Claude CLI exits 0 even on max turns, so check _MAX_TURNS_HIT)
    if [[ "$_MAX_TURNS_HIT" != "true" ]]; then
        MT_FILE="${AAU_TMP}/${AAU_PREFIX}_max_turns_${MEMBER}"
        echo 0 > "$MT_FILE" 2>/dev/null
    fi

    # Reset rapid launch counter on success (not a loop)
    if [[ "$_MAX_TURNS_HIT" != "true" ]]; then
        > "$COOLDOWN_LAUNCHES" 2>/dev/null
    fi

    # Reset consecutive failure counter on success
    FAIL_FILE="${AAU_TMP}/${AAU_PREFIX}_fail_count_${MEMBER}"
    if [[ -f "$FAIL_FILE" ]]; then
        _PREV_FAILS=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
        if [[ "${_PREV_FAILS:-0}" -gt 0 ]]; then
            aau_log "session recovered after $_PREV_FAILS consecutive failures"
        fi
        echo 0 > "$FAIL_FILE"
    fi

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
