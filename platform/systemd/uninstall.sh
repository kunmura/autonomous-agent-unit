#!/bin/bash
# uninstall.sh — Stop and remove all systemd units

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAU_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$AAU_ROOT/lib/config.sh"
aau_load_config

PROJECT="${AAU_PROJECT_NAME:-project}"
PREFIX="aau-${PROJECT}"
UNIT_DIR="${HOME}/.config/systemd/user"

echo "Removing systemd units for '$PROJECT'..."

for timer in "$UNIT_DIR/${PREFIX}-"*.timer; do
    [[ -f "$timer" ]] || continue
    name=$(basename "$timer" .timer)
    systemctl --user stop "$name.timer" 2>/dev/null
    systemctl --user disable "$name.timer" 2>/dev/null
    rm -f "$UNIT_DIR/$name.timer" "$UNIT_DIR/$name.service"
    echo "  Removed: $name"
done

systemctl --user daemon-reload
echo "Done."
