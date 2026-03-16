#!/bin/bash
# director_autonomous.sh — Director autonomous loop
# Runs periodically (default 30min). Detects project state and takes action.
# Zero-token when NO_ACTION (normal operation).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
aau_init_logging "director_autonomous"
aau_rotate_logs

aau_log "=== director_autonomous start ==="
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

# ─── Daily invocation limit ─────────────────────────────────────────────
TODAY=$(date +%Y-%m-%d)
DAILY_FILE="${AAU_TMP}/${AAU_PREFIX}_autonomous_daily_${TODAY}"
DAILY_MAX="${AAU_DIRECTOR_DAILY_MAX_INVOCATIONS:-20}"
DAILY_COUNT=0
if [[ -f "$DAILY_FILE" ]]; then
    DAILY_COUNT=$(cat "$DAILY_FILE" 2>/dev/null || echo 0)
fi
if [[ "$DAILY_COUNT" -ge "$DAILY_MAX" ]]; then
    aau_log "daily limit reached ($DAILY_COUNT/$DAILY_MAX), skip"
    aau_jlog "warn" "daily_limit" "\"count\":$DAILY_COUNT"
    exit 0
fi

# ─── Lock ────────────────────────────────────────────────────────────────
if ! aau_acquire_lock "director_autonomous"; then
    exit 0
fi

# ─── Yield to responder ─────────────────────────────────────────────────
RESPONDER_LOCK="${AAU_TMP}/${AAU_PREFIX}_director_responder.lock"
if [[ -f "$RESPONDER_LOCK" ]]; then
    RESP_PID=$(cat "$RESPONDER_LOCK" 2>/dev/null)
    if kill -0 "$RESP_PID" 2>/dev/null; then
        aau_log "responder active (PID=$RESP_PID), yielding"
        aau_jlog "info" "yield_to_responder"
        exit 0
    fi
fi

# ─── State detection ────────────────────────────────────────────────────
ACTION="NO_ACTION"
ACTION_DETAIL=""
NOW=$(date +%s)
TEAM_DIR="$AAU_PROJECT_ROOT/team"
REPORT_MARKER="${AAU_TMP}/${AAU_PREFIX}_last_report"
DONE_SEED="${AAU_TMP}/${AAU_PREFIX}_autonomous_done_seed"
REPORT_INTERVAL="${AAU_DIRECTOR_REPORT_INTERVAL:-7200}"
STALE_THRESHOLD="${AAU_DIRECTOR_STALE_THRESHOLD:-1800}"

# --- 1. REPORT_DUE ---
if [[ -f "$REPORT_MARKER" ]]; then
    LAST_REPORT=$(aau_file_mtime "$REPORT_MARKER")
    REPORT_AGE=$(( NOW - LAST_REPORT ))
else
    REPORT_AGE=$((REPORT_INTERVAL + 1))
fi
if [[ "$REPORT_AGE" -gt "$REPORT_INTERVAL" ]]; then
    ACTION="REPORT_DUE"
    ACTION_DETAIL="last_report_age=${REPORT_AGE}s"
fi

# --- 2. DONE_FOLLOWUP ---
if [[ "$ACTION" == "NO_ACTION" || "$ACTION" == "REPORT_DUE" ]]; then
    DONE_TASKS=""
    for MEMBER in $(aau_team_members); do
        TASKS_FILE="$TEAM_DIR/$MEMBER/tasks.md"
        if [[ -f "$TASKS_FILE" ]]; then
            M_DONE=$(grep -c '\[DONE\]' "$TASKS_FILE" 2>/dev/null || true)
            if [[ "$M_DONE" -gt 0 ]]; then
                DONE_TASKS="${DONE_TASKS}${MEMBER}:${M_DONE} "
            fi
        fi
    done
    if [[ -n "$DONE_TASKS" ]]; then
        CURRENT_HASH=$(echo "$DONE_TASKS" | aau_md5)
        SEEDED_HASH=""
        [[ -f "$DONE_SEED" ]] && SEEDED_HASH=$(cat "$DONE_SEED" 2>/dev/null)
        if [[ "$CURRENT_HASH" != "$SEEDED_HASH" ]]; then
            ACTION="DONE_FOLLOWUP"
            ACTION_DETAIL="done_tasks=$DONE_TASKS"
        fi
    fi
