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

# ─── Schedule check ──────────────────────────────────────────────────────
if ! aau_is_active "director"; then
    aau_log "outside active hours ($(aau_schedule_status director)), skip"
    aau_jlog "info" "schedule_skip"
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
REPORT_INTERVAL="${AAU_DIRECTOR_REPORT_INTERVAL:-3600}"
STALE_THRESHOLD="${AAU_DIRECTOR_STALE_THRESHOLD:-1800}"
REPORT_STATE_SEED="${AAU_TMP}/${AAU_PREFIX}_report_state_seed"
MILESTONE_SEED="${AAU_TMP}/${AAU_PREFIX}_milestone_seed"
APPROVAL_REMINDER_MARKER="${AAU_TMP}/${AAU_PREFIX}_approval_reminder"
APPROVAL_REMINDER_INTERVAL="${AAU_DIRECTOR_APPROVAL_REMINDER_INTERVAL:-21600}"
STATUS_FILE="$TEAM_DIR/director/status.md"

# --- 0. MILESTONE_REPORT (highest priority) ---
if [[ -f "$STATUS_FILE" ]]; then
    PHASE_LINES=$(grep -iE '^#+\s*(phase|step|フェーズ|ステップ)' "$STATUS_FILE" 2>/dev/null || true)
    if [[ -n "$PHASE_LINES" ]]; then
        CURRENT_MILESTONE_HASH=$(echo "$PHASE_LINES" | aau_md5)
        PREV_MILESTONE_HASH=""
        [[ -f "$MILESTONE_SEED" ]] && PREV_MILESTONE_HASH=$(cat "$MILESTONE_SEED" 2>/dev/null)
        if [[ -n "$PREV_MILESTONE_HASH" && "$CURRENT_MILESTONE_HASH" != "$PREV_MILESTONE_HASH" ]]; then
            ACTION="MILESTONE_REPORT"
            ACTION_DETAIL="milestone_changed=true"
        fi
        # Save initial snapshot if none exists
        if [[ ! -f "$MILESTONE_SEED" ]]; then
            echo "$CURRENT_MILESTONE_HASH" > "$MILESTONE_SEED"
        fi
    fi
fi

# --- 0.3. APPROVAL_PPT (director creates approval PPT via Claude) ---
if [[ "$ACTION" == "NO_ACTION" ]]; then
    APPROVAL_PPT_TRIGGER="${AAU_TMP}/${AAU_PREFIX}_trigger_approval_ppt"
    if [[ -f "$APPROVAL_PPT_TRIGGER" ]]; then
        ACTION="APPROVAL_PPT"
        # Get the latest PENDING AP-ID
        ACTION_DETAIL="$(grep -B1 '^status: PENDING' "$TEAM_DIR/director/approvals.md" 2>/dev/null | grep '^## AP-' | tail -1 | sed 's/^## //')"
        rm -f "$APPROVAL_PPT_TRIGGER"
    fi
fi

# --- 0.5. PHASE_COMPLETE (pipeline phase completion) ---
if [[ "$ACTION" == "NO_ACTION" ]]; then
    PHASE_TRIGGER="${AAU_TMP}/${AAU_PREFIX}_trigger_phase_complete"
    if [[ -f "$PHASE_TRIGGER" ]]; then
        ACTION="PHASE_COMPLETE"
        ACTION_DETAIL="$(cat "$PHASE_TRIGGER")"
        rm -f "$PHASE_TRIGGER"
    fi
fi

# --- 1. DONE_FOLLOWUP (highest priority after MILESTONE) ---
# Check before REPORT_DUE so new completions trigger task creation immediately
if [[ "$ACTION" == "NO_ACTION" ]]; then
    DONE_TASKS=""
    for MEMBER in $(aau_team_members); do
        TASKS_FILE="$TEAM_DIR/$MEMBER/tasks.md"
        if [[ -f "$TASKS_FILE" ]]; then
            M_DONE=$(grep -cE '^### TASK-.*\[DONE\]' "$TASKS_FILE" 2>/dev/null || true)
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

