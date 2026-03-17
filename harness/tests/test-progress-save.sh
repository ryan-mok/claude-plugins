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
TEST_BRANCH=$(git rev-parse --abbrev-ref HEAD)

echo "=== Progress Save Tests ==="

echo ""
echo "Test 1: Stop event — no progress dir means silent approve (harness never used)"
output=$(jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
if echo "$output" | jq -e '.decision == "approve"' > /dev/null 2>&1; then
    echo "  PASS: Stop returns silent approve when no progress dir"
    ((PASS++)) || true
else
    echo "  FAIL: expected silent approve (got: $output)"
    ((FAIL++)) || true
fi
# Now create progress dir for subsequent tests
mkdir -p "$PROGRESS_DIR"

echo ""
echo "Test 2: Stop event with agent-written progress — outputs systemMessage"
cat > "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md" << 'EOF'
# Harness Progress
**Updated:** 2026-01-01T00:00:00Z

## Current Status
In progress
EOF
output=$(jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
if echo "$output" | jq -e '.systemMessage' > /dev/null 2>&1; then
    echo "  PASS: Stop with active progress returns systemMessage"
    ((PASS++)) || true
else
    echo "  FAIL: expected systemMessage (got: $output)"
    ((FAIL++)) || true
fi
rm -f "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md"

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
echo "# Agent-written progress" > "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md"
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
assert_contains "existing file preserved" "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md" "Agent-written progress"

echo ""
echo "Test 5: _index.md lists progress files"
assert_contains "index lists files" "$PROGRESS_DIR/_index.md" "${TEST_BRANCH}--test1234"

echo ""
echo "Test 6: Stop event with COMPLETE status — silent approve (no systemMessage)"
rm -rf "$PROGRESS_DIR"
mkdir -p "$PROGRESS_DIR"
cat > "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md" << 'EOF'
# Harness Progress
**Updated:** 2026-01-01T00:00:00Z

## Status: COMPLETE
EOF
output=$(jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
if echo "$output" | jq -e '.systemMessage' > /dev/null 2>&1; then
    echo "  FAIL: COMPLETE task should not produce systemMessage (got: $output)"
    ((FAIL++)) || true
else
    if echo "$output" | jq -e '.decision == "approve"' > /dev/null 2>&1; then
        echo "  PASS: COMPLETE task returns silent approve"
        ((PASS++)) || true
    else
        echo "  FAIL: expected silent approve (got: $output)"
        ((FAIL++)) || true
    fi
fi

echo ""
echo "Test 7: Stale files (7+ days) are cleaned up"
rm -rf "$PROGRESS_DIR"
mkdir -p "$PROGRESS_DIR"
echo "# stale" > "$PROGRESS_DIR/old-branch--stale123.md"
# Set file modification time to 8 days ago
touch -t "$(date -v-8d +%Y%m%d%H%M.%S)" "$PROGRESS_DIR/old-branch--stale123.md"
echo "# fresh" > "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md"
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
if [ -f "$PROGRESS_DIR/old-branch--stale123.md" ]; then
    echo "  FAIL: stale file should have been cleaned up"
    ((FAIL++)) || true
else
    echo "  PASS: stale file cleaned up"
    ((PASS++)) || true
fi
assert_file_exists "fresh file kept" "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md"

echo ""
echo "Test 8: PreCompact with progress dir emits session.compact event"
rm -rf "$PROGRESS_DIR"
mkdir -p "$PROGRESS_DIR"
ANALYTICS_DIR="$TEST_DIR/.claude/harness/analytics"
rm -rf "$ANALYTICS_DIR"
echo "# in progress" > "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md"
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/pre-compact.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
EVENTS_FILE="$ANALYTICS_DIR/events.jsonl"
assert_file_exists "events.jsonl created" "$EVENTS_FILE"
if [ -f "$EVENTS_FILE" ]; then
    COMPACT_EVENT=$(jq -r 'select(.event=="session.compact")' "$EVENTS_FILE" 2>/dev/null)
    if [ -n "$COMPACT_EVENT" ]; then
        echo "  PASS: session.compact event found"
        ((PASS++)) || true
        CCOUNT=$(echo "$COMPACT_EVENT" | jq -r '.compaction_count')
        if [ "$CCOUNT" = "1" ]; then
            echo "  PASS: compaction_count is 1"
            ((PASS++)) || true
        else
            echo "  FAIL: expected compaction_count=1, got $CCOUNT"
            ((FAIL++)) || true
        fi
    else
        echo "  FAIL: session.compact event not found in events.jsonl"
        ((FAIL++)) || true
        echo "  SKIP: compaction_count check (no event)"
        ((FAIL++)) || true
    fi
else
    echo "  SKIP: session.compact check (no events file)"
    ((FAIL++)) || true
    echo "  SKIP: compaction_count check (no events file)"
    ((FAIL++)) || true
fi

echo ""
echo "Test 9: Stop event does NOT emit session.compact"
rm -rf "$PROGRESS_DIR"
mkdir -p "$PROGRESS_DIR"
rm -rf "$ANALYTICS_DIR"
echo "# in progress" > "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md"
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true
if [ -f "$ANALYTICS_DIR/events.jsonl" ]; then
    if jq -e 'select(.event=="session.compact")' "$ANALYTICS_DIR/events.jsonl" > /dev/null 2>&1; then
        echo "  FAIL: Stop event should not emit session.compact"
        ((FAIL++)) || true
    else
        echo "  PASS: Stop event does not emit session.compact"
        ((PASS++)) || true
    fi
else
    echo "  PASS: Stop event does not emit session.compact (no events file)"
    ((PASS++)) || true
fi

# Cleanup
rm -rf "$TEST_DIR"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
