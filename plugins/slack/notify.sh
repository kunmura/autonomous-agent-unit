#!/bin/bash
# Slack notification plugin
# Requires SLACK_TOKEN and SLACK_CHANNEL in .env
# Optional: pass agent name as second argument for [by Agent] prefix

aau_plugin_notify() {
    local message="$1"
    local agent_name="${2:-}"
    if [[ -z "$SLACK_TOKEN" || -z "$SLACK_CHANNEL" ]]; then
        aau_log "WARN: SLACK_TOKEN or SLACK_CHANNEL not set"
        return 1
    fi
    # Prepend agent name if provided
    local full_message="$message"
    if [[ -n "$agent_name" ]]; then
        full_message="[by ${agent_name}] ${message}"
    fi
    # Use python3 for safe JSON encoding of message
    local json_text
    json_text=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$full_message" 2>/dev/null)
    if [[ -z "$json_text" ]]; then
        json_text="\"${full_message//\"/\\\"}\""
    fi
    curl -s -X POST 'https://slack.com/api/chat.postMessage' \
      -H "Authorization: Bearer $SLACK_TOKEN" \
      -H 'Content-Type: application/json' \
      -d "{\"channel\":\"$SLACK_CHANNEL\",\"text\":${json_text}}" > /dev/null
}
