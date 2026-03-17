#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/scripts/constraint-check.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
TEST_DIR=$(cd "$TEST_DIR" && pwd -P)

echo "=== Constraint Check Tests ==="

echo ""
echo "Test 1: No constraints file — allow silently"
output=$(jq --arg cwd "$TEST_DIR" --arg fp "$TEST_DIR/src/api/handler.ts" '.cwd = $cwd | .tool_input.file_path = $fp' "$FIXTURES/pre-tool-use-write.json" | bash "$HOOK_SCRIPT" 2>&1)
EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 0 ] && [ -z "$output" ]; then
    echo "  PASS: no constraints = silent allow"
    ((PASS++)) || true
else
    echo "  FAIL: expected silent exit (got exit=$EXIT_CODE, output=$output)"
    ((FAIL++)) || true
fi

echo ""
echo "Test 2: Constraint file exists but no matching rules — allow"
mkdir -p "$TEST_DIR/.claude/harness"
cat > "$TEST_DIR/.claude/harness/constraints.json" << 'RULES'
{
  "rules": [
    {
      "name": "no-env-in-tests",
      "type": "file-pattern",
      "description": "Tests must not use env vars",
      "deny": { "in": "tests/**", "pattern": "process\\.env\\." },
      "severity": "block"
    }
  ]
}
RULES
output=$(jq --arg cwd "$TEST_DIR" --arg fp "$TEST_DIR/src/api/handler.ts" '.cwd = $cwd | .tool_input.file_path = $fp' "$FIXTURES/pre-tool-use-write.json" | bash "$HOOK_SCRIPT" 2>&1)
if [ -z "$output" ]; then
    echo "  PASS: no matching rules = silent allow"
    ((PASS++)) || true
else
    echo "  FAIL: expected silent exit for non-matching path"
    ((FAIL++)) || true
fi

echo ""
echo "Test 3: Matching file-pattern rule with warn severity"
cat > "$TEST_DIR/.claude/harness/constraints.json" << 'RULES'
{
  "rules": [
    {
      "name": "no-env-in-source",
      "type": "file-pattern",
      "description": "Source files must not read env vars directly",
      "deny": { "in": "src/**", "pattern": "process\\.env\\." },
      "severity": "warn"
    }
  ]
}
RULES
output=$(jq --arg cwd "$TEST_DIR" --arg fp "$TEST_DIR/src/api/handler.ts" '.cwd = $cwd | .tool_input.file_path = $fp' "$FIXTURES/pre-tool-use-write.json" | bash "$HOOK_SCRIPT" 2>&1)
if echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' > /dev/null 2>&1 && \
   echo "$output" | jq -e '.systemMessage' 2>/dev/null | grep -q "no-env-in-source"; then
    echo "  PASS: warn rule = allow + systemMessage"
    ((PASS++)) || true
else
    echo "  FAIL: expected allow + warning (got: $output)"
    ((FAIL++)) || true
fi

echo ""
echo "Test 4: Matching file-pattern rule with block severity"
cat > "$TEST_DIR/.claude/harness/constraints.json" << 'RULES'
{
  "rules": [
    {
      "name": "no-env-in-source",
      "type": "file-pattern",
      "description": "Source files must not read env vars directly",
      "deny": { "in": "src/**", "pattern": "process\\.env\\." },
      "severity": "block"
    }
  ]
}
RULES
output=$(jq --arg cwd "$TEST_DIR" --arg fp "$TEST_DIR/src/api/handler.ts" '.cwd = $cwd | .tool_input.file_path = $fp' "$FIXTURES/pre-tool-use-write.json" | bash "$HOOK_SCRIPT" 2>&1)
if echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null 2>&1; then
    echo "  PASS: block rule = deny"
    ((PASS++)) || true
else
    echo "  FAIL: expected deny (got: $output)"
    ((FAIL++)) || true
fi

echo ""
echo "Test 5: import-boundary rule — blocks forbidden import"
cat > "$TEST_DIR/.claude/harness/constraints.json" << 'RULES'
{
  "rules": [
    {
      "name": "no-cross-module-imports",
      "type": "import-boundary",
      "description": "API layer must not import from data layer",
      "deny": { "from": "src/api/**", "import": "src/data/**" },
      "severity": "block"
    }
  ]
}
RULES
output=$(jq --arg cwd "$TEST_DIR" --arg fp "$TEST_DIR/src/api/handler.ts" '.cwd = $cwd | .tool_input.file_path = $fp' "$FIXTURES/pre-tool-use-write.json" | bash "$HOOK_SCRIPT" 2>&1)
if echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null 2>&1; then
    echo "  PASS: import-boundary blocks cross-layer import"
    ((PASS++)) || true
