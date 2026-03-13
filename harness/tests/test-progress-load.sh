#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/scripts/progress-load.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
PROGRESS_DIR="$TEST_DIR/.claude/harness/progress"

# Set CLAUDE_PLUGIN_ROOT so progress-load.sh uses hookSpecificOutput format
export CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR/.."

echo "=== Progress Load Tests ==="

echo ""
echo "Test 1: No progress dir — silent exit"
output=$(jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/session-start.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
if [ -z "$output" ] || echo "$output" | jq -e '.hookSpecificOutput.additionalContext == null or .hookSpecificOutput.additionalContext == ""' > /dev/null 2>&1; then
    echo "  PASS: no progress dir = no output"
    ((PASS++)) || true
else
    echo "  FAIL: unexpected output without progress dir"
    ((FAIL++)) || true
fi

echo ""
echo "Test 2: Matching session file — loads it"
mkdir -p "$PROGRESS_DIR"
echo "# Test progress content" > "$PROGRESS_DIR/main--test1234.md"
output=$(jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/session-start.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
if echo "$output" | jq -e '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q "Test progress content"; then
    echo "  PASS: session file loaded"
    ((PASS++)) || true
else
    echo "  FAIL: session file not loaded (got: $output)"
    ((FAIL++)) || true
fi

echo ""
echo "Test 3: No matching session — loads _index.md"
rm -f "$PROGRESS_DIR/main--test1234.md"
echo "# Index content" > "$PROGRESS_DIR/_index.md"
output=$(jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/session-start.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
if echo "$output" | jq -e '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q "Index content"; then
    echo "  PASS: index loaded as fallback"
    ((PASS++)) || true
else
    echo "  FAIL: index not loaded (got: $output)"
    ((FAIL++)) || true
fi

# Cleanup
rm -rf "$TEST_DIR"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
