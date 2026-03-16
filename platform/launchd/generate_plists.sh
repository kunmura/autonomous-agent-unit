#!/bin/bash
# generate_plists.sh — Generate launchd plist files from aau.yaml
# Usage: generate_plists.sh [output_dir]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAU_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$AAU_ROOT/lib/config.sh"
aau_load_config

OUTPUT_DIR="${1:-$HOME/Library/LaunchAgents}"
PROJECT="${AAU_PROJECT_NAME:-project}"
PREFIX="ai.${PROJECT}"
REPO="$AAU_PROJECT_ROOT"

echo "Generating launchd plists for '$PROJECT' in $OUTPUT_DIR"

generate_plist() {
    local label="$1" script="$2" interval="$3" args="${4:-}"
    local plist_file="$OUTPUT_DIR/${label}.plist"

    # Use python3 for .py scripts, bash for .sh
    local program_args
    if [[ "$script" == *.py ]]; then
        program_args="<string>/opt/homebrew/bin/python3</string>
		<string>${script}</string>"
    else
        program_args="<string>/bin/bash</string>
		<string>${script}</string>"
    fi
    if [[ -n "$args" ]]; then
        program_args="$program_args
		<string>${args}</string>"
    fi

    cat > "$plist_file" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${label}</string>
	<key>ProgramArguments</key>
	<array>
		${program_args}
	</array>
	<key>StartInterval</key>
	<integer>${interval}</integer>
	<key>RunAtLoad</key>
	<false/>
	<key>StandardOutPath</key>
	<string>/tmp/${label##ai.}.log</string>
	<key>StandardErrorPath</key>
	<string>/tmp/${label##ai.}_err.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
		<key>HOME</key>
		<string>${HOME}</string>
	</dict>
	<key>WorkingDirectory</key>
	<string>${REPO}</string>
</dict>
</plist>
PLIST
    echo "  Created: $plist_file"
}

# Task monitor
TASK_INTERVAL="${AAU_SCHEDULING_TASK_MONITOR_INTERVAL:-300}"
generate_plist "${PREFIX}.task-monitor" "$AAU_ROOT/lib/task_monitor.sh" "$TASK_INTERVAL"

# Health monitor
HEALTH_INTERVAL="${AAU_SCHEDULING_HEALTH_MONITOR_INTERVAL:-600}"
generate_plist "${PREFIX}.health-monitor" "$AAU_ROOT/lib/health_monitor.py" "$HEALTH_INTERVAL"

# Director autonomous
DIR_INTERVAL="${AAU_DIRECTOR_AUTONOMOUS_INTERVAL:-1800}"
generate_plist "${PREFIX}.director-autonomous" "$AAU_ROOT/lib/director_autonomous.sh" "$DIR_INTERVAL"

# Director responder
RESP_INTERVAL="${AAU_DIRECTOR_RESPONDER_INTERVAL:-120}"
generate_plist "${PREFIX}.director-responder" "$AAU_ROOT/lib/director_responder.sh" "$RESP_INTERVAL"

# Slack monitor (if notification plugin is slack)
NOTIFY_PLUGIN="${AAU_NOTIFICATION_PLUGIN:-none}"
if [[ "$NOTIFY_PLUGIN" == "slack" ]]; then
    generate_plist "${PREFIX}.slack-monitor" "$AAU_ROOT/lib/slack_monitor.py" "60" "$REPO"
fi

# Agent runners (one per member)
for MEMBER in $(aau_team_members); do
    MEMBER_INTERVAL=$(aau_member_attr "$MEMBER" "interval")
    MEMBER_INTERVAL="${MEMBER_INTERVAL:-300}"
    generate_plist "${PREFIX}.agent-${MEMBER}" "$AAU_ROOT/lib/agent_runner.sh" "$MEMBER_INTERVAL" "$MEMBER"
done

echo ""
echo "Done! Generated $(ls "$OUTPUT_DIR/${PREFIX}."* 2>/dev/null | wc -l | xargs) plist files."
echo "Run: bash $SCRIPT_DIR/install.sh to activate."
