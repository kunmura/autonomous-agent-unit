#!/bin/bash
# setup.sh — Interactive setup wizard for Autonomous Agent Unit
# Usage: cd /path/to/your/project && /path/to/aau/setup.sh

set -e

AAU_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$PWD}"

echo "============================================="
echo "  Autonomous Agent Unit (AAU) — Setup"
echo "============================================="
echo ""

# ─── Project info ────────────────────────────────────────────────────────
DEFAULT_NAME=$(basename "$TARGET")
read -p "Project name [$DEFAULT_NAME]: " PROJECT_NAME
PROJECT_NAME="${PROJECT_NAME:-$DEFAULT_NAME}"

read -p "Project path [$TARGET]: " PROJECT_PATH
PROJECT_PATH="${PROJECT_PATH:-$TARGET}"

# ─── Claude config ───────────────────────────────────────────────────────
DEFAULT_CLAUDE="/opt/homebrew/bin/claude"
if ! command -v claude >/dev/null 2>&1; then
    DEFAULT_CLAUDE=$(which claude 2>/dev/null || echo "/opt/homebrew/bin/claude")
fi
read -p "Claude CLI path [$DEFAULT_CLAUDE]: " CLAUDE_CLI
CLAUDE_CLI="${CLAUDE_CLI:-$DEFAULT_CLAUDE}"

read -p "Claude model [claude-sonnet-4-6]: " CLAUDE_MODEL
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"

# ─── Team members ───────────────────────────────────────────────────────
read -p "Team members (comma-separated) [coder,qa]: " MEMBERS_INPUT
MEMBERS_INPUT="${MEMBERS_INPUT:-coder,qa}"
IFS=',' read -ra MEMBERS <<< "$MEMBERS_INPUT"

MEMBER_YAML=""
for m in "${MEMBERS[@]}"; do
    m=$(echo "$m" | xargs)  # trim
    read -p "  $m role: " ROLE
    ROLE="${ROLE:-General work}"
    MEMBER_YAML="$MEMBER_YAML
    - name: $m
      role: \"$ROLE\"
      timeout: 600
      max_turns: 30
      interval: 300"
done

# ─── Notification ────────────────────────────────────────────────────────
read -p "Notification plugin (slack/discord/webhook/none) [none]: " NOTIFY_PLUGIN
NOTIFY_PLUGIN="${NOTIFY_PLUGIN:-none}"

ENV_CONTENT=""
if [[ "$NOTIFY_PLUGIN" == "slack" ]]; then
    read -p "  Slack bot token (xoxb-...): " SLACK_TOKEN
    read -p "  Slack channel ID (C...): " SLACK_CHANNEL
    ENV_CONTENT="SLACK_TOKEN=$SLACK_TOKEN
SLACK_CHANNEL=$SLACK_CHANNEL"
elif [[ "$NOTIFY_PLUGIN" == "webhook" ]]; then
    read -p "  Webhook URL: " WEBHOOK_URL
    ENV_CONTENT="WEBHOOK_URL=$WEBHOOK_URL"
fi

# ─── Language ────────────────────────────────────────────────────────────
read -p "Prompt language (ja/en) [ja]: " LANG
LANG="${LANG:-ja}"

# ─── Local LLM ──────────────────────────────────────────────────────────
read -p "Enable local LLM (ollama)? (y/n) [n]: " USE_LLM
LLM_ENABLED="false"
if [[ "$USE_LLM" == "y" || "$USE_LLM" == "Y" ]]; then
    LLM_ENABLED="true"
fi

# ─── Quiet hours ─────────────────────────────────────────────────────────
read -p "Quiet hours (start-end, 24h) [0-8]: " QUIET
QUIET="${QUIET:-0-8}"
QUIET_START="${QUIET%-*}"
QUIET_END="${QUIET#*-}"

# ─── Prefix ──────────────────────────────────────────────────────────────
# Derive prefix from project name (lowercase, no spaces)
PREFIX=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' -' '_' | cut -c1-10)
read -p "File prefix for /tmp files [$PREFIX]: " PREFIX_INPUT
PREFIX="${PREFIX_INPUT:-$PREFIX}"

# ─── Generate aau.yaml ──────────────────────────────────────────────────
echo ""
echo "Creating aau.yaml..."

cat > "$TARGET/aau.yaml" << YAML
project:
  name: "$PROJECT_NAME"

runtime:
  claude_cli: "$CLAUDE_CLI"
  claude_model: "$CLAUDE_MODEL"
  permission_mode: "bypassPermissions"
  tmp_dir: "/tmp"
  prefix: "$PREFIX"

