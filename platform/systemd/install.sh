#!/bin/bash
# install.sh — Enable and start all generated systemd timers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAU_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$AAU_ROOT/lib/config.sh"
aau_load_config

PROJECT="${AAU_PROJECT_NAME:-project}"
PREFIX="aau-${PROJECT}"
UNIT_DIR="${HOME}/.config/systemd/user"

systemctl --user daemon-reload

echo "Enabling systemd timers for '$PROJECT'..."

for timer in "$UNIT_DIR/${PREFIX}-"*.timer; do
    [[ -f "$timer" ]] || continue
    name=$(basename "$timer" .timer)
    systemctl --user enable "$name.timer"
    systemctl --user start "$name.timer"
    echo "  Started: $name"
done

echo ""
echo "Verify with: systemctl --user list-timers | grep $PREFIX"
