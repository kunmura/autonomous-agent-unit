#!/bin/bash
# Generic webhook notification plugin
# Requires WEBHOOK_URL in .env

aau_plugin_notify() {
    local message="$1"
    if [[ -z "$WEBHOOK_URL" ]]; then
        aau_log "WARN: WEBHOOK_URL not set"
        return 1
    fi
    curl -s -X POST "$WEBHOOK_URL" \
      -H 'Content-Type: application/json' \
      -d "{\"text\":\"$message\"}" > /dev/null
}
