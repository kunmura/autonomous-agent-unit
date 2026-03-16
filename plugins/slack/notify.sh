#!/bin/bash
# Slack notification plugin
# Requires SLACK_TOKEN and SLACK_CHANNEL in .env

aau_plugin_notify() {
    local message="$1"
    if [[ -z "$SLACK_TOKEN" || -z "$SLACK_CHANNEL" ]]; then
        aau_log "WARN: SLACK_TOKEN or SLACK_CHANNEL not set"
        return 1
    fi
    curl -s -X POST 'https://slack.com/api/chat.postMessage' \
      -H "Authorization: Bearer $SLACK_TOKEN" \
      -H 'Content-Type: application/json' \
      -d "{\"channel\":\"$SLACK_CHANNEL\",\"text\":\"$message\"}" > /dev/null
}
