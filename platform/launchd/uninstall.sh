#!/bin/bash
# uninstall.sh — Unload and remove all plists

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAU_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$AAU_ROOT/lib/config.sh"
aau_load_config

PROJECT="${AAU_PROJECT_NAME:-project}"
PREFIX="ai.${PROJECT}"
AGENTS_DIR="${HOME}/Library/LaunchAgents"

echo "Unloading launchd services for '$PROJECT'..."

for plist in "$AGENTS_DIR/${PREFIX}."*.plist; do
    [[ -f "$plist" ]] || continue
    label=$(basename "$plist" .plist)
    launchctl unload "$plist" 2>/dev/null
    rm -f "$plist"
    echo "  Removed: $label"
done

echo "Done."
