#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_VERIFY_SCRIPT="$SCRIPT_DIR/../hooks/scripts/team-task-verify.sh"
IDLE_CHECK_SCRIPT="$SCRIPT_DIR/../hooks/scripts/team-idle-check.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
# Resolve symlinks for consistency with hook scripts (macOS /var -> /private/var)
TEST_DIR=$(cd "$TEST_DIR" && pwd -P)
ANALYTICS_DIR="$TEST_DIR/.claude/harness/analytics"

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $name"
        ((PASS++)) || true
    else
        echo "  FAIL: $name (expected '$expected', got '$actual')"
        ((FAIL++)) || true
    fi
}

# Setup: init a git repo in test dir
cd "$TEST_DIR"
git init -q
git commit --allow-empty -m "initial" -q
TEST_BRANCH=$(git rev-parse --abbrev-ref HEAD)

trap 'rm -rf "$TEST_DIR"' EXIT

echo "=== Team Hook Tests ==="

# ---------- Test 1: team-task-verify.sh emits team.task_completed with scope "team" ----------

echo ""
echo "Test 1: team-task-verify.sh emits team.task_completed with scope team"
rm -rf "$ANALYTICS_DIR"
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/task-completed.json" | bash "$TASK_VERIFY_SCRIPT" > /dev/null 2>&1
EXIT_CODE=$?
EVENTS_FILE="$ANALYTICS_DIR/events.jsonl"

assert_eq "exit code is 0" "0" "$EXIT_CODE"

if [ -f "$EVENTS_FILE" ] && grep -q '"team.task_completed"' "$EVENTS_FILE"; then
    echo "  PASS: team.task_completed event emitted"
    ((PASS++)) || true
    SCOPE=$(jq -r 'select(.event=="team.task_completed") | .scope' "$EVENTS_FILE" | tail -1)
    assert_eq "scope is team" "team" "$SCOPE"
else
    echo "  FAIL: team.task_completed event not found in events.jsonl"
    ((FAIL++)) || true
    echo "  SKIP: scope check"
    ((FAIL++)) || true
fi

# ---------- Test 2: Event contains task_id and advisory_signals ----------

echo ""
echo "Test 2: team.task_completed event contains task_id and advisory_signals"
if [ -f "$EVENTS_FILE" ]; then
    EVENT_LINE=$(grep '"team.task_completed"' "$EVENTS_FILE" | tail -1)
    TASK_ID=$(echo "$EVENT_LINE" | jq -r '.task_id' 2>/dev/null)
    assert_eq "task_id is 5" "5" "$TASK_ID"

    HAS_SIGNALS=$(echo "$EVENT_LINE" | jq -e '.advisory_signals' > /dev/null 2>&1 && echo "true" || echo "false")
    assert_eq "advisory_signals present" "true" "$HAS_SIGNALS"

    HAS_BLOCKED=$(echo "$EVENT_LINE" | jq -e '.advisory_signals.recent_blocked_violations' > /dev/null 2>&1 && echo "true" || echo "false")
    assert_eq "advisory_signals.recent_blocked_violations present" "true" "$HAS_BLOCKED"

    HAS_WARN=$(echo "$EVENT_LINE" | jq -e '.advisory_signals.recent_warn_violations' > /dev/null 2>&1 && echo "true" || echo "false")
    assert_eq "advisory_signals.recent_warn_violations present" "true" "$HAS_WARN"

    HAS_LOOPS=$(echo "$EVENT_LINE" | jq -e '.advisory_signals.recent_loops_on_branch' > /dev/null 2>&1 && echo "true" || echo "false")
    assert_eq "advisory_signals.recent_loops_on_branch present" "true" "$HAS_LOOPS"
else
    echo "  FAIL: events.jsonl not found"
    ((FAIL++)) || true
    for i in $(seq 1 4); do echo "  SKIP"; ((FAIL++)) || true; done
fi

# ---------- Test 3: team-idle-check.sh emits team.agent_idle with scope "team" ----------

