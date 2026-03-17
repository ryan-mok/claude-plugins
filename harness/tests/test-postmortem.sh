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
POSTMORTEM_DIR="$ANALYTICS_DIR/postmortems"

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

assert_file_not_exists() {
    local name="$1" file="$2"
    if [ ! -f "$file" ]; then
        echo "  PASS: $name"
        ((PASS++)) || true
    else
        echo "  FAIL: $name ($file should not exist)"
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

assert_not_contains() {
    local name="$1" file="$2" pattern="$3"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo "  PASS: $name"
        ((PASS++)) || true
    else
        echo "  FAIL: $name (pattern '$pattern' should not be in $file)"
        ((FAIL++)) || true
    fi
}

# Setup: init a git repo in test dir
cd "$TEST_DIR"
git init -q
git commit --allow-empty -m "initial" -q
TEST_BRANCH=$(git rev-parse --abbrev-ref HEAD)
TEST_BRANCH_SAFE=$(echo "$TEST_BRANCH" | tr '/' '-')

trap 'rm -rf "$TEST_DIR" /tmp/harness-loop-state-test1234.jsonl' EXIT

echo "=== Post-Mortem Generation Tests ==="

# ---------- Test 1: Post-mortem generated when session has loops ----------

echo ""
echo "Test 1: Post-mortem generated when session has loops"
rm -rf "$PROGRESS_DIR" "$ANALYTICS_DIR"
mkdir -p "$PROGRESS_DIR" "$ANALYTICS_DIR"

# Create progress file
cat > "$PROGRESS_DIR/${TEST_BRANCH_SAFE}--test1234.md" << 'EOF'
# Harness Progress

## Current Status
In progress
EOF

# Inject a loop.detected event and session.start before running Stop
jq -n -c --arg sid "test1234" --arg branch "$TEST_BRANCH" \
    '{ts:"2026-01-01T00:00:00Z",event:"session.start",session_id:$sid,branch:$branch,scope:"single",worktree:false,repo_root:"/tmp"}' \
    > "$ANALYTICS_DIR/events.jsonl"
jq -n -c --arg sid "test1234" --arg branch "$TEST_BRANCH" \
    '{ts:"2026-01-01T00:05:00Z",event:"loop.detected",session_id:$sid,branch:$branch,scope:"single",worktree:false,repo_root:"/tmp",tool:"Edit",file:"src/main.ts",count:4}' \
    >> "$ANALYTICS_DIR/events.jsonl"

rm -f /tmp/harness-loop-state-test1234.jsonl
POSTMORTEM_FILE="$POSTMORTEM_DIR/${TEST_BRANCH_SAFE}--test1234.md"
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true

assert_file_exists "post-mortem file created" "$POSTMORTEM_FILE"
if [ -f "$POSTMORTEM_FILE" ]; then
    assert_contains "has header" "$POSTMORTEM_FILE" "# Post-Mortem: test1234"
    assert_contains "has Loops section" "$POSTMORTEM_FILE" "## Loops"
    assert_contains "has loop tool" "$POSTMORTEM_FILE" "Edit"
    assert_contains "has loop file" "$POSTMORTEM_FILE" "src/main.ts"
fi

# ---------- Test 2: No post-mortem for clean success ----------

echo ""
echo "Test 2: No post-mortem for clean success"
rm -rf "$PROGRESS_DIR" "$ANALYTICS_DIR"
mkdir -p "$PROGRESS_DIR" "$ANALYTICS_DIR"

# Create progress file marked complete with success outcome
cat > "$PROGRESS_DIR/${TEST_BRANCH_SAFE}--test1234.md" << 'EOF'
# Harness Progress

## Agent Outcome
success

## Current Status
Complete
EOF

# Inject only a session.start event (no loops, no violations)
jq -n -c --arg sid "test1234" --arg branch "$TEST_BRANCH" \
    '{ts:"2026-01-01T00:00:00Z",event:"session.start",session_id:$sid,branch:$branch,scope:"single",worktree:false,repo_root:"/tmp"}' \
    > "$ANALYTICS_DIR/events.jsonl"

rm -f /tmp/harness-loop-state-test1234.jsonl
POSTMORTEM_FILE="$POSTMORTEM_DIR/${TEST_BRANCH_SAFE}--test1234.md"
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true

assert_file_not_exists "no post-mortem for clean success" "$POSTMORTEM_FILE"

# ---------- Test 3: Post-mortem contains Timeline, Loops, and Outcome Analysis ----------

echo ""
echo "Test 3: Post-mortem contains Timeline, Loops, and Outcome Analysis sections"
rm -rf "$PROGRESS_DIR" "$ANALYTICS_DIR"
mkdir -p "$PROGRESS_DIR" "$ANALYTICS_DIR"

# Create progress file with agent saying success but heuristic will say partial (disagreement)
cat > "$PROGRESS_DIR/${TEST_BRANCH_SAFE}--test1234.md" << 'EOF'
# Harness Progress

## Agent Outcome
success

## Current Status
In progress
EOF

# Inject events: session.start, loop.detected, constraint.violation
jq -n -c --arg sid "test1234" --arg branch "$TEST_BRANCH" \
    '{ts:"2026-01-01T00:00:00Z",event:"session.start",session_id:$sid,branch:$branch,scope:"single",worktree:false,repo_root:"/tmp"}' \
    > "$ANALYTICS_DIR/events.jsonl"
jq -n -c --arg sid "test1234" --arg branch "$TEST_BRANCH" \
    '{ts:"2026-01-01T00:03:00Z",event:"loop.detected",session_id:$sid,branch:$branch,scope:"single",worktree:false,repo_root:"/tmp",tool:"Bash",file:"npm test",count:3}' \
    >> "$ANALYTICS_DIR/events.jsonl"
jq -n -c --arg sid "test1234" --arg branch "$TEST_BRANCH" \
    '{ts:"2026-01-01T00:04:00Z",event:"constraint.violation",session_id:$sid,branch:$branch,scope:"single",worktree:false,repo_root:"/tmp",rule:"no-eval",severity:"block",decision:"deny"}' \
    >> "$ANALYTICS_DIR/events.jsonl"

rm -f /tmp/harness-loop-state-test1234.jsonl
POSTMORTEM_FILE="$POSTMORTEM_DIR/${TEST_BRANCH_SAFE}--test1234.md"
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true

assert_file_exists "post-mortem file created" "$POSTMORTEM_FILE"
if [ -f "$POSTMORTEM_FILE" ]; then
    # Timeline section
    assert_contains "has Timeline section" "$POSTMORTEM_FILE" "## Timeline"
    assert_contains "timeline has session.start" "$POSTMORTEM_FILE" "session.start"
    assert_contains "timeline has loop.detected" "$POSTMORTEM_FILE" "loop.detected"
    assert_contains "timeline has constraint.violation" "$POSTMORTEM_FILE" "constraint.violation"

    # Loops section
    assert_contains "has Loops section" "$POSTMORTEM_FILE" "## Loops"
    assert_contains "loops has tool" "$POSTMORTEM_FILE" "Bash"
    assert_contains "loops has file" "$POSTMORTEM_FILE" "npm test"

    # Constraint Violations section
    assert_contains "has Constraint Violations section" "$POSTMORTEM_FILE" "## Constraint Violations"
    assert_contains "violations has rule" "$POSTMORTEM_FILE" "no-eval"
    assert_contains "violations has decision" "$POSTMORTEM_FILE" "deny"

    # Outcome Analysis section
    assert_contains "has Outcome Analysis section" "$POSTMORTEM_FILE" "## Outcome Analysis"
    assert_contains "shows agent outcome" "$POSTMORTEM_FILE" "Agent outcome.*success"
    assert_contains "shows heuristic outcome" "$POSTMORTEM_FILE" "Heuristic outcome.*failed"
    assert_contains "shows disagreement" "$POSTMORTEM_FILE" "no -- agent and heuristic disagree"

    # Signals section
    assert_contains "has Signals section" "$POSTMORTEM_FILE" "## Signals"
    assert_contains "signals has loop info" "$POSTMORTEM_FILE" "loop(s) detected"
    assert_contains "signals has violation info" "$POSTMORTEM_FILE" "constraint violation(s) blocked"
    assert_contains "signals has disagreement" "$POSTMORTEM_FILE" "Outcome disagreement"

    # Header table
    assert_contains "header has Session" "$POSTMORTEM_FILE" "| Session | test1234 |"
    assert_contains "header has Mode" "$POSTMORTEM_FILE" "| Mode |"
fi

# ---------- Test 4: Post-mortem generated for outcome disagreement ----------

echo ""
echo "Test 4: Post-mortem generated when outcome_agreement is false"
rm -rf "$PROGRESS_DIR" "$ANALYTICS_DIR"
mkdir -p "$PROGRESS_DIR" "$ANALYTICS_DIR"

# Agent says success, heuristic will say partial (no complete marker, no PR)
cat > "$PROGRESS_DIR/${TEST_BRANCH_SAFE}--test1234.md" << 'EOF'
# Harness Progress

## Agent Outcome
success

## Current Status
In progress
EOF

# Inject only session.start (no loops, no violations) -- heuristic will be partial
jq -n -c --arg sid "test1234" --arg branch "$TEST_BRANCH" \
    '{ts:"2026-01-01T00:00:00Z",event:"session.start",session_id:$sid,branch:$branch,scope:"single",worktree:false,repo_root:"/tmp"}' \
    > "$ANALYTICS_DIR/events.jsonl"

rm -f /tmp/harness-loop-state-test1234.jsonl
POSTMORTEM_FILE="$POSTMORTEM_DIR/${TEST_BRANCH_SAFE}--test1234.md"
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true

assert_file_exists "post-mortem for outcome disagreement" "$POSTMORTEM_FILE"
if [ -f "$POSTMORTEM_FILE" ]; then
    assert_contains "shows disagreement signal" "$POSTMORTEM_FILE" "Outcome disagreement"
fi

# ---------- Test 5: Post-mortem generated for high compaction count ----------

echo ""
echo "Test 5: Post-mortem generated when compaction_count >= 3"
rm -rf "$PROGRESS_DIR" "$ANALYTICS_DIR"
mkdir -p "$PROGRESS_DIR" "$ANALYTICS_DIR"

cat > "$PROGRESS_DIR/${TEST_BRANCH_SAFE}--test1234.md" << 'EOF'
# Harness Progress

## Agent Outcome
partial

## Current Status
In progress
EOF

# Inject session.start + 3 compact events
jq -n -c --arg sid "test1234" --arg branch "$TEST_BRANCH" \
    '{ts:"2026-01-01T00:00:00Z",event:"session.start",session_id:$sid,branch:$branch,scope:"single",worktree:false,repo_root:"/tmp"}' \
    > "$ANALYTICS_DIR/events.jsonl"
for i in 1 2 3; do
    jq -n -c --arg sid "test1234" --arg branch "$TEST_BRANCH" --argjson n "$i" \
        '{ts:"2026-01-01T00:0\($n):00Z",event:"session.compact",session_id:$sid,branch:$branch,scope:"single",worktree:false,repo_root:"/tmp",compaction_count:$n}' \
        >> "$ANALYTICS_DIR/events.jsonl"
done

rm -f /tmp/harness-loop-state-test1234.jsonl
POSTMORTEM_FILE="$POSTMORTEM_DIR/${TEST_BRANCH_SAFE}--test1234.md"
jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/stop.json" | bash "$HOOK_SCRIPT" > /dev/null 2>&1 || true

assert_file_exists "post-mortem for high compaction" "$POSTMORTEM_FILE"
if [ -f "$POSTMORTEM_FILE" ]; then
    assert_contains "signals has compaction info" "$POSTMORTEM_FILE" "High compaction count"
fi

# Cleanup handled by trap
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