# --- 2. REPORT_DUE (blocked during approval pending — APPROVAL_REMINDER handles it) ---
_APPROVAL_PENDING=false
if [[ -f "$STATUS_FILE" ]] && grep -q '^status: PENDING' "$TEAM_DIR/director/approvals.md" 2>/dev/null; then
    _APPROVAL_PENDING=true
fi
if [[ "$_APPROVAL_PENDING" == "true" && "$ACTION" == "NO_ACTION" ]]; then
    aau_log "approval pending — skipping REPORT_DUE (APPROVAL_REMINDER handles notifications)"
    aau_jlog "info" "report_skip_approval"
fi
if [[ "$_APPROVAL_PENDING" == "false" && "$ACTION" != "MILESTONE_REPORT" && "$ACTION" != "DONE_FOLLOWUP" ]] && [[ -f "$REPORT_MARKER" ]]; then
    LAST_REPORT=$(aau_file_mtime "$REPORT_MARKER")
    REPORT_AGE=$(( NOW - LAST_REPORT ))
else
    REPORT_AGE=$((REPORT_INTERVAL + 1))
fi
if [[ "$_APPROVAL_PENDING" == "false" && "$ACTION" != "MILESTONE_REPORT" && "$ACTION" != "DONE_FOLLOWUP" && "$REPORT_AGE" -gt "$REPORT_INTERVAL" ]]; then
    CURRENT_STATE=""
    for MEMBER in $(aau_team_members); do
        TF="$TEAM_DIR/$MEMBER/tasks.md"
        if [[ -f "$TF" ]]; then
            P=$(grep -cE '^### TASK-.*\[PENDING\]' "$TF" 2>/dev/null || true)
            I=$(grep -cE '^### TASK-.*\[IN_PROGRESS\]' "$TF" 2>/dev/null || true)
            D=$(grep -cE '^### TASK-.*\[DONE\]' "$TF" 2>/dev/null || true)
            E=$(grep -cE '^### TASK-.*\[NEEDS_EVIDENCE\]' "$TF" 2>/dev/null || true)
            CURRENT_STATE="${CURRENT_STATE}${MEMBER}:${P}/${I}/${D}/${E} "
        fi
    done
    CURRENT_STATE_HASH=$(echo "$CURRENT_STATE" | aau_md5)
    PREV_STATE_HASH=""
    [[ -f "$REPORT_STATE_SEED" ]] && PREV_STATE_HASH=$(cat "$REPORT_STATE_SEED" 2>/dev/null)

    if [[ "$CURRENT_STATE_HASH" != "$PREV_STATE_HASH" ]]; then
        ACTION="REPORT_DUE"
        ACTION_DETAIL="last_report_age=${REPORT_AGE}s,state_changed=true"
    else
        aau_log "report interval passed but no state change, skip"
        aau_jlog "info" "report_skip_no_change" "\"age\":$REPORT_AGE"
        touch "$REPORT_MARKER"
    fi
fi

# --- 3. STALE_PROGRESS ---
if [[ "$ACTION" == "NO_ACTION" ]]; then
    for MEMBER in $(aau_team_members); do
        TASKS_FILE="$TEAM_DIR/$MEMBER/tasks.md"
        PROGRESS_FILE="$TEAM_DIR/$MEMBER/progress.md"
        if [[ -f "$TASKS_FILE" ]] && grep -qE '^### TASK-.*\[IN_PROGRESS\]' "$TASKS_FILE" 2>/dev/null; then
            if [[ -f "$PROGRESS_FILE" ]]; then
                PROG_AGE=$(( NOW - $(aau_file_mtime "$PROGRESS_FILE") ))
                if [[ "$PROG_AGE" -gt "$STALE_THRESHOLD" ]]; then
                    # Skip if we already failed STALE_PROGRESS for this member recently
                    STALE_FAIL_MARKER="${AAU_TMP}/${AAU_PREFIX}_stale_fail_${MEMBER}"
                    STALE_COOLDOWN="${AAU_STALE_FAIL_COOLDOWN:-7200}"
                    if [[ -f "$STALE_FAIL_MARKER" ]]; then
                        STALE_FAIL_AGE=$(( NOW - $(aau_file_mtime "$STALE_FAIL_MARKER") ))
                        if [[ "$STALE_FAIL_AGE" -lt "$STALE_COOLDOWN" ]]; then
                            aau_log "STALE_PROGRESS skip: $MEMBER failed recently (${STALE_FAIL_AGE}s ago, cooldown=${STALE_COOLDOWN}s)"
                            aau_jlog "info" "stale_skip_cooldown" "\"member\":\"$MEMBER\",\"age\":$STALE_FAIL_AGE"
                            continue
                        fi
                    fi
                    ACTION="STALE_PROGRESS"
                    ACTION_DETAIL="member=${MEMBER},progress_age=${PROG_AGE}s"
                    break
                fi
            fi
        fi
    done