fi

# --- 3. STALE_PROGRESS ---
if [[ "$ACTION" == "NO_ACTION" ]]; then
    for MEMBER in $(aau_team_members); do
        TASKS_FILE="$TEAM_DIR/$MEMBER/tasks.md"
        PROGRESS_FILE="$TEAM_DIR/$MEMBER/progress.md"
        if [[ -f "$TASKS_FILE" ]] && grep -q '\[IN_PROGRESS\]' "$TASKS_FILE" 2>/dev/null; then
            if [[ -f "$PROGRESS_FILE" ]]; then
                PROG_AGE=$(( NOW - $(aau_file_mtime "$PROGRESS_FILE") ))
                if [[ "$PROG_AGE" -gt "$STALE_THRESHOLD" ]]; then
                    ACTION="STALE_PROGRESS"
                    ACTION_DETAIL="member=${MEMBER},progress_age=${PROG_AGE}s"
                    break
                fi
            fi
        fi
    done
fi

# --- 4. IDLE_ALL ---
if [[ "$ACTION" == "NO_ACTION" ]]; then
    TOTAL_PENDING=0
    TOTAL_INPROG=0
    for MEMBER in $(aau_team_members); do
        TASKS_FILE="$TEAM_DIR/$MEMBER/tasks.md"
        if [[ -f "$TASKS_FILE" ]]; then
            P=$(grep -c '\[PENDING\]' "$TASKS_FILE" 2>/dev/null || true)
            I=$(grep -c '\[IN_PROGRESS\]' "$TASKS_FILE" 2>/dev/null || true)
            TOTAL_PENDING=$((TOTAL_PENDING + P))
            TOTAL_INPROG=$((TOTAL_INPROG + I))
        fi
    done
    if [[ "$TOTAL_PENDING" -eq 0 && "$TOTAL_INPROG" -eq 0 ]]; then
        ACTION="IDLE_ALL"
        ACTION_DETAIL="pending=0,inprogress=0"
    fi
fi

aau_log "action=$ACTION detail=$ACTION_DETAIL"
aau_jlog "info" "state_decided" "\"action\":\"$ACTION\",\"detail\":\"$ACTION_DETAIL\""

# ─── NO_ACTION → zero-token exit ────────────────────────────────────────
if [[ "$ACTION" == "NO_ACTION" ]]; then
    aau_log "=== no action needed, exit ==="
    aau_jlog "info" "no_action_exit"
    exit 0
fi

# ─── Render prompt from template ─────────────────────────────────────────
cd "$AAU_PROJECT_ROOT"
OUTFILE="${AAU_TMP}/${AAU_PREFIX}_director_autonomous_$$.out"

# Map action to template and max_turns
case "$ACTION" in
    REPORT_DUE)
        TEMPLATE="director_report.txt"
        MAX_TURNS="${AAU_DIRECTOR_MAX_TURNS_REPORT:-15}"
        ;;
    DONE_FOLLOWUP)
        TEMPLATE="director_done_followup.txt"
        MAX_TURNS="${AAU_DIRECTOR_MAX_TURNS_FOLLOWUP:-20}"
        ;;
    STALE_PROGRESS)
        TEMPLATE="director_stale_progress.txt"
        MAX_TURNS="${AAU_DIRECTOR_MAX_TURNS_STALE:-10}"
        ;;
    IDLE_ALL)
        TEMPLATE="director_idle_all.txt"
        MAX_TURNS="${AAU_DIRECTOR_MAX_TURNS_IDLE:-25}"
        ;;
esac

PROMPT=$(aau_render_prompt "$TEMPLATE" "action_detail=$ACTION_DETAIL")
if [[ -z "$PROMPT" ]]; then
    aau_log "ERROR: prompt template $TEMPLATE not found, abort"
    aau_jlog "error" "missing_template" "\"template\":\"$TEMPLATE\""
    exit 1
fi

