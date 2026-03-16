#!/bin/bash
# test_config_loader.sh — Test aau.yaml config loading
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAU_ROOT="$(dirname "$SCRIPT_DIR")"
PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected='$expected', actual='$actual')"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_empty() {
    local desc="$1" actual="$2"
    if [[ -n "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (empty)"
        FAIL=$((FAIL + 1))
    fi
}

# ─── Setup test fixture ─────────────────────────────────────────────────
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

cat > "$TEST_DIR/aau.yaml" << 'YAML'
project:
  name: "test-project"
runtime:
  claude_cli: "/usr/bin/claude"
  claude_model: "claude-sonnet-4-6"
  permission_mode: "bypassPermissions"
  tmp_dir: "/tmp"
  prefix: "testproj"
team:
  members:
    - name: backend
      role: "API development"
      timeout: 300
      max_turns: 20
      interval: 180
    - name: frontend
      role: "UI development"
      timeout: 600
      max_turns: 30
      interval: 300
director:
  autonomous_interval: 1800
  quiet_hours_start: 0
  quiet_hours_end: 8
  daily_max_invocations: 10
notification:
  plugin: "none"
YAML

# ─── Test config loading ────────────────────────────────────────────────
echo "=== Test: Config Loading ==="

source "$AAU_ROOT/lib/config.sh"
aau_load_config "$TEST_DIR/aau.yaml"

assert_eq "project name" "test-project" "$AAU_PROJECT_NAME"
assert_eq "prefix" "testproj" "$AAU_PREFIX"
assert_eq "claude cli" "/usr/bin/claude" "$AAU_CLAUDE"
assert_eq "model" "claude-sonnet-4-6" "$AAU_MODEL"
assert_eq "tmp dir" "/tmp" "$AAU_TMP"
assert_eq "member count" "2" "$AAU_TEAM_MEMBERS_COUNT"

# ─── Test team member functions ──────────────────────────────────────────
echo ""
echo "=== Test: Team Members ==="

MEMBERS=$(aau_team_members)
assert_eq "member list" "backend frontend" "$MEMBERS"

ROLE=$(aau_member_attr "backend" "role")
assert_eq "backend role" "API development" "$ROLE"

TIMEOUT=$(aau_member_attr "frontend" "timeout")
assert_eq "frontend timeout" "600" "$TIMEOUT"

INTERVAL=$(aau_member_attr "backend" "interval")
assert_eq "backend interval" "180" "$INTERVAL"

# ─── Test common functions ───────────────────────────────────────────────
echo ""
echo "=== Test: Common Functions ==="

source "$AAU_ROOT/lib/common.sh"

# Test md5
HASH=$(echo "test" | aau_md5)
assert_not_empty "md5 produces output" "$HASH"

# Test file_mtime
touch "$TEST_DIR/testfile"
MTIME=$(aau_file_mtime "$TEST_DIR/testfile")
assert_not_empty "file_mtime returns value" "$MTIME"

# Test logging
aau_init_logging "test_component"
aau_log "test message"
assert_eq "log file exists" "true" "$(test -f $_AAU_LOG_FILE && echo true || echo false)"

aau_jlog "info" "test_event"
assert_eq "jsonl file exists" "true" "$(test -f $_AAU_JSONL_FILE && echo true || echo false)"

# ─── Results ─────────────────────────────────────────────────────────────
echo ""
echo "============================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
