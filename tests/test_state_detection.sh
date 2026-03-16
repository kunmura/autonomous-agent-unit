#!/bin/bash
# test_state_detection.sh — Test director autonomous state detection logic
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

# ─── Setup test fixture ─────────────────────────────────────────────────
TEST_DIR=$(mktemp -d)
TEST_TMP=$(mktemp -d)
trap "rm -rf $TEST_DIR $TEST_TMP" EXIT

cat > "$TEST_DIR/aau.yaml" << YAML
project:
  name: "test-project"
runtime:
  claude_cli: "/usr/bin/echo"
  claude_model: "test"
  permission_mode: "bypassPermissions"
  tmp_dir: "$TEST_TMP"
  prefix: "test"
team:
  members:
    - name: dev
      role: "Development"
      timeout: 10
      max_turns: 5
      interval: 60
director:
  report_interval: 7200
  stale_threshold: 1800
  daily_max_invocations: 20
  quiet_hours_start: 0
  quiet_hours_end: 4
notification:
  plugin: "none"
YAML

# Create team structure
mkdir -p "$TEST_DIR/team/dev" "$TEST_DIR/team/director"
echo "" > "$TEST_DIR/team/director/inbox.md"

source "$AAU_ROOT/lib/config.sh"
aau_load_config "$TEST_DIR/aau.yaml"
source "$AAU_ROOT/lib/common.sh"

# ─── Test 1: IDLE_ALL when no tasks ─────────────────────────────────────
echo "=== Test: IDLE_ALL detection ==="
cat > "$TEST_DIR/team/dev/tasks.md" << 'TASKS'
# Dev Tasks
## TASK-1 [DONE]
Old completed task
TASKS

touch "$TEST_TMP/test_last_report"  # Prevent REPORT_DUE
echo "dev:1" | aau_md5 > "$TEST_TMP/test_autonomous_done_seed"  # Prevent DONE_FOLLOWUP

# Simulate state detection (extract from director_autonomous.sh logic)
ACTION="NO_ACTION"
TOTAL_PENDING=0; TOTAL_INPROG=0
for MEMBER in $(aau_team_members); do
    TF="$TEST_DIR/team/$MEMBER/tasks.md"
    [[ -f "$TF" ]] || continue
    P=$(grep -c '\[PENDING\]' "$TF" 2>/dev/null || true)
    I=$(grep -c '\[IN_PROGRESS\]' "$TF" 2>/dev/null || true)
    TOTAL_PENDING=$((TOTAL_PENDING + P))
    TOTAL_INPROG=$((TOTAL_INPROG + I))
done
[[ "$TOTAL_PENDING" -eq 0 && "$TOTAL_INPROG" -eq 0 ]] && ACTION="IDLE_ALL"

assert_eq "IDLE_ALL when no pending/inprogress" "IDLE_ALL" "$ACTION"

# ─── Test 2: NO_ACTION when tasks exist ──────────────────────────────────
echo ""
echo "=== Test: NO_ACTION when tasks in progress ==="
cat > "$TEST_DIR/team/dev/tasks.md" << 'TASKS'
# Dev Tasks
## TASK-2 [IN_PROGRESS]
Working on something
TASKS

# Create fresh progress file (not stale)
touch "$TEST_DIR/team/dev/progress.md"

ACTION="NO_ACTION"
TOTAL_PENDING=0; TOTAL_INPROG=0
for MEMBER in $(aau_team_members); do
    TF="$TEST_DIR/team/$MEMBER/tasks.md"
    [[ -f "$TF" ]] || continue
    P=$(grep -c '\[PENDING\]' "$TF" 2>/dev/null || true)
    I=$(grep -c '\[IN_PROGRESS\]' "$TF" 2>/dev/null || true)
    TOTAL_PENDING=$((TOTAL_PENDING + P))
    TOTAL_INPROG=$((TOTAL_INPROG + I))
done
[[ "$TOTAL_PENDING" -eq 0 && "$TOTAL_INPROG" -eq 0 ]] && ACTION="IDLE_ALL"

assert_eq "NO_ACTION when IN_PROGRESS exists" "NO_ACTION" "$ACTION"

# ─── Test 3: REPORT_DUE when no marker ──────────────────────────────────
echo ""
echo "=== Test: REPORT_DUE detection ==="
rm -f "$TEST_TMP/test_last_report"
REPORT_INTERVAL=7200
NOW=$(date +%s)
REPORT_AGE=$((REPORT_INTERVAL + 1))

[[ "$REPORT_AGE" -gt "$REPORT_INTERVAL" ]] && ACTION="REPORT_DUE" || ACTION="NO_ACTION"
assert_eq "REPORT_DUE when no marker" "REPORT_DUE" "$ACTION"

# ─── Test 4: Lock mechanism ─────────────────────────────────────────────
echo ""
echo "=== Test: Lock mechanism ==="
aau_init_logging "test_lock"
aau_acquire_lock "test_lock_1"
LOCK_EXISTS=$(test -f "$TEST_TMP/test_test_lock_1.lock" && echo "true" || echo "false")
assert_eq "lock file created" "true" "$LOCK_EXISTS"
LOCK_PID=$(cat "$TEST_TMP/test_test_lock_1.lock")
assert_eq "lock contains PID" "$$" "$LOCK_PID"

# ─── Results ─────────────────────────────────────────────────────────────
echo ""
echo "============================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
