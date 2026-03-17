#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SH="$SCRIPT_DIR/../hooks/scripts/lib.sh"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
# Resolve symlinks for consistency with hook scripts (macOS /var -> /private/var)
TEST_DIR=$(cd "$TEST_DIR" && pwd -P)

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

assert_exit_code() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $name (exit $actual)"
        ((PASS++)) || true
    else
        echo "  FAIL: $name (expected exit $expected, got $actual)"
        ((FAIL++)) || true
    fi
}

assert_file_exists() {
    local name="$1" file="$2"
    if [ -f "$file" ]; then
        echo "  PASS: $name"
        ((PASS++)) || true
    else
        echo "  FAIL: $name ($file not found)"
        ((FAIL++)) || true
    fi
}

assert_contains() {
    local name="$1" file="$2" pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "  PASS: $name"
        ((PASS++)) || true
    else
        echo "  FAIL: $name (pattern '$pattern' not found in $file)"
        ((FAIL++)) || true
    fi
}

# Source lib.sh
source "$LIB_SH"

# Setup: init a git repo in test dir
cd "$TEST_DIR"
git init -q
git commit --allow-empty -m "initial" -q

trap 'rm -rf "$TEST_DIR"' EXIT

echo "=== Lib Analytics Helpers Tests ==="

# ---------- get_analytics_dir ----------

echo ""
echo "Test 1: get_analytics_dir returns correct path"
result=$(get_analytics_dir "$TEST_DIR")
assert_eq "analytics dir path" "$TEST_DIR/.claude/harness/analytics" "$result"

echo ""
echo "Test 2: get_analytics_dir defaults to CWD env var"
CWD="$TEST_DIR" result=$(get_analytics_dir)
assert_eq "analytics dir uses CWD default" "$TEST_DIR/.claude/harness/analytics" "$result"

# ---------- is_worktree ----------

echo ""
echo "Test 3: is_worktree returns false for normal repo"
is_worktree "$TEST_DIR" && rc=0 || rc=$?
assert_exit_code "normal repo is not worktree" "1" "$rc"

echo ""
echo "Test 4: is_worktree returns true for actual worktree"
# Create a worktree
WORKTREE_DIR="$TEST_DIR/wt-test"
git worktree add -q "$WORKTREE_DIR" -b wt-branch 2>/dev/null
is_worktree "$WORKTREE_DIR" && wt_rc=0 || wt_rc=$?
assert_exit_code "worktree detected" "0" "$wt_rc"
git worktree remove "$WORKTREE_DIR" 2>/dev/null || true

# ---------- emit_event ----------

echo ""
echo "Test 5: emit_event creates analytics dir and events.jsonl"
ANALYTICS_DIR="$TEST_DIR/.claude/harness/analytics"
rm -rf "$ANALYTICS_DIR"
CWD="$TEST_DIR" SESSION_PREFIX="abcd1234" BRANCH="main" emit_event "session.start"
assert_file_exists "events.jsonl created" "$ANALYTICS_DIR/events.jsonl"

echo ""
echo "Test 6: emit_event writes valid JSON with all envelope fields"
line=$(head -1 "$ANALYTICS_DIR/events.jsonl")
# Verify it parses as JSON and has required fields
for field in ts event session_id branch scope worktree repo_root; do
    has_field=$(echo "$line" | jq -r "has(\"$field\")" 2>/dev/null || echo "false")
    if [ "$has_field" = "true" ]; then
        echo "  PASS: event has field '$field'"
        ((PASS++)) || true
    else
        echo "  FAIL: event missing field '$field' (line: $line)"
        ((FAIL++)) || true
    fi
done

echo ""
echo "Test 7: emit_event envelope values are correct"
event_type=$(echo "$line" | jq -r '.event')
session_id=$(echo "$line" | jq -r '.session_id')
branch=$(echo "$line" | jq -r '.branch')
scope=$(echo "$line" | jq -r '.scope')
assert_eq "event type" "session.start" "$event_type"
assert_eq "session_id" "abcd1234" "$session_id"
assert_eq "branch" "main" "$branch"
assert_eq "default scope" "single" "$scope"

echo ""
echo "Test 8: emit_event appends (multiple events produce multiple lines)"
CWD="$TEST_DIR" SESSION_PREFIX="abcd1234" BRANCH="main" emit_event "task.complete"
line_count=$(wc -l < "$ANALYTICS_DIR/events.jsonl" | tr -d ' ')
assert_eq "two events = two lines" "2" "$line_count"

echo ""
echo "Test 9: emit_event uses scope parameter"
rm -f "$ANALYTICS_DIR/events.jsonl"
CWD="$TEST_DIR" SESSION_PREFIX="abcd1234" BRANCH="main" emit_event "session.start" "{}" "team"
scope=$(head -1 "$ANALYTICS_DIR/events.jsonl" | jq -r '.scope')
assert_eq "scope is team" "team" "$scope"

echo ""
echo "Test 10: emit_event merges extra_fields"
rm -f "$ANALYTICS_DIR/events.jsonl"
CWD="$TEST_DIR" SESSION_PREFIX="abcd1234" BRANCH="main" emit_event "task.complete" '{"task":"build","status":"pass"}'
task_val=$(head -1 "$ANALYTICS_DIR/events.jsonl" | jq -r '.task')
status_val=$(head -1 "$ANALYTICS_DIR/events.jsonl" | jq -r '.status')
assert_eq "extra field task" "build" "$task_val"
assert_eq "extra field status" "pass" "$status_val"

echo ""
echo "Test 11: emit_event worktree field is boolean false for normal repo"
rm -f "$ANALYTICS_DIR/events.jsonl"
CWD="$TEST_DIR" SESSION_PREFIX="abcd1234" BRANCH="main" emit_event "session.start"
wt_val=$(head -1 "$ANALYTICS_DIR/events.jsonl" | jq -r '.worktree')
assert_eq "worktree is false" "false" "$wt_val"

# Cleanup handled by trap
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
