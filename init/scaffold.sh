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

# Member directories + agent definitions
mkdir -p "$TARGET/.claude/agents"
echo "Creating .claude/agents/ definitions..."

for MEMBER in $(aau_team_members); do
    ROLE=$(aau_member_attr "$MEMBER" "role")
    TOOLS=$(aau_member_attr "$MEMBER" "tools")
    TIMEOUT=$(aau_member_attr "$MEMBER" "timeout")
    MAX_TURNS=$(aau_member_attr "$MEMBER" "max_turns")
    mkdir -p "$TARGET/team/$MEMBER"

    cat > "$TARGET/team/$MEMBER/tasks.md" << TASKS
# ${MEMBER^} — Task Queue

<!-- Director writes tasks here. ${MEMBER^} reads and executes. -->
<!-- Status: PENDING | IN_PROGRESS | DONE | BLOCKED | CANCELLED -->

## Active Tasks

TASKS

    cat > "$TARGET/team/$MEMBER/progress.md" << PROGRESS
# ${MEMBER^} — Progress Log

<!-- ${MEMBER^} writes progress here. Director reads. -->
PROGRESS

    # Create knowledge.md for learning accumulation
    cat > "$TARGET/team/$MEMBER/knowledge.md" << KNOWLEDGE
# ${MEMBER^} — Knowledge Base

<!-- Lessons learned, patterns, and accumulated knowledge. -->
KNOWLEDGE

    # Create INSTRUCTIONS.md for member-specific manual
    cat > "$TARGET/team/$MEMBER/INSTRUCTIONS.md" << INSTRUCTIONS
# ${MEMBER^} — Instructions

## Role
${ROLE:-General team member}

## Task Polling Protocol
1. Read team/${MEMBER}/tasks.md every session (never cache)
2. Find tasks with [PENDING] status
3. Before starting, check prerequisites:
   - If task has **Blocked by**: check that blocking task is [DONE]
   - If blocked, set status to [BLOCKED] and move to next task
4. Set status to [IN_PROGRESS] and begin work
5. On completion, set status to [DONE] and update progress.md
6. If draft.md exists, review and use as starting point, then delete

## Slack Posting Rules
- Always include agent name: [by ${MEMBER^}] before any message
- Never post without Director approval unless auto-reply

## Quality Standards
- All deliverables must include evidence/sources
- Update knowledge.md with lessons learned
INSTRUCTIONS

    # Create .claude/agents/<member>.md
    cat > "$TARGET/.claude/agents/${MEMBER}.md" << AGENTMD
---
name: ${MEMBER}
role: ${ROLE:-Team member}
tools: ${TOOLS:-Read,Write,Edit,Bash,Grep,Glob}
---

# ${MEMBER^} Agent

## Task Polling Protocol (Top Priority)
1. Read team/${MEMBER}/tasks.md every time (never use cached version)
2. Find tasks with [PENDING] status
3. For each PENDING task:
   - Check prerequisites / blocked-by conditions
   - If draft.md exists in team/${MEMBER}/, use it as starting point
   - Set status to [IN_PROGRESS]
   - Execute the task
   - On completion: set [DONE], update progress.md
   - Delete draft.md if used
4. If no PENDING tasks: continue [IN_PROGRESS] tasks
5. If nothing to do: check knowledge.md for learning tasks

## Blocked Task Handling
- If a task has "Blocked by: TASK-XXX", check if TASK-XXX is [DONE]
- If not done, set this task to [BLOCKED] and skip to next
- Never work on [BLOCKED] tasks

## Communication
- Write progress to team/${MEMBER}/progress.md
- For Slack messages, always prefix with: [by ${MEMBER^}]
- Report blockers immediately in progress.md
AGENTMD

    echo "  Created team/$MEMBER/ + .claude/agents/${MEMBER}.md (role: $ROLE)"
done

# Team README
cat > "$TARGET/team/README.md" << 'README'
# Team Communication Protocol

## File-Based IPC

Each team member has:
- `tasks.md` — Task queue (Director writes, member reads)
- `progress.md` — Progress log (member writes, Director reads)
- `knowledge.md` — Accumulated lessons and patterns
- `draft.md` — Local LLM pre-draft (optional, auto-deleted after use)
- `INSTRUCTIONS.md` — Member-specific manual and rules

## Task Status Flow
```
PENDING → IN_PROGRESS → DONE
        → BLOCKED      → PENDING (when unblocked)
                       → CANCELLED
        → NEEDS_EVIDENCE → DONE (after adding evidence)
```

## Promise Tracking
Director promises (detected in Slack) are tracked in `director/promised.md`:
```
[PENDING] → [IN_QUEUE] (auto-converted to task) → [DONE]
```

## Director has additionally:
- `inbox.md` — Incoming messages and health alerts
- `status.md` — Project dashboard
- `promised.md` — Tracked commitments (auto-monitored)
- `last_check.md` — Slack monitor state

## Agent Definitions
`.claude/agents/<member>.md` — Claude Code agent definitions for each member
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
