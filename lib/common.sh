#!/bin/bash
# common.sh — Shared functions for all AAU scripts
# Usage: source lib/common.sh

AAU_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-load config if not already loaded
if [[ -z "$AAU_CONFIG_FILE" ]]; then
    source "$AAU_LIB_DIR/config.sh"
    aau_load_config
fi

# Load schedule module
if [[ -f "$AAU_LIB_DIR/schedule.sh" ]]; then
    source "$AAU_LIB_DIR/schedule.sh"
elif [[ -n "$AAU_ROOT" && -f "$AAU_ROOT/lib/schedule.sh" ]]; then
    source "$AAU_ROOT/lib/schedule.sh"
fi

# ─── Platform detection ──────────────────────────────────────────────────
AAU_PLATFORM="$(uname -s)"

aau_file_mtime() {
    if [[ "$AAU_PLATFORM" == "Darwin" ]]; then
        stat -f %m "$1" 2>/dev/null || echo 0
    else
        stat -c %Y "$1" 2>/dev/null || echo 0
    fi
}

aau_md5() {
    if command -v md5 >/dev/null 2>&1; then
        md5 | cut -c1-12
    else
        md5sum | cut -c1-12
    fi
}

# ─── Logging ─────────────────────────────────────────────────────────────
_AAU_LOG_FILE=""
_AAU_JSONL_FILE=""
_AAU_SESSION_ID=""

aau_init_logging() {
    local component="$1"
    _AAU_LOG_FILE="${AAU_TMP}/${AAU_PREFIX}_${component}.log"
    _AAU_JSONL_FILE="${AAU_TMP}/${AAU_PREFIX}_${component}.jsonl"
    _AAU_SESSION_ID="${component}_$(date +%s)"
}

aau_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$_AAU_LOG_FILE"
}

aau_jlog() {
    local level="$1" msg="$2" extra="${3:-}"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '{"ts":"%s","session":"%s","level":"%s","msg":"%s"%s}\n' \
        "$ts" "$_AAU_SESSION_ID" "$level" "$msg" "${extra:+,$extra}" >> "$_AAU_JSONL_FILE"
}

# ─── Locking ─────────────────────────────────────────────────────────────

aau_acquire_lock() {
    local lock_name="$1"
    local lock_file="${AAU_TMP}/${AAU_PREFIX}_${lock_name}.lock"
    local max_age="${AAU_LOCKS_MAX_AGE:-1800}"

    if [[ -f "$lock_file" ]]; then
        local lock_pid
        lock_pid=$(cat "$lock_file" 2>/dev/null)
        local lock_age=$(( $(date +%s) - $(aau_file_mtime "$lock_file") ))

        if kill -0 "$lock_pid" 2>/dev/null; then
            if [[ "$lock_age" -gt "$max_age" ]]; then
                aau_log "lock $lock_name held by PID=$lock_pid for ${lock_age}s, force killing"
                aau_jlog "warn" "force_kill_stale" "\"pid\":$lock_pid,\"age\":$lock_age"
                kill "$lock_pid" 2>/dev/null
                sleep 2
                kill -9 "$lock_pid" 2>/dev/null
                rm -f "$lock_file"
            else
                aau_log "already running (PID=$lock_pid, age=${lock_age}s), skip"
                return 1
            fi
        else
            aau_log "stale lock removed (PID=$lock_pid dead)"
            rm -f "$lock_file"
        fi
    fi

    echo $$ > "$lock_file"
    trap "rm -f '$lock_file'" EXIT
    return 0
}

# ─── Timeout ─────────────────────────────────────────────────────────────

aau_run_with_timeout() {
    local timeout_secs="$1" outfile="$2" stdin_data="$3"; shift 3
    # Pass prompt via stdin to avoid conflicts with --tools flag
    # (Claude CLI cannot accept positional prompt when --tools is specified)
    echo "$stdin_data" | "$@" > "$outfile" 2>&1 &
    local cmd_pid=$!
    ( sleep "$timeout_secs" && kill "$cmd_pid" 2>/dev/null && kill -- -"$cmd_pid" 2>/dev/null ) &
    local watchdog_pid=$!
    wait "$cmd_pid" 2>/dev/null
    local exit_code=$?
    kill "$watchdog_pid" 2>/dev/null; wait "$watchdog_pid" 2>/dev/null
    if [[ $exit_code -eq 143 ]]; then exit_code=124; fi
    return $exit_code
}

# ─── Notification ────────────────────────────────────────────────────────

aau_notify() {
    local message="$1"
    local agent_name="${2:-}"
    local queue="${AAU_TMP}/${AAU_PREFIX}_slack_queue"
    local full_msg="$message"
    [[ -n "$agent_name" ]] && full_msg="[by ${agent_name}] ${message}"
    # Write to queue — slack_monitor will consume, dedup, and post
    echo "$(date +%s)|${full_msg}" >> "$queue" 2>/dev/null
    aau_log "notification queued: ${full_msg:0:80}"
}

# Direct posting, bypasses queue (for emergencies, approval reminders)
aau_notify_flush() {
    local message="$1"
    local agent_name="${2:-}"
    local plugin="${AAU_NOTIFICATION_PLUGIN:-none}"
    local full_msg="$message"
    [[ -n "$agent_name" ]] && full_msg="[by ${agent_name}] ${message}"

    case "$plugin" in
        slack)
            local plugin_script="$AAU_ROOT/plugins/slack/notify.sh"
            if [[ -f "$plugin_script" ]]; then
                source "$plugin_script"
                aau_plugin_notify "$full_msg"
            fi
            ;;
        discord|webhook)
            local plugin_script="$AAU_ROOT/plugins/${plugin}/notify.sh"
            if [[ -f "$plugin_script" ]]; then
                source "$plugin_script"
                aau_plugin_notify "$full_msg"
            fi
            ;;
        none)
            aau_log "notification (no plugin): $full_msg"
            ;;
    esac
}

