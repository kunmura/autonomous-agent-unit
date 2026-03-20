#!/bin/bash
# director_responder.sh — Respond to inbox messages
# Triggered when inbox.md has UNREAD entries. Zero-token otherwise.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
aau_init_logging "director_responder"

aau_log "=== director_responder start ==="
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

# ─── Daily invocation limit ─────────────────────────────────────────
TODAY=$(date +%Y-%m-%d)
DAILY_FILE="${AAU_TMP}/${AAU_PREFIX}_responder_daily_${TODAY}"
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

# Lock
if ! aau_acquire_lock "director_responder"; then
    exit 0
fi

# Check inbox
INBOX="$AAU_PROJECT_ROOT/team/director/inbox.md"
if [[ ! -f "$INBOX" ]] || ! grep -q "ステータス: UNREAD" "$INBOX"; then
    aau_log "no UNREAD entries, exit"
    aau_jlog "info" "no_unread_exit"
    exit 0
fi

UNREAD_COUNT=$(grep -c "ステータス: UNREAD" "$INBOX" || true)
aau_log "UNREAD entries: $UNREAD_COUNT"
aau_jlog "info" "unread_found" "\"count\":$UNREAD_COUNT"

# ─── Exponential backoff ────────────────────────────────────────────────
RETRY_DIR="${AAU_TMP}/${AAU_PREFIX}_director_retries"
mkdir -p "$RETRY_DIR"
MAX_RETRIES="${AAU_RETRY_MAX_RETRIES:-3}"
BACKOFF_BASE="${AAU_RETRY_BACKOFF_BASE:-300}"
NOW=$(date +%s)

INBOX_HASH=$(grep -B2 "ステータス: UNREAD" "$INBOX" | aau_md5)
RETRY_FILE="$RETRY_DIR/${INBOX_HASH}.txt"
RETRY_COUNT=0

if [[ -f "$RETRY_FILE" ]]; then
    RETRY_COUNT=$(awk -F: '{print $1}' "$RETRY_FILE")
    WAIT_UNTIL=$(awk -F: '{print $2}' "$RETRY_FILE")

    if [[ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]]; then
        aau_log "retry limit reached ($RETRY_COUNT/$MAX_RETRIES), aborting"
        aau_jlog "error" "retry_limit_abort" "\"retry_count\":$RETRY_COUNT"
        aau_notify "⛔ Director processing aborted after $MAX_RETRIES retries"
        sed -i '' 's/ステータス: UNREAD/ステータス: ABORTED/g' "$INBOX"
        rm -f "$RETRY_FILE"
        exit 0
    fi

    if [[ "$NOW" -lt "$WAIT_UNTIL" ]]; then
        WAIT_REMAINING=$(( WAIT_UNTIL - NOW ))
        aau_log "backoff active (attempt $RETRY_COUNT/$MAX_RETRIES, wait ${WAIT_REMAINING}s), skip"
        exit 0
    fi
fi

# Mark UNREAD → PROCESSING
sed -i '' 's/ステータス: UNREAD/ステータス: PROCESSING/g' "$INBOX"

# ─── Main session ───────────────────────────────────────────────────────
cd "$AAU_PROJECT_ROOT"
TIMEOUT="${AAU_DIRECTOR_TIMEOUT:-600}"
MAX_TURNS="${AAU_DIRECTOR_MAX_TURNS_RESPOND:-40}"
OUTFILE="${AAU_TMP}/${AAU_PREFIX}_director_responder_$$.out"

PROMPT=$(aau_render_prompt "director_respond_inbox.txt")
if [[ -z "$PROMPT" ]]; then
    PROMPT="team/director/inbox.md を読み、ステータスがPROCESSINGのエントリに対応せよ。完了後、ステータスをREADに更新する。"
fi

# Inject notification instructions
NOTIFY_PLUGIN="${AAU_NOTIFICATION_PLUGIN:-none}"
if [[ "$NOTIFY_PLUGIN" == "slack" && -n "$SLACK_TOKEN" && -n "$SLACK_CHANNEL" ]]; then
    PROMPT="$PROMPT

## Slack投稿（絶対厳守 — これを怠ると全作業が無意味になる）
タスク振り完了後、**必ずBashツールで以下のcurlコマンドを実行せよ**。
「送信済み」と書くだけでは投稿されない。curlを実際に実行しなければプロデューサーに何も届かない。

### 投稿ルール
1. 必ず最後のステップとしてcurlを実行する
2. 投稿テキストはプロデューサーの依頼への回答＋どのメンバーに何を振ったかの要約
3. curlのレスポンスに \"ok\":true が含まれることを確認する

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

**curlを実行しないままinbox.mdをREADにしてはならない。**"
fi

aau_log "launching Claude (max_turns=$MAX_TURNS)"
aau_jlog "info" "claude_launch" "\"max_turns\":$MAX_TURNS"

DIRECTOR_TOOLS="Read,Write,Edit,Bash"
aau_run_with_timeout "$TIMEOUT" "$OUTFILE" "$PROMPT" "$AAU_CLAUDE" \
    --model "$AAU_MODEL" \
    --print \
    --permission-mode "$AAU_PERM" \
    --max-turns "$MAX_TURNS" \
    --tools "$DIRECTOR_TOOLS" \
    --allowedTools "$DIRECTOR_TOOLS"

MAIN_EXIT=$?
MAIN_OUTPUT=$(cat "$OUTFILE" 2>/dev/null)
rm -f "$OUTFILE"
echo "$MAIN_OUTPUT" >> "$_AAU_LOG_FILE"

# ─── Failure handling with backoff ───────────────────────────────────────
if [[ "$MAIN_EXIT" -eq 124 ]]; then
    aau_jlog "error" "session_timeout" "\"timeout\":$TIMEOUT"
fi

if echo "$MAIN_OUTPUT" | grep -qE "Reached max turns|^Error:|API error|rate limit exceeded" || [[ "$MAIN_EXIT" -ne 0 ]]; then
    NEW_COUNT=$(( RETRY_COUNT + 1 ))
    BACKOFF_SECS=$(( BACKOFF_BASE * NEW_COUNT ))
    NEXT_RETRY=$(( NOW + BACKOFF_SECS ))
    echo "${NEW_COUNT}:${NEXT_RETRY}" > "$RETRY_FILE"

    aau_log "session failed (attempt $NEW_COUNT/$MAX_RETRIES, backoff ${BACKOFF_SECS}s)"
    aau_jlog "warn" "session_failed" "\"attempt\":$NEW_COUNT,\"backoff\":$BACKOFF_SECS"

    if [[ "$NEW_COUNT" -lt "$MAX_RETRIES" ]]; then
        sed -i '' 's/ステータス: PROCESSING/ステータス: UNREAD/g' "$INBOX"
    fi
else
    rm -f "$RETRY_FILE"
    echo $(( DAILY_COUNT + 1 )) > "$DAILY_FILE"
    find "${AAU_TMP}" -name "${AAU_PREFIX}_responder_daily_*" -not -name "*${TODAY}" -delete 2>/dev/null
    aau_log "session succeeded"
    aau_jlog "info" "session_succeeded"
fi

aau_log "=== done (exit=$MAIN_EXIT) ==="
aau_jlog "info" "done" "\"exit\":$MAIN_EXIT"
