#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/scripts/checkpoint.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0

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

assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $name"
        ((PASS++)) || true
    else
        echo "  FAIL: $name (expected to contain '$needle')"
        ((FAIL++)) || true
    fi
}

assert_file_exists() {
    local name="$1" path="$2"
    if [ -f "$path" ]; then
        echo "  PASS: $name"
        ((PASS++)) || true
    else
        echo "  FAIL: $name (file not found: $path)"
        ((FAIL++)) || true
    fi
}

assert_file_not_exists() {
    local name="$1" path="$2"
    if [ ! -f "$path" ]; then
        echo "  PASS: $name"
        ((PASS++)) || true
    else
        echo "  FAIL: $name (file should not exist: $path)"
        ((FAIL++)) || true
    fi
}

# Helper: create a temp git repo with one commit and harness progress file
setup_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    tmpdir=$(cd "$tmpdir" && pwd -P)
    (
        cd "$tmpdir"
        git init -q
        echo "initial" > file.txt
        git add file.txt
        git commit -q -m "init"
        mkdir -p .claude/harness/progress
        echo "# Progress" > ".claude/harness/progress/$(git rev-parse --abbrev-ref HEAD)--test1234.md"
    )
    echo "$tmpdir"
}

# Helper: generate passing test input JSON
passing_test_input() {
    local cwd="$1"
    local cmd="${2:-npm test}"
    jq -n \
        --arg sid "test1234-abcd-efgh-ijkl" \
        --arg cwd "$cwd" \
        --arg cmd "$cmd" \
        '{
            session_id: $sid,
            cwd: $cwd,
            hook_event_name: "PostToolUse",
            tool_name: "Bash",
            tool_input: { command: $cmd },
            tool_result: "Tests: 5 passed, 5 total\nAll tests passed."
        }'
}

# Helper: generate failing test input JSON
failing_test_input() {
    local cwd="$1"
    jq -n \
        --arg sid "test1234-abcd-efgh-ijkl" \
        --arg cwd "$cwd" \
        '{
            session_id: $sid,
            cwd: $cwd,
            hook_event_name: "PostToolUse",
            tool_name: "Bash",
            tool_input: { command: "npm test" },
            tool_result: "FAIL src/handler.test.ts\n  TypeError: Cannot read property"
        }'
}

# Helper: generate non-test bash input JSON
non_test_input() {
    local cwd="$1"
    jq -n \
        --arg sid "test1234-abcd-efgh-ijkl" \
        --arg cwd "$cwd" \
        '{
            session_id: $sid,
            cwd: $cwd,
            hook_event_name: "PostToolUse",
            tool_name: "Bash",
            tool_input: { command: "ls -la" },
            tool_result: "total 32\ndrwxr-xr-x  5 user staff 160 Jan  1 00:00 ."
        }'
}

SESSION_PREFIX="test1234"
RATE_FILE="/tmp/harness-checkpoint-ts-${SESSION_PREFIX}"

echo "=== Checkpoint Tests ==="

# --- Test 1: No checkpoint when no changes ---
echo ""
echo "Test 1: No checkpoint when no changes"
TEST_DIR=$(setup_test_repo)
cleanup_test1() { rm -rf "$TEST_DIR"; rm -f "$RATE_FILE"; }
trap cleanup_test1 EXIT
rm -f "$RATE_FILE"

passing_test_input "$TEST_DIR" | bash "$HOOK_SCRIPT" 2>&1 || true

