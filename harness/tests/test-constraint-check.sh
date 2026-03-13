#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/scripts/constraint-check.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)

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

# Cleanup
rm -rf "$TEST_DIR" /tmp/harness-constraint-log-test1234.jsonl

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