fi

# --- 4. APPROVAL_REMINDER ---
if [[ "$ACTION" == "NO_ACTION" ]]; then
    if [[ -f "$TEAM_DIR/director/approvals.md" ]] && grep -q '^status: PENDING' "$TEAM_DIR/director/approvals.md" 2>/dev/null; then
        # Check if reminder is due (every APPROVAL_REMINDER_INTERVAL)
        SEND_REMINDER=false
        if [[ -f "$APPROVAL_REMINDER_MARKER" ]]; then
            LAST_REMINDER=$(aau_file_mtime "$APPROVAL_REMINDER_MARKER")
            REMINDER_AGE=$(( NOW - LAST_REMINDER ))
            if [[ "$REMINDER_AGE" -gt "$APPROVAL_REMINDER_INTERVAL" ]]; then
                SEND_REMINDER=true
            fi
        else
            SEND_REMINDER=true
        fi
        if [[ "$SEND_REMINDER" == "true" ]]; then
            ACTION="APPROVAL_REMINDER"
            ACTION_DETAIL="approval_pending=true"
        else
            # Block IDLE_ALL even if reminder not due
            ACTION="NO_ACTION"
            ACTION_DETAIL="approval_pending_waiting"
        fi
    fi
fi

# --- 5. IDLE_ALL (blocked by approval gate) ---
if [[ "$ACTION" == "NO_ACTION" ]]; then
    # Approval gate: if status.md has approval pending, do not enter IDLE_ALL
    if [[ -f "$STATUS_FILE" ]] && grep -q '^status: PENDING' "$TEAM_DIR/director/approvals.md" 2>/dev/null; then
        aau_log "approval pending in status.md, blocking IDLE_ALL"
        aau_jlog "info" "approval_gate_block"
        ACTION="NO_ACTION"
        ACTION_DETAIL="approval_gate_blocked"
    fi
fi

if [[ "$ACTION" == "NO_ACTION" ]]; then
    TOTAL_PENDING=0
    TOTAL_INPROG=0
    for MEMBER in $(aau_team_members); do
        TASKS_FILE="$TEAM_DIR/$MEMBER/tasks.md"
        if [[ -f "$TASKS_FILE" ]]; then
            P=$(grep -cE '^### TASK-.*\[PENDING\]' "$TASKS_FILE" 2>/dev/null || true)
            I=$(grep -cE '^### TASK-.*\[IN_PROGRESS\]' "$TASKS_FILE" 2>/dev/null || true)
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