STASH_COUNT=$(git -C "$TEST_DIR" stash list 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no stash when no changes" "0" "$STASH_COUNT"
ANALYTICS="$TEST_DIR/.claude/harness/analytics/events.jsonl"
if [ -f "$ANALYTICS" ] && grep -q "checkpoint.created" "$ANALYTICS" 2>/dev/null; then
    echo "  FAIL: no analytics event expected"
    ((FAIL++)) || true
else
    echo "  PASS: no analytics event"
    ((PASS++)) || true
fi

rm -rf "$TEST_DIR"
trap - EXIT

# --- Test 2: Checkpoint created on passing test with changes ---
echo ""
echo "Test 2: Checkpoint created on passing test with changes"
TEST_DIR=$(setup_test_repo)
cleanup_test2() { rm -rf "$TEST_DIR"; rm -f "$RATE_FILE"; }
trap cleanup_test2 EXIT
rm -f "$RATE_FILE"

# Make an uncommitted change
echo "modified" >> "$TEST_DIR/file.txt"

passing_test_input "$TEST_DIR" | bash "$HOOK_SCRIPT" 2>&1 || true

STASH_LIST=$(git -C "$TEST_DIR" stash list 2>/dev/null)
STASH_COUNT=$(echo "$STASH_LIST" | grep -c "harness-checkpoint:" || true)
assert_eq "stash entry created" "1" "$STASH_COUNT"
assert_contains "stash message has prefix" "$STASH_LIST" "harness-checkpoint:"
assert_contains "stash message has tests passing" "$STASH_LIST" "tests passing"

# Verify working tree is unchanged (git stash create + store doesn't modify working tree)
WORKING_CONTENT=$(cat "$TEST_DIR/file.txt")
assert_contains "working tree unchanged" "$WORKING_CONTENT" "modified"

# Verify analytics event
ANALYTICS="$TEST_DIR/.claude/harness/analytics/events.jsonl"
assert_file_exists "analytics file created" "$ANALYTICS"
if [ -f "$ANALYTICS" ]; then
    EVENT=$(jq -r 'select(.event == "checkpoint.created") | .trigger' "$ANALYTICS" 2>/dev/null | head -1)
    assert_eq "checkpoint.created event emitted" "tests_passing" "$EVENT"
fi

rm -rf "$TEST_DIR"
rm -f "$RATE_FILE"
trap - EXIT

# --- Test 3: No checkpoint on failing test ---
echo ""
echo "Test 3: No checkpoint on failing test"
TEST_DIR=$(setup_test_repo)
cleanup_test3() { rm -rf "$TEST_DIR"; rm -f "$RATE_FILE"; }
trap cleanup_test3 EXIT
rm -f "$RATE_FILE"

echo "modified" >> "$TEST_DIR/file.txt"

failing_test_input "$TEST_DIR" | bash "$HOOK_SCRIPT" 2>&1 || true

STASH_COUNT=$(git -C "$TEST_DIR" stash list 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no stash on failing test" "0" "$STASH_COUNT"

rm -rf "$TEST_DIR"
rm -f "$RATE_FILE"
trap - EXIT

# --- Test 4: No checkpoint for non-test Bash commands ---
echo ""
echo "Test 4: No checkpoint for non-test commands"
TEST_DIR=$(setup_test_repo)
cleanup_test4() { rm -rf "$TEST_DIR"; rm -f "$RATE_FILE"; }
trap cleanup_test4 EXIT
rm -f "$RATE_FILE"

echo "modified" >> "$TEST_DIR/file.txt"

non_test_input "$TEST_DIR" | bash "$HOOK_SCRIPT" 2>&1 || true

STASH_COUNT=$(git -C "$TEST_DIR" stash list 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no stash for non-test command" "0" "$STASH_COUNT"

rm -rf "$TEST_DIR"
rm -f "$RATE_FILE"
trap - EXIT

# --- Test 5: Rate limiting — no checkpoint within 5 minutes ---
echo ""
echo "Test 5: Rate limiting prevents frequent checkpoints"
TEST_DIR=$(setup_test_repo)
cleanup_test5() { rm -rf "$TEST_DIR"; rm -f "$RATE_FILE"; }
trap cleanup_test5 EXIT
rm -f "$RATE_FILE"

echo "modified" >> "$TEST_DIR/file.txt"

# Write a recent timestamp to the rate file (current time)
date +%s > "$RATE_FILE"

passing_test_input "$TEST_DIR" | bash "$HOOK_SCRIPT" 2>&1 || true

STASH_COUNT=$(git -C "$TEST_DIR" stash list 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no stash due to rate limit" "0" "$STASH_COUNT"

rm -rf "$TEST_DIR"
rm -f "$RATE_FILE"
trap - EXIT

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
