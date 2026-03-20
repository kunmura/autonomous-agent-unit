#!/bin/bash
# build_check.sh — Post-session build verification gate
# Runs after coder session to verify the project still builds.
# Usage: build_check.sh [member_name]
# Returns: 0 if build passes, 1 if build fails

MEMBER="${1:-coder}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Detect project type and run appropriate build command
cd "$AAU_PROJECT_ROOT"

BUILD_CMD=""
BUILD_RESULT=0

if [[ -f "package.json" ]]; then
    # Node.js project
    if grep -q '"build"' package.json 2>/dev/null; then
        BUILD_CMD="npm run build"
    fi
elif [[ -f "Cargo.toml" ]]; then
    BUILD_CMD="cargo check"
elif [[ -f "go.mod" ]]; then
    BUILD_CMD="go build ./..."
elif [[ -f "pyproject.toml" ]] || [[ -f "setup.py" ]]; then
    BUILD_CMD="python3 -m py_compile *.py"
fi

if [[ -z "$BUILD_CMD" ]]; then
    aau_log "build_check: no build command detected, skip"
    exit 0
fi

aau_log "build_check: running '$BUILD_CMD'"
BUILD_OUTPUT=$(eval "$BUILD_CMD" 2>&1)
BUILD_RESULT=$?

if [[ "$BUILD_RESULT" -ne 0 ]]; then
    aau_log "BUILD FAILED (exit=$BUILD_RESULT)"
    aau_jlog "error" "build_failed" "\"member\":\"$MEMBER\",\"exit\":$BUILD_RESULT"

    # Write build failure to inbox for director attention
    INBOX="$AAU_PROJECT_ROOT/team/director/inbox.md"
    DT=$(date '+%Y-%m-%d %H:%M')
    TRUNCATED="${BUILD_OUTPUT:0:300}"
    cat >> "$INBOX" << EOF

## [$DT] 🔴 Build Failed: $MEMBER
**Issue**: \`$BUILD_CMD\` exited with code $BUILD_RESULT
**対応**: 内部対応のみ（Slackへの投稿不要）
\`\`\`
$TRUNCATED
\`\`\`
ステータス: UNREAD

EOF
    exit 1
else
    aau_log "build_check: PASSED"
    aau_jlog "info" "build_passed" "\"member\":\"$MEMBER\""
    exit 0
fi
