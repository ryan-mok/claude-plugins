#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/scripts/progress-save.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
PROGRESS_DIR="$TEST_DIR/.claude/harness/progress"

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

# Setup: init a git repo in test dir
cd "$TEST_DIR"
git init -q
git commit --allow-empty -m "initial" -q

echo "=== Progress Save Tests ==="

echo ""
echo "Test 1: Stop event — creates progress dir and fallback file"
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
assert_file_exists "progress dir created" "$PROGRESS_DIR/_index.md"

echo ""
echo "Test 2: Stop event — output contains decision:approve"
output=$(jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
if echo "$output" | jq -e '.decision == "approve"' > /dev/null 2>&1; then
    echo "  PASS: Stop returns decision:approve"
    ((PASS++)) || true
else
    echo "  FAIL: Stop missing decision:approve (got: $output)"
    ((FAIL++)) || true
fi

echo ""
echo "Test 3: PreCompact event — no decision field"
rm -rf "$PROGRESS_DIR"
output=$(jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/pre-compact.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
if echo "$output" | jq -e '.decision' > /dev/null 2>&1; then
    echo "  FAIL: PreCompact should not have decision field"
    ((FAIL++)) || true
else
    echo "  PASS: PreCompact has no decision field"
    ((PASS++)) || true
fi

echo ""
echo "Test 4: Does not overwrite existing progress file"
rm -rf "$PROGRESS_DIR"
mkdir -p "$PROGRESS_DIR"
echo "# Agent-written progress" > "$PROGRESS_DIR/main--test1234.md"
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
assert_contains "existing file preserved" "$PROGRESS_DIR/main--test1234.md" "Agent-written progress"

echo ""
echo "Test 5: _index.md lists progress files"
assert_contains "index lists files" "$PROGRESS_DIR/_index.md" "main--test1234"

# Cleanup
rm -rf "$TEST_DIR"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
