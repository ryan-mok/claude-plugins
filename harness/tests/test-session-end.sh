#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/scripts/progress-save.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
# Resolve symlinks for consistency with hook scripts (macOS /var -> /private/var)
TEST_DIR=$(cd "$TEST_DIR" && pwd -P)
PROGRESS_DIR="$TEST_DIR/.claude/harness/progress"
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

assert_event_field() {
    local name="$1" field="$2" expected="$3" events_file="$4"
    local actual
    actual=$(jq -r "select(.event==\"session.end\") | .$field" "$events_file" 2>/dev/null | tail -1)
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

trap 'rm -rf "$TEST_DIR" /tmp/harness-loop-state-test1234.jsonl' EXIT

echo "=== Session End Heuristic Tests ==="

# ---------- Test 1: session.end emitted with correct agent_outcome from progress file ----------

echo ""
echo "Test 1: session.end emitted with correct agent_outcome from progress file"
rm -rf "$PROGRESS_DIR" "$ANALYTICS_DIR"
mkdir -p "$PROGRESS_DIR"
cat > "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md" << 'EOF'
# Harness Progress

## Agent Outcome
success — all tasks completed

## Current Status
In progress
EOF
rm -f /tmp/harness-loop-state-test1234.jsonl
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
EVENTS_FILE="$ANALYTICS_DIR/events.jsonl"
if [ -f "$EVENTS_FILE" ] && jq -e 'select(.event=="session.end")' "$EVENTS_FILE" > /dev/null 2>&1; then
    echo "  PASS: session.end event emitted"
    ((PASS++)) || true
    assert_event_field "agent_outcome is success" "agent_outcome" "success" "$EVENTS_FILE"
else
    echo "  FAIL: session.end event not found in events.jsonl"
    ((FAIL++)) || true
    echo "  SKIP: agent_outcome check"
    ((FAIL++)) || true
fi

# ---------- Test 2: heuristic_outcome="failed" when loop state has failing test ----------

echo ""
echo "Test 2: heuristic_outcome=failed when loop state has failing test"
rm -rf "$PROGRESS_DIR" "$ANALYTICS_DIR"
mkdir -p "$PROGRESS_DIR"
cat > "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md" << 'EOF'
# Harness Progress

## Current Status
In progress
EOF
# Create loop state with a failing test entry
rm -f /tmp/harness-loop-state-test1234.jsonl
cat > /tmp/harness-loop-state-test1234.jsonl << 'EOF'
{"tool":"Bash","file":"npm test","error":"","ts":"2026-01-01T00:00:00Z"}
{"tool":"Bash","file":"npm test","error":"Error: 3 tests failed","ts":"2026-01-01T00:01:00Z"}
EOF
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
EVENTS_FILE="$ANALYTICS_DIR/events.jsonl"
assert_event_field "heuristic_outcome is failed" "heuristic_outcome" "failed" "$EVENTS_FILE"
assert_event_field "tests_passing is false" "tests_passing" "false" "$EVENTS_FILE"

# ---------- Test 3: agent_outcome defaults to "unknown" when section missing ----------

echo ""
echo "Test 3: agent_outcome defaults to unknown when section missing"
rm -rf "$PROGRESS_DIR" "$ANALYTICS_DIR"
mkdir -p "$PROGRESS_DIR"
cat > "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md" << 'EOF'
# Harness Progress

## Current Status
In progress

## Notes
Some notes here
EOF
rm -f /tmp/harness-loop-state-test1234.jsonl
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
EVENTS_FILE="$ANALYTICS_DIR/events.jsonl"
assert_event_field "agent_outcome defaults to unknown" "agent_outcome" "unknown" "$EVENTS_FILE"

# ---------- Test 4: heuristic_outcome="success" when progress_marked_complete=true and no issues ----------

echo ""
echo "Test 4: heuristic_outcome=success when progress_marked_complete and no issues"
rm -rf "$PROGRESS_DIR" "$ANALYTICS_DIR"
mkdir -p "$PROGRESS_DIR"
cat > "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md" << 'EOF'
# Harness Progress

## Current Status
Complete

## Agent Outcome
success
EOF
rm -f /tmp/harness-loop-state-test1234.jsonl
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
EVENTS_FILE="$ANALYTICS_DIR/events.jsonl"
assert_event_field "heuristic_outcome is success" "heuristic_outcome" "success" "$EVENTS_FILE"
assert_event_field "progress_marked_complete is true" "progress_marked_complete" "true" "$EVENTS_FILE"

# ---------- Test 5: tests_passing=null when no test runner in loop state ----------

echo ""
echo "Test 5: tests_passing=null when no test runner in loop state"
rm -rf "$PROGRESS_DIR" "$ANALYTICS_DIR"
mkdir -p "$PROGRESS_DIR"
cat > "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md" << 'EOF'
# Harness Progress

## Current Status
In progress
EOF
# Create loop state with no test-related commands
rm -f /tmp/harness-loop-state-test1234.jsonl
cat > /tmp/harness-loop-state-test1234.jsonl << 'EOF'
{"tool":"Edit","file":"src/main.ts","error":"","ts":"2026-01-01T00:00:00Z"}
{"tool":"Bash","file":"ls -la","error":"","ts":"2026-01-01T00:01:00Z"}
{"tool":"Write","file":"src/util.ts","error":"","ts":"2026-01-01T00:02:00Z"}
EOF
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
EVENTS_FILE="$ANALYTICS_DIR/events.jsonl"
assert_event_field "tests_passing is null" "tests_passing" "null" "$EVENTS_FILE"

# ---------- Test 6: heuristic_outcome=failed when constraint_violations_blocked > 0 ----------

echo ""
echo "Test 6: heuristic_outcome=failed when constraint violations blocked"
rm -rf "$PROGRESS_DIR" "$ANALYTICS_DIR"
mkdir -p "$PROGRESS_DIR" "$ANALYTICS_DIR"
cat > "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md" << 'EOF'
# Harness Progress

## Current Status
In progress
EOF
rm -f /tmp/harness-loop-state-test1234.jsonl
# Pre-seed events.jsonl with a blocked constraint violation for this session
jq -n -c --arg sid "test1234" '{event:"constraint.violation",session_id:$sid,decision:"deny",rule:"no-eval",severity:"block"}' > "$ANALYTICS_DIR/events.jsonl"
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
assert_event_field "heuristic_outcome is failed (blocked violation)" "heuristic_outcome" "failed" "$EVENTS_FILE"
assert_event_field "constraint_violations_blocked is 1" "constraint_violations_blocked" "1" "$EVENTS_FILE"

# ---------- Test 7: mode read from YAML frontmatter ----------

echo ""
echo "Test 7: mode read from YAML frontmatter"
rm -rf "$PROGRESS_DIR" "$ANALYTICS_DIR"
mkdir -p "$PROGRESS_DIR"
cat > "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md" << 'EOF'
---
mode: harness
status: in-progress
---
# Harness Progress

## Current Status
In progress
EOF
rm -f /tmp/harness-loop-state-test1234.jsonl
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
EVENTS_FILE="$ANALYTICS_DIR/events.jsonl"
assert_event_field "mode is harness" "mode" "harness" "$EVENTS_FILE"

# ---------- Test 8: semantic_blocks counted correctly ----------

echo ""
echo "Test 8: semantic_blocks counted from Semantic Constraint Notes"
rm -rf "$PROGRESS_DIR" "$ANALYTICS_DIR"
mkdir -p "$PROGRESS_DIR"
cat > "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md" << 'EOF'
# Harness Progress

## Semantic Constraint Notes
- [x] No direct DB calls from controllers
- [ ] API versioning maintained
- [x] Error boundaries in place

## Current Status
In progress
EOF
rm -f /tmp/harness-loop-state-test1234.jsonl
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
EVENTS_FILE="$ANALYTICS_DIR/events.jsonl"
assert_event_field "semantic_blocks is 3" "semantic_blocks" "3" "$EVENTS_FILE"

# ---------- Test 9: outcome_agreement when agent and heuristic match ----------

echo ""
echo "Test 9: outcome_agreement=true when agent and heuristic agree"
rm -rf "$PROGRESS_DIR" "$ANALYTICS_DIR"
mkdir -p "$PROGRESS_DIR"
cat > "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md" << 'EOF'
# Harness Progress

## Agent Outcome
partial — some tasks remain

## Current Status
In progress
EOF
rm -f /tmp/harness-loop-state-test1234.jsonl
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
EVENTS_FILE="$ANALYTICS_DIR/events.jsonl"
# No PR, no complete marker, no failures => heuristic is "partial", agent says "partial"
assert_event_field "outcome_agreement is true" "outcome_agreement" "true" "$EVENTS_FILE"

# ---------- Test 10: all session.end envelope fields present ----------

echo ""
echo "Test 10: session.end has all required fields"
rm -rf "$PROGRESS_DIR" "$ANALYTICS_DIR"
mkdir -p "$PROGRESS_DIR"
echo "# progress" > "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md"
rm -f /tmp/harness-loop-state-test1234.jsonl
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
EVENTS_FILE="$ANALYTICS_DIR/events.jsonl"
if [ -f "$EVENTS_FILE" ]; then
    END_EVENT=$(jq -c 'select(.event=="session.end")' "$EVENTS_FILE" 2>/dev/null | tail -1)
    for field in agent_outcome heuristic_outcome outcome_agreement mode pr_created pr_check_timeout progress_marked_complete tests_passing unresolved_loops loop_count total_violations constraint_violations_blocked compaction_count semantic_blocks duration_seconds team_context; do
        has_field=$(echo "$END_EVENT" | jq -r "has(\"$field\")" 2>/dev/null || echo "false")
        if [ "$has_field" = "true" ]; then
            echo "  PASS: session.end has field '$field'"
            ((PASS++)) || true
        else
            echo "  FAIL: session.end missing field '$field'"
            ((FAIL++)) || true
        fi
    done
else
    echo "  FAIL: no events.jsonl file found"
    for i in $(seq 1 16); do ((FAIL++)) || true; done
fi

# Cleanup handled by trap
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