# Upload a file to Slack (reuses approval.sh upload pattern)
# Args: $1=file_path $2=title(optional) $3=initial_comment(optional)
aau_upload_file() {
    local file_path="$1"
    local title="${2:-$(basename "$file_path")}"
    local comment="${3:-}"

    [[ -f "$file_path" ]] || return 1
    [[ -z "$SLACK_TOKEN" || -z "$SLACK_CHANNEL" ]] && return 1

    local file_size
    file_size=$(stat -f%z "$file_path" 2>/dev/null || stat -c%s "$file_path" 2>/dev/null)
    # Skip files >10MB
    [[ "$file_size" -gt 10485760 ]] && return 1

    local file_name
    file_name=$(basename "$file_path")

    # Step 1: Get upload URL
    local resp
    resp=$(curl -s -X POST 'https://slack.com/api/files.getUploadURLExternal' \
        -H "Authorization: Bearer ${SLACK_TOKEN}" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d "filename=${file_name}&length=${file_size}")
    local upload_url file_id
    upload_url=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('upload_url',''))" 2>/dev/null)
    file_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('file_id',''))" 2>/dev/null)
    [[ -z "$upload_url" || -z "$file_id" ]] && return 1

    # Step 2: Upload file content
    curl -s -X POST "$upload_url" -F "file=@${file_path}" > /dev/null 2>&1

    # Step 3: Complete upload
    local complete_body="{\"files\":[{\"id\":\"${file_id}\",\"title\":\"${title}\"}],\"channel_id\":\"${SLACK_CHANNEL}\""
    if [[ -n "$comment" ]]; then
        # Escape JSON special chars in comment
        local escaped_comment
        escaped_comment=$(echo "$comment" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null | sed 's/^"//;s/"$//')
        complete_body="${complete_body},\"initial_comment\":\"${escaped_comment}\""
    fi
    complete_body="${complete_body}}"

    curl -s -X POST 'https://slack.com/api/files.completeUploadExternal' \
        -H "Authorization: Bearer ${SLACK_TOKEN}" \
        -H 'Content-Type: application/json' \
        -d "$complete_body" > /dev/null 2>&1

    aau_log "file uploaded: $file_name"
    return 0
}

# ─── Prompt rendering ───────────────────────────────────────────────────

aau_render_prompt() {
    local template_name="$1"; shift
    # Remaining args: key=value pairs for substitution
    local lang="${AAU_PROMPTS_LANGUAGE:-ja}"
    local custom_dir="${AAU_PROMPTS_CUSTOM_DIR:-}"

    local template_file=""
    # Check custom dir first
    if [[ -n "$custom_dir" && -f "$AAU_PROJECT_ROOT/$custom_dir/$template_name" ]]; then
        template_file="$AAU_PROJECT_ROOT/$custom_dir/$template_name"
    elif [[ -f "$AAU_ROOT/templates/prompts/$lang/$template_name" ]]; then
        template_file="$AAU_ROOT/templates/prompts/$lang/$template_name"
    elif [[ -f "$AAU_ROOT/templates/prompts/en/$template_name" ]]; then
        template_file="$AAU_ROOT/templates/prompts/en/$template_name"
    fi

    if [[ -z "$template_file" ]]; then
        echo "ERROR: prompt template '$template_name' not found" >&2
        return 1
    fi

    local content
    content=$(cat "$template_file")

    # Built-in variables
    content="${content//\{\{project_name\}\}/${AAU_PROJECT_NAME:-project}}"
    content="${content//\{\{report_max_chars\}\}/${AAU_NOTIFICATION_REPORT_MAX_CHARS:-200}}"
    content="${content//\{\{report_style\}\}/${AAU_NOTIFICATION_REPORT_STYLE:-short}}"

    # Team member list
    local member_list=""
    for m in $(aau_team_members); do
        local role
        role=$(aau_member_attr "$m" "role")
        member_list="${member_list}- ${m}: ${role}\n"
    done
    content="${content//\{\{members_list\}\}/$member_list}"

    # Custom key=value substitutions
    for pair in "$@"; do
        local key="${pair%%=*}"
        local val="${pair#*=}"
        content="${content//\{\{$key\}\}/$val}"
    done

    echo "$content"
}

# ─── Log rotation ────────────────────────────────────────────────────────

aau_rotate_logs() {
    local max_bytes="${1:-10485760}"  # 10MB default
    for f in "${AAU_TMP}/${AAU_PREFIX}_"*.log "${AAU_TMP}/${AAU_PREFIX}_"*.jsonl; do
        [[ -f "$f" ]] || continue
        local size
        if [[ "$AAU_PLATFORM" == "Darwin" ]]; then
            size=$(stat -f %z "$f" 2>/dev/null || echo 0)
        else
            size=$(stat -c %s "$f" 2>/dev/null || echo 0)
        fi
        if [[ "$size" -gt "$max_bytes" ]]; then
            # Keep last 1000 lines, archive rest
            tail -1000 "$f" > "${f}.tmp"
            mv "${f}.tmp" "$f"
            aau_log "rotated $f (was ${size} bytes)"
        fi
    done
}
