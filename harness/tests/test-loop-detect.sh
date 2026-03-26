#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/scripts/loop-detect.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0

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

assert_no_loop() {
    local name="$1" output="$2"
    if echo "$output" | grep -q "LOOP DETECTED"; then
        echo "  FAIL: $name (unexpected loop detected)"
        ((FAIL++)) || true
    else
        echo "  PASS: $name (no loop)"
        ((PASS++)) || true
    fi
}

assert_loop_detected() {
    local name="$1" output="$2"
    if echo "$output" | grep -q "LOOP DETECTED"; then
        echo "  PASS: $name (loop detected)"
        ((PASS++)) || true
    else
        echo "  FAIL: $name (expected loop detection)"
        ((FAIL++)) || true
    fi
}

assert_nudge() {
    local name="$1" output="$2"
    if echo "$output" | grep -q "Harness notice" && ! echo "$output" | grep -q "LOOP DETECTED"; then
        echo "  PASS: $name (nudge)"
        ((PASS++)) || true
    else
        echo "  FAIL: $name (expected nudge, not loop)"
        ((FAIL++)) || true
    fi
}

assert_escalated() {
    local name="$1" output="$2"
    if echo "$output" | grep -q "escalated"; then
        echo "  PASS: $name (escalated)"
        ((PASS++)) || true
    else
        echo "  FAIL: $name (expected escalated)"
        ((FAIL++)) || true
    fi
}

assert_circuit_breaker() {
    local name="$1" output="$2"
    if echo "$output" | grep -q "circuit breaker"; then
        echo "  PASS: $name (circuit breaker)"
        ((PASS++)) || true
    else
        echo "  FAIL: $name (expected circuit breaker)"
        ((FAIL++)) || true
    fi
}

assert_output_contains() {
    local name="$1" output="$2" pattern="$3"
    if echo "$output" | grep -q "$pattern"; then
        echo "  PASS: $name"
        ((PASS++)) || true
    else
        echo "  FAIL: $name (expected output to contain '$pattern')"
        ((FAIL++)) || true
    fi
}

assert_output_not_contains() {
    local name="$1" output="$2" pattern="$3"
    if echo "$output" | grep -q "$pattern"; then
        echo "  FAIL: $name (unexpected '$pattern' in output)"
        ((FAIL++)) || true
    else
        echo "  PASS: $name"
        ((PASS++)) || true
    fi
}

# Clean state before tests
STATE_PREFIX="/tmp/harness-loop-state-test1234"
rm -f "${STATE_PREFIX}.jsonl"
rm -f "/tmp/harness-budget-test1234"

echo "=== Loop Detection Tests ==="