# ─── NO_ACTION → heartbeat check, then zero-token exit ─────────────────
if [[ "$ACTION" == "NO_ACTION" ]]; then
    # ─── Heartbeat (zero-token) ─────────────────────────────────────────
    # Post a brief status pulse to Slack every HEARTBEAT_INTERVAL seconds
    # so the producer knows the system is alive, even when nothing changed.
    HEARTBEAT_MARKER="${AAU_TMP}/${AAU_PREFIX}_heartbeat"
    HEARTBEAT_INTERVAL="${AAU_DIRECTOR_HEARTBEAT_INTERVAL:-3600}"
    SEND_HEARTBEAT=false
    if [[ -f "$HEARTBEAT_MARKER" ]]; then
        LAST_HB=$(aau_file_mtime "$HEARTBEAT_MARKER")
        HB_AGE=$(( NOW - LAST_HB ))
        if [[ "$HB_AGE" -gt "$HEARTBEAT_INTERVAL" ]]; then
            SEND_HEARTBEAT=true
        fi
    else
        SEND_HEARTBEAT=true
    fi

    if [[ "$SEND_HEARTBEAT" == "true" ]]; then
        # Build summary from task files (pure bash, zero-token)
        HB_TOTAL_P=0; HB_TOTAL_I=0; HB_TOTAL_D=0; HB_TOTAL_E=0
        for _M in $(aau_team_members); do
            _TF="$TEAM_DIR/$_M/tasks.md"
            if [[ -f "$_TF" ]]; then
                _P=$(grep -cE '^### TASK-.*\[PENDING\]' "$_TF" 2>/dev/null || true)
                _I=$(grep -cE '^### TASK-.*\[IN_PROGRESS\]' "$_TF" 2>/dev/null || true)
                _D=$(grep -cE '^### TASK-.*\[DONE\]' "$_TF" 2>/dev/null || true)
                _E=$(grep -cE '^### TASK-.*\[NEEDS_EVIDENCE\]' "$_TF" 2>/dev/null || true)
                HB_TOTAL_P=$(( HB_TOTAL_P + _P ))
                HB_TOTAL_I=$(( HB_TOTAL_I + _I ))
                HB_TOTAL_D=$(( HB_TOTAL_D + _D ))
                HB_TOTAL_E=$(( HB_TOTAL_E + _E ))
            fi
        done
        HB_TOTAL=$(( HB_TOTAL_P + HB_TOTAL_I + HB_TOTAL_D + HB_TOTAL_E ))
        if [[ "$HB_TOTAL" -gt 0 ]]; then
            HB_DONE_PCT=$(( HB_TOTAL_D * 100 / HB_TOTAL ))
        else
            HB_DONE_PCT=0
        fi
        HB_MSG="[Heartbeat] 稼働中 | 全${HB_TOTAL}件: 完了${HB_TOTAL_D}(${HB_DONE_PCT}%) 進行${HB_TOTAL_I} 待機${HB_TOTAL_P}"
        if [[ "$HB_TOTAL_E" -gt 0 ]]; then
            HB_MSG="${HB_MSG} 要証跡${HB_TOTAL_E}"
        fi
        # Append roadmap progress (zero Claude-token)
        source "$SCRIPT_DIR/task_summarizer.sh"
        HB_ROADMAP=$(aau_roadmap_summary 2>/dev/null)
        if [[ -n "$HB_ROADMAP" && "$HB_ROADMAP" != "(ロードマップなし)" ]]; then
            HB_MSG="${HB_MSG}
${HB_ROADMAP}"
        fi
        # Append task summaries from local LLM (zero Claude-token)
        HB_DETAIL=$(aau_task_summary_compact 600 2>/dev/null)
        if [[ -n "$HB_DETAIL" && "$HB_DETAIL" != *"タスクなし"* ]]; then
            HB_MSG="${HB_MSG}
${HB_DETAIL}"
        fi
        aau_notify "$HB_MSG"
        touch "$HEARTBEAT_MARKER"
        aau_log "heartbeat sent"
        aau_jlog "info" "heartbeat_sent" "\"pending\":$HB_TOTAL_P,\"inprogress\":$HB_TOTAL_I,\"done\":$HB_TOTAL_D"
    fi

    aau_log "=== no action needed, exit ==="
    aau_jlog "info" "no_action_exit"
    exit 0
fi