# Inject notification instructions if plugin is configured
NOTIFY_PLUGIN="${AAU_NOTIFICATION_PLUGIN:-none}"
if [[ "$NOTIFY_PLUGIN" == "slack" && -n "$SLACK_TOKEN" && -n "$SLACK_CHANNEL" ]]; then
    PROMPT="$PROMPT

## Slack投稿（必須）
以下のcurlコマンドでSlackに報告を投稿せよ。投稿しなかった場合、Producerに状況が伝わらない。

投稿内容は以下の構成にすること:
- 1行目: フェーズ名と進捗率
- 2行目: 完了タスク数と主要成果物
- 3行目: 進行中タスクとメンバー
- 4行目: 次のアクション

SLACK_TOKEN=\"$SLACK_TOKEN\"
SLACK_CHANNEL=\"$SLACK_CHANNEL\"
curl -s -X POST 'https://slack.com/api/chat.postMessage' \\
  -H \"Authorization: Bearer \$SLACK_TOKEN\" \\
  -H 'Content-Type: application/json' \\
  -d '{\"channel\":\"\$SLACK_CHANNEL\",\"text\":\"報告内容\"}'"
fi

# ─── Launch Claude ───────────────────────────────────────────────────────
TIMEOUT="${AAU_DIRECTOR_TIMEOUT:-600}"
echo $(( DAILY_COUNT + 1 )) > "$DAILY_FILE"

aau_log "launching Claude (action=$ACTION, max_turns=$MAX_TURNS)"
aau_jlog "info" "claude_launch" "\"action\":\"$ACTION\",\"max_turns\":$MAX_TURNS"

DIRECTOR_TOOLS="Read,Write,Edit,Bash"
aau_run_with_timeout "$TIMEOUT" "$OUTFILE" "$AAU_CLAUDE" \
    --model "$AAU_MODEL" \
    --print \
    --permission-mode "$AAU_PERM" \
    --max-turns "$MAX_TURNS" \
    --tools "$DIRECTOR_TOOLS" \
    --allowedTools "$DIRECTOR_TOOLS" \
    "$PROMPT"

EXIT_CODE=$?
OUTPUT=$(cat "$OUTFILE" 2>/dev/null)
rm -f "$OUTFILE"
echo "$OUTPUT" >> "$_AAU_LOG_FILE"

# ─── Result handling ─────────────────────────────────────────────────────
if [[ "$EXIT_CODE" -eq 124 ]]; then
    aau_log "session timed out after ${TIMEOUT}s"
    aau_jlog "error" "session_timeout" "\"action\":\"$ACTION\""
elif echo "$OUTPUT" | grep -qE "Reached max turns|^Error:|API error|rate limit exceeded" || [[ "$EXIT_CODE" -ne 0 ]]; then
    aau_log "session failed (exit=$EXIT_CODE, action=$ACTION)"
    aau_jlog "warn" "session_failed" "\"action\":\"$ACTION\",\"exit\":$EXIT_CODE"
else
    aau_log "session succeeded (action=$ACTION)"
    aau_jlog "info" "session_succeeded" "\"action\":\"$ACTION\""

    case "$ACTION" in
        REPORT_DUE)
            touch "$REPORT_MARKER"
            ;;
        DONE_FOLLOWUP)
            DONE_NOW=""
            for M in $(aau_team_members); do
                TF="$TEAM_DIR/$M/tasks.md"
                [[ -f "$TF" ]] || continue
                MD=$(grep -c '\[DONE\]' "$TF" 2>/dev/null || true)
                [[ "$MD" -gt 0 ]] && DONE_NOW="${DONE_NOW}${M}:${MD} "
            done
            echo "$DONE_NOW" | aau_md5 > "$DONE_SEED"
            ;;
    esac
fi

# Clean old daily counters
find "${AAU_TMP}" -name "${AAU_PREFIX}_autonomous_daily_*" -not -name "*${TODAY}" -delete 2>/dev/null

aau_log "=== done (exit=$EXIT_CODE, action=$ACTION) ==="
aau_jlog "info" "done" "\"exit\":$EXIT_CODE,\"action\":\"$ACTION\""