echo ""
echo "Test 1: Single tool call — no loop"
output=$(cat "$FIXTURES/post-tool-use-edit.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
assert_no_loop "single call" "$output"

echo ""
echo "Test 2: 3 identical calls — no loop (threshold is 4)"
rm -f "${STATE_PREFIX}.jsonl" "/tmp/harness-budget-test1234"
for i in 1 2 3; do
    output=$(cat "$FIXTURES/post-tool-use-edit.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
done
assert_no_loop "3 calls same file" "$output"

echo ""
echo "Test 3: 4 identical calls — loop detected"
rm -f "${STATE_PREFIX}.jsonl" "/tmp/harness-budget-test1234"
for i in 1 2 3 4; do
    output=$(cat "$FIXTURES/post-tool-use-edit.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
done
assert_loop_detected "4 calls same file" "$output"

echo ""
echo "Test 4: 3 identical error messages — loop detected"
rm -f "${STATE_PREFIX}.jsonl" "/tmp/harness-budget-test1234"
for i in 1 2 3; do
    output=$(cat "$FIXTURES/post-tool-use-bash-fail.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
done
assert_loop_detected "3 identical errors" "$output"

echo ""
echo "Test 5: Edit-test-fail cycle — 3 iterations triggers loop"
rm -f "${STATE_PREFIX}.jsonl" "/tmp/harness-budget-test1234"
for i in 1 2 3; do
    # Edit call
    cat "$FIXTURES/post-tool-use-edit.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
    # Failing test call — unique error each time so Pattern 2 (error echo) doesn't shadow this
    output=$(jq --arg err "FAIL: Error variant $i — cannot read property of undefined" \
        '.tool_result = $err' "$FIXTURES/post-tool-use-bash-fail.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
done
assert_loop_detected "edit-test-fail cycle" "$output"

echo ""
echo "Test 6: State file keeps only last 20 entries"
rm -f "${STATE_PREFIX}.jsonl" "/tmp/harness-budget-test1234"
for i in $(seq 1 25); do
    # Use a unique file path each time to avoid triggering Pattern 1
    jq --arg fp "/tmp/test-project/src/file${i}.ts" '.tool_input.file_path = $fp' "$FIXTURES/post-tool-use-edit.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
done
line_count=$(wc -l < "${STATE_PREFIX}.jsonl" | tr -d ' ')
if [ "$line_count" -le 20 ]; then
    echo "  PASS: rolling window ($line_count lines <= 20)"
    ((PASS++)) || true
else
    echo "  FAIL: rolling window ($line_count lines > 20)"
    ((FAIL++)) || true
fi

echo ""
echo "Test 7: same-target loop emits loop.detected event"
rm -f "${STATE_PREFIX}.jsonl" "/tmp/harness-budget-test1234"
TEST7_DIR=$(mktemp -d)
TEST7_DIR=$(cd "$TEST7_DIR" && pwd -P)
cleanup_test7() { rm -rf "$TEST7_DIR"; }
trap cleanup_test7 EXIT
(
    cd "$TEST7_DIR"
    git init -q
    git commit --allow-empty -m "init" -q
    mkdir -p .claude/harness/progress
    echo "# Progress" > ".claude/harness/progress/$(git rev-parse --abbrev-ref HEAD)--test1234.md"
)
TEST7_ANALYTICS="$TEST7_DIR/.claude/harness/analytics"
for i in 1 2 3 4; do
    jq --arg cwd "$TEST7_DIR" --arg fp "$TEST7_DIR/src/handler.ts" \
        '.cwd = $cwd | .tool_input.file_path = $fp' \
        "$FIXTURES/post-tool-use-edit.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
done
if [ -f "$TEST7_ANALYTICS/events.jsonl" ]; then
    EVENT=$(jq -r 'select(.event == "loop.detected") | .pattern' "$TEST7_ANALYTICS/events.jsonl" 2>/dev/null | head -1)
    if [ "$EVENT" = "same-target" ]; then
        echo "  PASS: loop.detected event with pattern=same-target"
        ((PASS++)) || true
    else
        echo "  FAIL: expected loop.detected event with pattern=same-target, got: $EVENT"
        ((FAIL++)) || true
    fi
else
    echo "  FAIL: events.jsonl not created"
    ((FAIL++)) || true
fi
rm -rf "$TEST7_DIR"
trap - EXIT

echo ""
echo "Test 8: 3 same-target calls — nudge (Harness notice, no LOOP DETECTED)"
rm -f "${STATE_PREFIX}.jsonl" "/tmp/harness-budget-test1234"
for i in 1 2 3; do
    output=$(cat "$FIXTURES/post-tool-use-edit.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
done
assert_nudge "3 same-target nudge" "$output"

echo ""
echo "Test 9: 6 same-target calls — escalated message"
rm -f "${STATE_PREFIX}.jsonl" "/tmp/harness-budget-test1234"
for i in 1 2 3 4 5 6; do
    output=$(cat "$FIXTURES/post-tool-use-edit.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
done
assert_escalated "6 same-target escalated" "$output"

echo ""
echo "Test 10: 8 same-target calls — circuit breaker message"
rm -f "${STATE_PREFIX}.jsonl" "/tmp/harness-budget-test1234"
for i in 1 2 3 4 5 6 7 8; do
    output=$(cat "$FIXTURES/post-tool-use-edit.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
done
assert_circuit_breaker "8 same-target circuit breaker" "$output"

echo ""
echo "Test 11: 2 error-echo calls — nudge"
rm -f "${STATE_PREFIX}.jsonl" "/tmp/harness-budget-test1234"
for i in 1 2; do
    output=$(cat "$FIXTURES/post-tool-use-bash-fail.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
done
assert_nudge "2 error-echo nudge" "$output"

echo ""
echo "Test 12: edit-test-fail at level 3 (4 cycles) — escalated message"
rm -f "${STATE_PREFIX}.jsonl" "/tmp/harness-budget-test1234"
for i in 1 2 3 4; do
    # Edit call
    cat "$FIXTURES/post-tool-use-edit.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
    # Failing test call — unique error each time so Pattern 2 (error echo) doesn't shadow this
    output=$(jq --arg err "FAIL: Error variant $i — cannot read property of undefined" \
        '.tool_result = $err' "$FIXTURES/post-tool-use-bash-fail.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
done
assert_escalated "edit-test-fail level 3" "$output"

echo ""
echo "Test 13: Budget advisory at 50 tool calls"
rm -f "${STATE_PREFIX}.jsonl" "/tmp/harness-budget-test1234"
echo "49" > "/tmp/harness-budget-test1234"
output=$(jq --arg fp "/tmp/test-project/src/unique-budget-test.ts" '.tool_input.file_path = $fp' "$FIXTURES/post-tool-use-edit.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
assert_output_contains "budget advisory at 50" "$output" "Budget advisory"

echo ""
echo "Test 14: No budget message at 51"
output=$(jq --arg fp "/tmp/test-project/src/unique-budget-test2.ts" '.tool_input.file_path = $fp' "$FIXTURES/post-tool-use-edit.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
assert_output_not_contains "no budget message at 51" "$output" "Budget"

echo ""
echo "Test 15: Budget warning at 100"
echo "99" > "/tmp/harness-budget-test1234"
rm -f "${STATE_PREFIX}.jsonl"
output=$(jq --arg fp "/tmp/test-project/src/unique-budget-test3.ts" '.tool_input.file_path = $fp' "$FIXTURES/post-tool-use-edit.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
assert_output_contains "budget warning at 100" "$output" "Budget warning"

echo ""
echo "Test 16: Budget critical at 150"
echo "149" > "/tmp/harness-budget-test1234"
rm -f "${STATE_PREFIX}.jsonl"
output=$(jq --arg fp "/tmp/test-project/src/unique-budget-test4.ts" '.tool_input.file_path = $fp' "$FIXTURES/post-tool-use-edit.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
assert_output_contains "budget critical at 150" "$output" "Budget critical"

# Cleanup
rm -f "${STATE_PREFIX}.jsonl"
rm -f "/tmp/harness-budget-test1234"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