# ─── APPROVAL_REMINDER → notify only, no Claude (zero-token) ───────────
if [[ "$ACTION" == "APPROVAL_REMINDER" ]]; then
    # Include pending approval summaries (human-readable, no AP-ID required)
    _PENDING_SUMMARIES=$(python3 -c "
import re
with open('$TEAM_DIR/director/approvals.md') as f:
    content = f.read()
lines = content.split('\n')
for i, line in enumerate(lines):
    if line.startswith('## AP-'):
        if i+1 < len(lines) and 'PENDING' in lines[i+1]:
            # Extract summary after AP-XXX
            summary = re.sub(r'^## AP-\d+\s*', '', line).strip()
            print(f'・{summary}')
" 2>/dev/null)
    aau_notify_flush "プロデューサーの承認をお待ちしています。\n${_PENDING_SUMMARIES}\n\n承認する場合は「承認」「進めて」「OK」のいずれかをご返信ください。却下する場合は「却下」と理由をお伝えください。"
    touch "$APPROVAL_REMINDER_MARKER"
    aau_log "=== approval reminder sent, exit ==="
    aau_jlog "info" "approval_reminder_sent"
    exit 0
fi

# ─── PHASE_COMPLETE → zero-token pipeline advance ────────────────────────
if [[ "$ACTION" == "PHASE_COMPLETE" ]]; then
    cd "$AAU_PROJECT_ROOT"
    source "$SCRIPT_DIR/pipeline.sh"
    REQUIRE_APPROVAL="${AAU_PIPELINE_REQUIRE_APPROVAL:-true}"
    if [[ "$REQUIRE_APPROVAL" == "true" ]]; then
        source "$SCRIPT_DIR/approval.sh"
        source "$SCRIPT_DIR/dashboard.sh"
        PHASE_INFO=$(aau_pipeline_status)
        PHASE_NAME=$(echo "$PHASE_INFO" | cut -d'|' -f2)
        DASH_TEXT=$(aau_dashboard_summary 2>/dev/null)
        aau_create_approval "Phase完了: ${PHASE_NAME} — 次フェーズ移行" "${DASH_TEXT}"
    else
        aau_pipeline_advance
        source "$SCRIPT_DIR/dashboard.sh"
        aau_update_dashboard
    fi
    aau_log "=== done (phase_complete) ==="
    aau_jlog "info" "done" "\"action\":\"PHASE_COMPLETE\""
    exit 0
fi

# ─── DONE_FOLLOWUP → zero-token ──────────────────────────────────────────
if [[ "$ACTION" == "DONE_FOLLOWUP" ]]; then
    cd "$AAU_PROJECT_ROOT"
    source "$SCRIPT_DIR/task_lifecycle.sh"
    aau_followup_done
    # Update DONE_SEED
    DONE_NOW=""
    for _M in $(aau_team_members); do
        _TF="$TEAM_DIR/$_M/tasks.md"
        [[ -f "$_TF" ]] || continue
        _MD=$(grep -cE '^### TASK-.*\[DONE\]' "$_TF" 2>/dev/null || true)
        [[ "$_MD" -gt 0 ]] && DONE_NOW="${DONE_NOW}${_M}:${_MD} "
    done
    echo "$DONE_NOW" | aau_md5 > "$DONE_SEED"
    aau_log "=== done (done_followup_zero_token) ==="
    aau_jlog "info" "done" "\"action\":\"DONE_FOLLOWUP\",\"method\":\"zero_token\""
    exit 0
fi

# ─── REPORT_DUE → zero-token ────────────────────────────────────────────
if [[ "$ACTION" == "REPORT_DUE" ]]; then
    cd "$AAU_PROJECT_ROOT"
    source "$SCRIPT_DIR/task_summarizer.sh"
    REPORT_MSG="[進捗報告]"
    # Roadmap progress
    _RM=$(aau_roadmap_summary 2>/dev/null)
    [[ -n "$_RM" && "$_RM" != "(ロードマップなし)" ]] && REPORT_MSG="${REPORT_MSG}\n${_RM}"
    # Task summary
    _TS=$(aau_task_summary_compact 1 2>/dev/null)
    [[ -n "$_TS" && "$_TS" != *"タスクなし"* ]] && REPORT_MSG="${REPORT_MSG}\n${_TS}"
    aau_notify "$(echo -e "$REPORT_MSG")"
    touch "$REPORT_MARKER"
    echo "$CURRENT_STATE_HASH" > "$REPORT_STATE_SEED"
    aau_log "=== done (report_due_zero_token) ==="
    aau_jlog "info" "done" "\"action\":\"REPORT_DUE\",\"method\":\"zero_token\""
    exit 0
fi

# ─── IDLE_ALL → zero-token ──────────────────────────────────────────────
if [[ "$ACTION" == "IDLE_ALL" ]]; then
    cd "$AAU_PROJECT_ROOT"
    source "$SCRIPT_DIR/task_lifecycle.sh"
    aau_idle_all
    aau_log "=== done (idle_all_zero_token) ==="
    aau_jlog "info" "done" "\"action\":\"IDLE_ALL\",\"method\":\"zero_token\""
    exit 0
fi

# ─── STALE_PROGRESS → zero-token auto-decompose ─────────────────────────
if [[ "$ACTION" == "STALE_PROGRESS" ]]; then
    cd "$AAU_PROJECT_ROOT"
    source "$SCRIPT_DIR/task_decomposer.sh"
    STALE_MEMBER=$(echo "$ACTION_DETAIL" | grep -oE 'member=[a-z]+' | cut -d= -f2)
    aau_log "auto-decompose: attempting for $STALE_MEMBER"

    if aau_decompose_stale_task "$STALE_MEMBER"; then
        aau_notify "[Auto-Split] ${STALE_MEMBER}の停滞タスクを分割しました。サブタスクを順次処理します。"
        aau_jlog "info" "stale_auto_decomposed" "\"member\":\"$STALE_MEMBER\""
    else
        # Ollama failed — fall back to Claude with limited template
        aau_log "auto-decompose failed, falling back to Claude"
        touch "${AAU_TMP}/${AAU_PREFIX}_stale_fail_${STALE_MEMBER}"
        # Notify producer only once (fallback dedup handles this)
        if _should_post_fallback 2>/dev/null; then
            aau_notify "[Stale] ${STALE_MEMBER}のタスク自動分割に失敗。プロデューサー確認をお願いします。"
            touch "${AAU_TMP}/${AAU_PREFIX}_fallback_STALE_PROGRESS"
        fi
    fi
    aau_log "=== done (stale_auto_decompose) ==="
    aau_jlog "info" "done" "\"action\":\"STALE_PROGRESS\",\"method\":\"auto_decompose\""
    exit 0
fi

# ─── Render prompt from template ─────────────────────────────────────────
cd "$AAU_PROJECT_ROOT"
OUTFILE="${AAU_TMP}/${AAU_PREFIX}_director_autonomous_$$.out"

# Map action to template and max_turns
case "$ACTION" in
    MILESTONE_REPORT)
        TEMPLATE="director_milestone_report.txt"
        MAX_TURNS="${AAU_DIRECTOR_MAX_TURNS_MILESTONE:-10}"
        ;;
    REPORT_DUE)
        TEMPLATE="director_report.txt"
        MAX_TURNS="${AAU_DIRECTOR_MAX_TURNS_REPORT:-15}"
        ;;
    DONE_FOLLOWUP)
        TEMPLATE="director_done_followup.txt"
        MAX_TURNS="${AAU_DIRECTOR_MAX_TURNS_FOLLOWUP:-20}"
        ;;
    STALE_PROGRESS)
        # Fallback only — normally handled by zero-token above
        TEMPLATE="director_stale_progress.txt"
        MAX_TURNS="${AAU_DIRECTOR_MAX_TURNS_STALE:-10}"
        ;;
    IDLE_ALL)
        TEMPLATE="director_idle_all.txt"
        MAX_TURNS="${AAU_DIRECTOR_MAX_TURNS_IDLE:-25}"
        ;;
    APPROVAL_PPT)
        TEMPLATE="director_approval_ppt.txt"
        MAX_TURNS="${AAU_DIRECTOR_MAX_TURNS_APPROVAL:-30}"
        ;;
