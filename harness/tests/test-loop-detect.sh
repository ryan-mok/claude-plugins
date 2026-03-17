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

# Clean state before tests
STATE_PREFIX="/tmp/harness-loop-state-test1234"
rm -f "${STATE_PREFIX}.jsonl"

echo "=== Loop Detection Tests ==="

echo ""
echo "Test 1: Single tool call — no loop"
output=$(cat "$FIXTURES/post-tool-use-edit.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
assert_no_loop "single call" "$output"

echo ""
echo "Test 2: 3 identical calls — no loop (threshold is 4)"
rm -f "${STATE_PREFIX}.jsonl"
for i in 1 2 3; do
    output=$(cat "$FIXTURES/post-tool-use-edit.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
done
assert_no_loop "3 calls same file" "$output"

echo ""
echo "Test 3: 4 identical calls — loop detected"
rm -f "${STATE_PREFIX}.jsonl"
for i in 1 2 3 4; do
    output=$(cat "$FIXTURES/post-tool-use-edit.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
done
assert_loop_detected "4 calls same file" "$output"

echo ""
echo "Test 4: 3 identical error messages — loop detected"
rm -f "${STATE_PREFIX}.jsonl"
for i in 1 2 3; do
    output=$(cat "$FIXTURES/post-tool-use-bash-fail.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
done
assert_loop_detected "3 identical errors" "$output"

echo ""
echo "Test 5: Edit-test-fail cycle — 3 iterations triggers loop"
rm -f "${STATE_PREFIX}.jsonl"
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
rm -f "${STATE_PREFIX}.jsonl"
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
rm -f "${STATE_PREFIX}.jsonl"
ANALYTICS_DIR="/tmp/test-project/.claude/harness/analytics"
rm -rf "$ANALYTICS_DIR"
for i in 1 2 3 4; do
    cat "$FIXTURES/post-tool-use-edit.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
done
if [ -f "$ANALYTICS_DIR/events.jsonl" ]; then
    EVENT=$(jq -r 'select(.event == "loop.detected") | .pattern' "$ANALYTICS_DIR/events.jsonl" 2>/dev/null | head -1)
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
rm -rf "$ANALYTICS_DIR"

# Cleanup
rm -f "${STATE_PREFIX}.jsonl"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
