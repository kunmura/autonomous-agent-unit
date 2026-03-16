#!/bin/bash
# generate_units.sh — Generate systemd user service + timer files from aau.yaml
# Usage: generate_units.sh [output_dir]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAU_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$AAU_ROOT/lib/config.sh"
aau_load_config

OUTPUT_DIR="${1:-$HOME/.config/systemd/user}"
mkdir -p "$OUTPUT_DIR"

PROJECT="${AAU_PROJECT_NAME:-project}"
PREFIX="aau-${PROJECT}"
REPO="$AAU_PROJECT_ROOT"

echo "Generating systemd units for '$PROJECT' in $OUTPUT_DIR"

generate_unit() {
    local name="$1" script="$2" interval_sec="$3" args="${4:-}"

    local exec_start
    if [[ "$script" == *.py ]]; then
        exec_start="/usr/bin/python3 $script"
    else
        exec_start="/bin/bash $script"
    fi
    [[ -n "$args" ]] && exec_start="$exec_start $args"

    # Service file
    cat > "$OUTPUT_DIR/${name}.service" << SERVICE
[Unit]
Description=AAU ${name} for ${PROJECT}

[Service]
Type=oneshot
ExecStart=${exec_start}
WorkingDirectory=${REPO}
Environment=HOME=${HOME}
Environment=PATH=/usr/local/bin:/usr/bin:/bin
SERVICE

    # Timer file
    cat > "$OUTPUT_DIR/${name}.timer" << TIMER
[Unit]
Description=AAU ${name} timer for ${PROJECT}

[Timer]
OnBootSec=60
OnUnitActiveSec=${interval_sec}s
Persistent=true

[Install]
WantedBy=timers.target
TIMER

    echo "  Created: ${name}.service + ${name}.timer"
}

# Generate units
TASK_INT="${AAU_SCHEDULING_TASK_MONITOR_INTERVAL:-300}"
generate_unit "${PREFIX}-task-monitor" "$AAU_ROOT/lib/task_monitor.sh" "$TASK_INT"

HEALTH_INT="${AAU_SCHEDULING_HEALTH_MONITOR_INTERVAL:-600}"
generate_unit "${PREFIX}-health-monitor" "$AAU_ROOT/lib/health_monitor.py" "$HEALTH_INT"

DIR_INT="${AAU_DIRECTOR_AUTONOMOUS_INTERVAL:-1800}"
generate_unit "${PREFIX}-director-autonomous" "$AAU_ROOT/lib/director_autonomous.sh" "$DIR_INT"

RESP_INT="${AAU_DIRECTOR_RESPONDER_INTERVAL:-120}"
generate_unit "${PREFIX}-director-responder" "$AAU_ROOT/lib/director_responder.sh" "$RESP_INT"

# Slack monitor (if notification plugin is slack)
NOTIFY_PLUGIN="${AAU_NOTIFICATION_PLUGIN:-none}"
if [[ "$NOTIFY_PLUGIN" == "slack" ]]; then
    generate_unit "${PREFIX}-slack-monitor" "$AAU_ROOT/lib/slack_monitor.py" "60" "$REPO"
fi

for MEMBER in $(aau_team_members); do
    M_INT=$(aau_member_attr "$MEMBER" "interval")
    M_INT="${M_INT:-300}"
    generate_unit "${PREFIX}-agent-${MEMBER}" "$AAU_ROOT/lib/agent_runner.sh" "$M_INT" "$MEMBER"
done

echo ""
echo "Done! Run: bash $SCRIPT_DIR/install.sh to activate."