esac

# Extract AP-ID for approval templates
_AP_ID=""
if [[ "$ACTION" == "APPROVAL_PPT" ]]; then
    _AP_ID=$(echo "$ACTION_DETAIL" | grep -oE 'AP-[0-9]+' | head -1)
    _AP_SUMMARY=$(echo "$ACTION_DETAIL" | sed 's/^AP-[0-9]* //')
fi
PROMPT=$(aau_render_prompt "$TEMPLATE" "action_detail=$ACTION_DETAIL" "ap_id=${_AP_ID}" "summary=${_AP_SUMMARY}")
if [[ -z "$PROMPT" ]]; then
    aau_log "ERROR: prompt template $TEMPLATE not found, abort"
    aau_jlog "error" "missing_template" "\"template\":\"$TEMPLATE\""
    exit 1
fi

# Inject task summary from local LLM so Claude uses concrete descriptions
source "$SCRIPT_DIR/task_summarizer.sh"
TASK_SUMMARY=$(aau_task_summary 600 2>/dev/null)
if [[ -n "$TASK_SUMMARY" && "$TASK_SUMMARY" != "(タスクなし)" ]]; then
    PROMPT="${PROMPT}

## タスク要約（ローカルLLM生成 — Slack報告時はこの要約を使うこと）
TASK番号だけでなく、以下の要約を使って具体的に何をしているか伝えること:
${TASK_SUMMARY}"
fi

