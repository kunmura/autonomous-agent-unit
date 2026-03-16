#!/bin/bash
# install.sh — Load all generated plists into launchd

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAU_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$AAU_ROOT/lib/config.sh"
aau_load_config

PROJECT="${AAU_PROJECT_NAME:-project}"
PREFIX="ai.${PROJECT}"
AGENTS_DIR="${HOME}/Library/LaunchAgents"

echo "Loading launchd services for '$PROJECT'..."

for plist in "$AGENTS_DIR/${PREFIX}."*.plist; do
    [[ -f "$plist" ]] || continue
    label=$(basename "$plist" .plist)

    # Unload first if already loaded
    launchctl list "$label" >/dev/null 2>&1 && launchctl unload "$plist" 2>/dev/null

    launchctl load "$plist"
    echo "  Loaded: $label"
done

echo ""
echo "Verify with: launchctl list | grep $PREFIX"