else
    echo "  FAIL: expected deny for cross-layer import (got: $output)"
    ((FAIL++)) || true
fi

echo ""
echo "Test 6: Rule pattern does not match content — allow"
cat > "$TEST_DIR/.claude/harness/constraints.json" << 'RULES'
{
  "rules": [
    {
      "name": "no-eval",
      "type": "file-pattern",
      "description": "No eval in source",
      "deny": { "in": "src/**", "pattern": "\\beval\\(" },
      "severity": "block"
    }
  ]
}
RULES
output=$(jq --arg cwd "$TEST_DIR" --arg fp "$TEST_DIR/src/api/handler.ts" '.cwd = $cwd | .tool_input.file_path = $fp' "$FIXTURES/pre-tool-use-write.json" | bash "$HOOK_SCRIPT" 2>&1)
if [ -z "$output" ]; then
    echo "  PASS: non-matching pattern = silent allow"
    ((PASS++)) || true
else
    echo "  FAIL: expected silent allow (got: $output)"
    ((FAIL++)) || true
fi

echo ""
echo "Test 7: Violation event emitted to events.jsonl"
# Re-init TEST_DIR as a git repo so emit_event can resolve the git root
rm -rf "$TEST_DIR"
TEST_DIR=$(mktemp -d)
# Resolve symlinks (macOS /var -> /private/var) so paths match get_git_root
TEST_DIR=$(cd "$TEST_DIR" && pwd -P)
git -C "$TEST_DIR" init -q
git -C "$TEST_DIR" commit --allow-empty -m "init" -q
mkdir -p "$TEST_DIR/.claude/harness"
cat > "$TEST_DIR/.claude/harness/constraints.json" << 'RULES'
{
  "rules": [
    {
      "name": "no-env-in-source",
      "type": "file-pattern",
      "description": "Source files must not read env vars directly",
      "deny": { "in": "src/**", "pattern": "process\\.env\\." },
      "severity": "warn"
    }
  ]
}
RULES
output=$(jq --arg cwd "$TEST_DIR" --arg fp "$TEST_DIR/src/api/handler.ts" '.cwd = $cwd | .tool_input.file_path = $fp' "$FIXTURES/pre-tool-use-write.json" | bash "$HOOK_SCRIPT" 2>&1)
EVENTS_FILE="$TEST_DIR/.claude/harness/analytics/events.jsonl"
if [ -f "$EVENTS_FILE" ] && grep -q '"constraint.violation"' "$EVENTS_FILE"; then
    echo "  PASS: constraint.violation event written to events.jsonl"
    ((PASS++)) || true
else
    echo "  FAIL: expected constraint.violation event in $EVENTS_FILE (output: $output)"
    ((FAIL++)) || true
fi

echo ""
echo "Test 8: Event contains rule, file, severity, decision fields"
if [ -f "$EVENTS_FILE" ]; then
    EVENT_LINE=$(grep '"constraint.violation"' "$EVENTS_FILE" | tail -1)
    HAS_RULE=$(echo "$EVENT_LINE" | jq -e '.rule == "no-env-in-source"' 2>/dev/null)
    HAS_FILE=$(echo "$EVENT_LINE" | jq -e '.file == "src/api/handler.ts"' 2>/dev/null)
    HAS_SEVERITY=$(echo "$EVENT_LINE" | jq -e '.severity == "warn"' 2>/dev/null)
    HAS_DECISION=$(echo "$EVENT_LINE" | jq -e '.decision == "allow"' 2>/dev/null)
    if [ "$HAS_RULE" = "true" ] && [ "$HAS_FILE" = "true" ] && [ "$HAS_SEVERITY" = "true" ] && [ "$HAS_DECISION" = "true" ]; then
        echo "  PASS: event contains rule, file, severity, decision"
        ((PASS++)) || true
    else
        echo "  FAIL: event missing expected fields (got: $EVENT_LINE)"
        ((FAIL++)) || true
    fi
else
    echo "  FAIL: events.jsonl not found"
    ((FAIL++)) || true
fi

echo ""
echo "Test 9: /tmp constraint log is NOT written"
if ! ls /tmp/harness-constraint-log-* 2>/dev/null | grep -q .; then
    echo "  PASS: no /tmp constraint log created"
    ((PASS++)) || true
else
    echo "  FAIL: /tmp constraint log still exists"
    ((FAIL++)) || true
fi

# Cleanup
rm -rf "$TEST_DIR"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