echo ""
echo "Test 3: team-idle-check.sh emits team.agent_idle with scope team"
rm -rf "$ANALYTICS_DIR"
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/teammate-idle.json" | bash "$IDLE_CHECK_SCRIPT" > /dev/null 2>&1
EXIT_CODE=$?
EVENTS_FILE="$ANALYTICS_DIR/events.jsonl"

assert_eq "exit code is 0" "0" "$EXIT_CODE"

if [ -f "$EVENTS_FILE" ] && grep -q '"team.agent_idle"' "$EVENTS_FILE"; then
    echo "  PASS: team.agent_idle event emitted"
    ((PASS++)) || true
    SCOPE=$(jq -r 'select(.event=="team.agent_idle") | .scope' "$EVENTS_FILE" | tail -1)
    assert_eq "scope is team" "team" "$SCOPE"
else
    echo "  FAIL: team.agent_idle event not found in events.jsonl"
    ((FAIL++)) || true
    echo "  SKIP: scope check"
    ((FAIL++)) || true
fi

# ---------- Test 4: team.agent_idle has standard envelope fields ----------

echo ""
echo "Test 4: team.agent_idle has standard envelope fields"
if [ -f "$EVENTS_FILE" ]; then
    EVENT_LINE=$(grep '"team.agent_idle"' "$EVENTS_FILE" | tail -1)
    for field in ts event session_id branch scope worktree repo_root; do
        has_field=$(echo "$EVENT_LINE" | jq -r "has(\"$field\")" 2>/dev/null || echo "false")
        if [ "$has_field" = "true" ]; then
            echo "  PASS: team.agent_idle has field '$field'"
            ((PASS++)) || true
        else
            echo "  FAIL: team.agent_idle missing field '$field'"
            ((FAIL++)) || true
        fi
    done
else
    echo "  FAIL: events.jsonl not found"
    for i in $(seq 1 7); do ((FAIL++)) || true; done
fi

# ---------- Test 5: task_id defaults to "unknown" when missing ----------

echo ""
echo "Test 5: task_id defaults to unknown when missing from input"
rm -rf "$ANALYTICS_DIR"
# Send input without task_id
jq --arg cwd "$TEST_DIR" '{session_id: .session_id, cwd: $cwd, hook_event_name: "TaskCompleted"}' "$FIXTURES/task-completed.json" | bash "$TASK_VERIFY_SCRIPT" > /dev/null 2>&1
EVENTS_FILE="$ANALYTICS_DIR/events.jsonl"
if [ -f "$EVENTS_FILE" ]; then
    TASK_ID=$(jq -r 'select(.event=="team.task_completed") | .task_id' "$EVENTS_FILE" | tail -1)
    assert_eq "task_id defaults to unknown" "unknown" "$TASK_ID"
else
    echo "  FAIL: events.jsonl not found"
    ((FAIL++)) || true
fi

# ---------- Test 6: advisory_signals counts are 0 with no prior events ----------

echo ""
echo "Test 6: advisory_signals counts are 0 with no prior events"
rm -rf "$ANALYTICS_DIR"
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/task-completed.json" | bash "$TASK_VERIFY_SCRIPT" > /dev/null 2>&1
EVENTS_FILE="$ANALYTICS_DIR/events.jsonl"
if [ -f "$EVENTS_FILE" ]; then
    EVENT_LINE=$(grep '"team.task_completed"' "$EVENTS_FILE" | tail -1)
    BLOCKED=$(echo "$EVENT_LINE" | jq -r '.advisory_signals.recent_blocked_violations' 2>/dev/null)
    WARN=$(echo "$EVENT_LINE" | jq -r '.advisory_signals.recent_warn_violations' 2>/dev/null)
    LOOPS=$(echo "$EVENT_LINE" | jq -r '.advisory_signals.recent_loops_on_branch' 2>/dev/null)
    assert_eq "recent_blocked_violations is 0" "0" "$BLOCKED"
    assert_eq "recent_warn_violations is 0" "0" "$WARN"
    assert_eq "recent_loops_on_branch is 0" "0" "$LOOPS"
else
    echo "  FAIL: events.jsonl not found"
    ((FAIL++)) || true
fi

# Cleanup handled by trap
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