team:
  members:$MEMBER_YAML

director:
  autonomous_interval: 1800
  responder_interval: 120
  timeout: 600
  max_turns:
    report: 15
    followup: 20
    stale: 10
    idle: 25
    respond: 40
  report_interval: 7200
  stale_threshold: 1800
  daily_max_invocations: 20
  quiet_hours_start: $QUIET_START
  quiet_hours_end: $QUIET_END

scheduling:
  task_monitor_interval: 300
  health_monitor_interval: 600

locks:
  max_age: 1800

retry:
  max_retries: 3
  backoff_base: 300

notification:
  plugin: "$NOTIFY_PLUGIN"
  report_style: "short"
  report_max_chars: 50

local_llm:
  enabled: $LLM_ENABLED
  url: "http://localhost:11434/api/generate"
  classifier_model: "gemma2:9b"
  drafter_model: "qwen2.5-coder:32b"
  classifier_timeout: 30
  drafter_timeout: 300

prompts:
  language: "$LANG"

health:
  critical_patterns:
    - "Reached max turns"
    - "permission denied"
    - "Edit not allowed"
    - "Tool not allowed"
  warning_patterns:
    - "TESTS FAILED"
    - "assert failed"
    - "Error: "
    - "BLOCKED"
  stale_threshold: 1500
YAML

# ─── Generate .env ───────────────────────────────────────────────────────
if [[ -n "$ENV_CONTENT" ]]; then
    echo "Creating .env..."
    echo "$ENV_CONTENT" > "$TARGET/.env"

    # Add to .gitignore if not already there
    if [[ -f "$TARGET/.gitignore" ]]; then
        grep -q "^\.env$" "$TARGET/.gitignore" 2>/dev/null || echo ".env" >> "$TARGET/.gitignore"
    else
        echo ".env" > "$TARGET/.gitignore"
    fi
fi

# ─── Scaffold team directory ────────────────────────────────────────────
echo "Creating team/ directory structure..."
bash "$AAU_ROOT/init/scaffold.sh" "$TARGET"

# ─── Platform setup ─────────────────────────────────────────────────────
PLATFORM="$(uname -s)"
echo ""

if [[ "$PLATFORM" == "Darwin" ]]; then
    echo "Detected: macOS — generating launchd plists"
    bash "$AAU_ROOT/platform/launchd/generate_plists.sh"
    echo ""
    read -p "Install launchd services now? (y/n) [y]: " INSTALL_NOW
    if [[ "$INSTALL_NOW" != "n" && "$INSTALL_NOW" != "N" ]]; then
        bash "$AAU_ROOT/platform/launchd/install.sh"
    fi
elif [[ "$PLATFORM" == "Linux" ]]; then
    echo "Detected: Linux — generating systemd units"
    bash "$AAU_ROOT/platform/systemd/generate_units.sh"
    echo ""
    read -p "Install systemd timers now? (y/n) [y]: " INSTALL_NOW
    if [[ "$INSTALL_NOW" != "n" && "$INSTALL_NOW" != "N" ]]; then
        bash "$AAU_ROOT/platform/systemd/install.sh"
    fi
else
    echo "WARNING: Unsupported platform '$PLATFORM'. Manual scheduler setup required."
fi

# ─── Make scripts executable ────────────────────────────────────────────
chmod +x "$AAU_ROOT/lib/"*.sh "$AAU_ROOT/init/"*.sh "$AAU_ROOT/platform/"*/*.sh 2>/dev/null

# ─── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "============================================="
echo "  Setup Complete!"
echo "============================================="
echo ""
echo "  Project:   $PROJECT_NAME"
echo "  Config:    $TARGET/aau.yaml"
echo "  Team:      ${MEMBERS[*]}"
echo "  Notify:    $NOTIFY_PLUGIN"
echo "  Language:  $LANG"
echo "  Prefix:    $PREFIX"
echo ""
echo "  Services:"
echo "    - task-monitor       (every 5 min)"
echo "    - health-monitor     (every 10 min)"
echo "    - director-autonomous (every 30 min)"
echo "    - director-responder (every 2 min)"
for m in "${MEMBERS[@]}"; do
    echo "    - agent-$(echo $m | xargs)         (every 5 min)"
done
echo ""
echo "  Next steps:"
echo "    1. Review and customize aau.yaml"
echo "    2. Create .claude/agents/*.md for each member (optional)"
echo "    3. Add initial tasks to team/*/tasks.md"
echo "    4. The system will start working automatically"
echo ""
