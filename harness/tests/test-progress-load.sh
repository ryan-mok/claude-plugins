#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/scripts/progress-load.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
# Resolve symlinks for consistency with hook scripts (macOS /var -> /private/var)
TEST_DIR=$(cd "$TEST_DIR" && pwd -P)
PROGRESS_DIR="$TEST_DIR/.claude/harness/progress"

# Set CLAUDE_PLUGIN_ROOT so progress-load.sh uses hookSpecificOutput format
export CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR/.."

# Setup: init a git repo in test dir (required for git root resolution)
cd "$TEST_DIR"
git init -q
git commit --allow-empty -m "initial" -q
TEST_BRANCH=$(git rev-parse --abbrev-ref HEAD)

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
echo "# Test progress content" > "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md"
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
rm -f "$PROGRESS_DIR/${TEST_BRANCH}--test1234.md"
echo "# Index content" > "$PROGRESS_DIR/_index.md"
output=$(jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/session-start.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
if echo "$output" | jq -e '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q "Index content"; then
    echo "  PASS: index loaded as fallback"
    ((PASS++)) || true
else
    echo "  FAIL: index not loaded (got: $output)"
    ((FAIL++)) || true
fi

echo ""
echo "Test 4: Branch fallback — different session, same branch loads most recent"
rm -rf "$PROGRESS_DIR"
mkdir -p "$PROGRESS_DIR"
# Create a progress file from a different session on the same branch
cat > "$PROGRESS_DIR/${TEST_BRANCH}--othersess.md" << 'EOF'
# Harness Progress
**Updated:** 2026-01-01T00:00:00Z

## Current Status
In progress — working on feature X
EOF
output=$(jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/session-start.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
if echo "$output" | jq -e '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q "working on feature X"; then
    echo "  PASS: branch fallback loaded from different session"
    ((PASS++)) || true
else
    echo "  FAIL: branch fallback not loaded (got: $output)"
    ((FAIL++)) || true
fi

echo ""
echo "Test 5: Branch fallback — skips completed tasks"
rm -rf "$PROGRESS_DIR"
mkdir -p "$PROGRESS_DIR"
# Create a COMPLETED progress file from a different session
cat > "$PROGRESS_DIR/${TEST_BRANCH}--oldsess1.md" << 'EOF'
# Harness Progress
**Updated:** 2026-01-01T00:00:00Z

## Current Status
COMPLETE — PR created
EOF
echo "# Index with sessions" > "$PROGRESS_DIR/_index.md"
output=$(jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/session-start.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
if echo "$output" | jq -e '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q "COMPLETE"; then
    echo "  FAIL: should not load completed task (got: $output)"
    ((FAIL++)) || true
else
    if echo "$output" | jq -e '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q "Index with sessions"; then
        echo "  PASS: skipped completed task, fell through to index"
        ((PASS++)) || true
    else
        echo "  FAIL: expected index fallback (got: $output)"
        ((FAIL++)) || true
    fi
fi

echo ""
echo "Test 6: Worktree support — progress dir resolves to main repo root"
# Create a worktree
WORKTREE_BRANCH="test-worktree-branch"
git checkout -b "$WORKTREE_BRANCH" -q
git checkout "${TEST_BRANCH}" -q
WORKTREE_DIR=$(mktemp -d)
WORKTREE_DIR=$(cd "$WORKTREE_DIR" && pwd -P)
rm -rf "$WORKTREE_DIR"
git worktree add "$WORKTREE_DIR" "$WORKTREE_BRANCH" -q 2>/dev/null
# Create progress file at main repo (where it should be)
rm -rf "$PROGRESS_DIR"
mkdir -p "$PROGRESS_DIR"
cat > "$PROGRESS_DIR/${WORKTREE_BRANCH}--test1234.md" << 'EOF'
# Harness Progress from main repo

## Current Status
Working in worktree
EOF
# Run hook from worktree CWD — should find progress at main repo root
output=$(jq --arg cwd "$WORKTREE_DIR" '.cwd = $cwd' "$FIXTURES/session-start.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
if echo "$output" | jq -e '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q "Working in worktree"; then
    echo "  PASS: worktree resolved to main repo progress"
    ((PASS++)) || true
else
    echo "  FAIL: worktree did not resolve to main repo (got: $output)"
    ((FAIL++)) || true
fi
# Cleanup worktree
git worktree remove "$WORKTREE_DIR" 2>/dev/null || rm -rf "$WORKTREE_DIR"
git branch -D "$WORKTREE_BRANCH" -q 2>/dev/null || true

# Cleanup
rm -rf "$TEST_DIR"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