# Inject notification instructions if plugin is configured
NOTIFY_PLUGIN="${AAU_NOTIFICATION_PLUGIN:-none}"
if [[ "$NOTIFY_PLUGIN" == "slack" && -n "$SLACK_TOKEN" && -n "$SLACK_CHANNEL" ]]; then
    PROMPT="$PROMPT

## Slack投稿（絶対厳守 — これを怠ると全作業が無意味になる）
作業完了後、**必ずBashツールで以下のcurlコマンドを実行せよ**。
「送信済み」と書くだけでは投稿されない。curlを実際に実行しなければプロデューサーに何も届かない。

### 投稿内容の構成
- 1行目: フェーズ名と進捗率
- 2行目: 完了タスク数と主要成果物
- 3行目: 進行中タスクとメンバー
- 4行目: 次のアクション

### 実行するコマンド（変数はそのまま使える）
\`\`\`bash
curl -s -X POST 'https://slack.com/api/chat.postMessage' \\
  -H 'Authorization: Bearer $SLACK_TOKEN' \\
  -H 'Content-Type: application/json' \\
  -d '{\"channel\":\"$SLACK_CHANNEL\",\"text\":\"ここに報告内容を書く\"}'
\`\`\`

環境変数:
SLACK_TOKEN=\"$SLACK_TOKEN\"
SLACK_CHANNEL=\"$SLACK_CHANNEL\"

**curlを実行せずにセッションを終了してはならない。投稿しなければプロデューサーには何も見えない。**"
fi

# ─── Launch Claude ───────────────────────────────────────────────────────
TIMEOUT="${AAU_DIRECTOR_TIMEOUT:-600}"
echo $(( DAILY_COUNT + 1 )) > "$DAILY_FILE"

# Use Opus for approval PPT if configured
DIRECTOR_MODEL="$AAU_MODEL"
if [[ "$ACTION" == "APPROVAL_PPT" ]]; then
    DIRECTOR_MODEL="${AAU_DIRECTOR_APPROVAL_MODEL:-${AAU_MODEL}}"
    TIMEOUT="${AAU_DIRECTOR_APPROVAL_TIMEOUT:-900}"
fi

aau_log "launching Claude (action=$ACTION, model=$DIRECTOR_MODEL, max_turns=$MAX_TURNS)"
aau_jlog "info" "claude_launch" "\"action\":\"$ACTION\",\"model\":\"$DIRECTOR_MODEL\",\"max_turns\":$MAX_TURNS"

DIRECTOR_TOOLS="Read,Write,Edit,Bash"
aau_run_with_timeout "$TIMEOUT" "$OUTFILE" "$PROMPT" "$AAU_CLAUDE" \
    --model "$DIRECTOR_MODEL" \
    --print \
    --permission-mode "$AAU_PERM" \
    --max-turns "$MAX_TURNS" \
    --tools "$DIRECTOR_TOOLS" \
    --allowedTools "$DIRECTOR_TOOLS"

EXIT_CODE=$?
OUTPUT=$(cat "$OUTFILE" 2>/dev/null)
rm -f "$OUTFILE"
echo "$OUTPUT" >> "$_AAU_LOG_FILE"

# ─── Result handling ─────────────────────────────────────────────────────
# Fallback dedup: don't post the same fallback message within 2 hours
FALLBACK_MARKER="${AAU_TMP}/${AAU_PREFIX}_fallback_${ACTION}"
FALLBACK_COOLDOWN=7200

_should_post_fallback() {
    if [[ -f "$FALLBACK_MARKER" ]]; then
        local age=$(( NOW - $(aau_file_mtime "$FALLBACK_MARKER") ))
        [[ "$age" -ge "$FALLBACK_COOLDOWN" ]]
    else
        return 0
    fi
}

if [[ "$EXIT_CODE" -eq 124 ]]; then
    aau_log "session timed out after ${TIMEOUT}s"
    aau_jlog "error" "session_timeout" "\"action\":\"$ACTION\""
    if _should_post_fallback; then
        aau_notify "[Fallback] ${ACTION} セッションがタイムアウトしました (${TIMEOUT}s)。2時間後にリトライします。"
        touch "$FALLBACK_MARKER"
    fi
    # Mark STALE_PROGRESS failure for cooldown
    if [[ "$ACTION" == "STALE_PROGRESS" ]]; then
        STALE_MEMBER=$(echo "$ACTION_DETAIL" | grep -oE 'member=[a-z]+' | cut -d= -f2)
        [[ -n "$STALE_MEMBER" ]] && touch "${AAU_TMP}/${AAU_PREFIX}_stale_fail_${STALE_MEMBER}"
    fi
elif echo "$OUTPUT" | grep -qE "Reached max turns|^Error:|API error|rate limit exceeded" || [[ "$EXIT_CODE" -ne 0 ]]; then
    aau_log "session failed (exit=$EXIT_CODE, action=$ACTION)"
    aau_jlog "warn" "session_failed" "\"action\":\"$ACTION\",\"exit\":$EXIT_CODE"
    FAIL_REASON="exit=$EXIT_CODE"
    echo "$OUTPUT" | grep -qE "Reached max turns" && FAIL_REASON="max_turns超過"
    echo "$OUTPUT" | grep -qE "rate limit" && FAIL_REASON="レート制限"
    echo "$OUTPUT" | grep -qE "API error" && FAIL_REASON="APIエラー"
    if _should_post_fallback; then
        aau_notify "[Fallback] ${ACTION} セッションが失敗しました (${FAIL_REASON})。2時間後にリトライします。"
        touch "$FALLBACK_MARKER"
    fi
    # Mark STALE_PROGRESS failure for cooldown
    if [[ "$ACTION" == "STALE_PROGRESS" ]]; then
        STALE_MEMBER=$(echo "$ACTION_DETAIL" | grep -oE 'member=[a-z]+' | cut -d= -f2)
        [[ -n "$STALE_MEMBER" ]] && touch "${AAU_TMP}/${AAU_PREFIX}_stale_fail_${STALE_MEMBER}"
    fi
else
    aau_log "session succeeded (action=$ACTION)"
    aau_jlog "info" "session_succeeded" "\"action\":\"$ACTION\""

    case "$ACTION" in
        MILESTONE_REPORT)
            # Update milestone snapshot so same change doesn't fire again
            echo "$CURRENT_MILESTONE_HASH" > "$MILESTONE_SEED"
            ;;
        REPORT_DUE)
            touch "$REPORT_MARKER"
            # Save state hash to prevent duplicate reports when nothing changed
            echo "$CURRENT_STATE_HASH" > "$REPORT_STATE_SEED"
            ;;
        DONE_FOLLOWUP)
            DONE_NOW=""
            for M in $(aau_team_members); do
                TF="$TEAM_DIR/$M/tasks.md"
                [[ -f "$TF" ]] || continue
                MD=$(grep -cE '^### TASK-.*\[DONE\]' "$TF" 2>/dev/null || true)
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
