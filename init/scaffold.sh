#!/bin/bash
# scaffold.sh — Create team/ directory structure in target project
# Usage: scaffold.sh [/path/to/project]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAU_ROOT="$(dirname "$SCRIPT_DIR")"
source "$AAU_ROOT/lib/config.sh"

TARGET="${1:-$PWD}"

if [[ ! -f "$TARGET/aau.yaml" ]]; then
    echo "ERROR: aau.yaml not found in $TARGET"
    echo "Run setup.sh first or copy aau.yaml.example to $TARGET/aau.yaml"
    exit 1
fi

aau_load_config "$TARGET/aau.yaml"

echo "Creating team structure in $TARGET/team/"

# Director directory
mkdir -p "$TARGET/team/director"
cat > "$TARGET/team/director/inbox.md" << 'INBOX'
# Director Inbox

<!-- Incoming messages and health alerts appear here. -->
<!-- Status: UNREAD | PROCESSING | READ | ABORTED -->
INBOX

cat > "$TARGET/team/director/status.md" << 'STATUS'
# Project Status — Director Dashboard

## Current Phase
- (Update with project phases)

## Team Status
| Member | Current Task | Status |
|--------|-------------|--------|

## Recent Decisions
STATUS

cat > "$TARGET/team/director/promised.md" << 'PROMISED'
# Promised Actions

<!-- Director's commitments tracked here. -->
<!-- Status: [PENDING] | [DONE] -->
PROMISED

# Member directories
for MEMBER in $(aau_team_members); do
    ROLE=$(aau_member_attr "$MEMBER" "role")
    mkdir -p "$TARGET/team/$MEMBER"

    cat > "$TARGET/team/$MEMBER/tasks.md" << TASKS
# ${MEMBER^} — Task Queue

<!-- Director writes tasks here. ${MEMBER^} reads and executes. -->
<!-- Status: PENDING | IN_PROGRESS | DONE | CANCELLED -->

## Active Tasks

TASKS

    cat > "$TARGET/team/$MEMBER/progress.md" << PROGRESS
# ${MEMBER^} — Progress Log

<!-- ${MEMBER^} writes progress here. Director reads. -->
PROGRESS

    echo "  Created team/$MEMBER/ (role: $ROLE)"
done

# Team README
cat > "$TARGET/team/README.md" << 'README'
# Team Communication Protocol

## File-Based IPC

Each team member has:
- `tasks.md` — Task queue (Director writes, member reads)
- `progress.md` — Progress log (member writes, Director reads)

## Task Status Flow
```
PENDING → IN_PROGRESS → DONE
                      → CANCELLED
```

## Director has additionally:
- `inbox.md` — Incoming messages and health alerts
- `status.md` — Project dashboard
- `promised.md` — Tracked commitments
README

# Project launcher script
if [[ ! -f "$TARGET/aau" ]]; then
    cat > "$TARGET/aau" << 'LAUNCHER'
#!/bin/bash
# AAU — Launch monitoring & settings server for this project
AAU_ROOT="$HOME/git/autonomous-agent-unit"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${1:-7700}"
if [[ ! -d "$AAU_ROOT/web" ]]; then
    echo "ERROR: AAU not found at $AAU_ROOT"; exit 1
fi
echo "AAU Monitor: http://localhost:$PORT/monitor"
echo "Project:     $PROJECT_DIR"
exec python3 "$AAU_ROOT/web/server.py" "$PROJECT_DIR"
LAUNCHER
    chmod +x "$TARGET/aau"
    echo "  Created aau launcher"
fi

echo ""
echo "Team structure created successfully!"
echo "Members: $(aau_team_members)"
