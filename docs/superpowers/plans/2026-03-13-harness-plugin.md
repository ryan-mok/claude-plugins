# Harness Plugin Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Claude Code plugin that wraps existing tools with autonomous runtime guardrails — loop detection, cross-session progress, architectural constraint enforcement, and an orchestration entry point.

**Architecture:** The plugin provides always-on hooks (PostToolUse, PreToolUse, SessionStart, Stop, PreCompact) that monitor agent behavior, plus skills that teach recovery/tracking patterns, plus commands that orchestrate the full workflow. All hook scripts are bash + jq, all skills/commands are markdown.

**Tech Stack:** Bash, jq, Claude Code plugin system (hooks.json, SKILL.md, command .md files)

**Spec:** `docs/superpowers/specs/2026-03-13-harness-plugin-design.md`

---

## File Structure

```
harness/
├── .claude-plugin/
│   └── plugin.json                    # Plugin manifest (name, description, metadata)
├── hooks/
│   ├── hooks.json                     # Hook event registrations
│   └── scripts/
│       ├── lib.sh                     # Shared utilities (JSON escape, session ID extraction)
│       ├── loop-detect.sh             # PostToolUse: track tool calls, detect loops
│       ├── progress-save.sh           # Stop + PreCompact: save progress snapshot
│       ├── progress-load.sh           # SessionStart: load progress into context
│       └── constraint-check.sh        # PreToolUse: enforce architectural constraints
├── skills/
│   ├── loop-recovery/
│   │   └── SKILL.md                   # Recovery strategies when loop detected
│   ├── progress-tracking/
│   │   └── SKILL.md                   # How to write effective progress entries
│   ├── constraint-setup/
│   │   └── SKILL.md                   # How to define project constraints
│   └── harness-orchestration/
│       └── SKILL.md                   # Full harness-aware development workflow
├── commands/
│   ├── harness.md                     # /harness entry point command
│   └── harness-status.md             # /harness-status diagnostic command
├── tests/
│   ├── test-loop-detect.sh            # Tests for loop detection hook
│   ├── test-progress-save.sh          # Tests for progress save hook
│   ├── test-progress-load.sh          # Tests for progress load hook
│   ├── test-constraint-check.sh       # Tests for constraint check hook
│   └── fixtures/                      # Test input JSON fixtures
│       ├── post-tool-use-edit.json
│       ├── post-tool-use-bash-fail.json
│       ├── pre-tool-use-write.json
│       ├── session-start.json
│       ├── stop.json
│       └── pre-compact.json
└── README.md
```

Note: `hooks/scripts/lib.sh` is added beyond the spec — it extracts shared utilities (JSON escaping, session ID prefix) to avoid duplication across 4 hook scripts. This follows DRY.

---

## Chunk 1: Plugin Scaffold + Loop Detection

### Task 1: Create plugin scaffold

**Files:**
- Create: `harness/.claude-plugin/plugin.json`
- Create: `harness/hooks/hooks.json`
- Create: `harness/hooks/scripts/lib.sh`

- [ ] **Step 1: Create directory structure**

```bash
cd ~/repos/claude-plugins
mkdir -p harness/.claude-plugin
mkdir -p harness/hooks/scripts
mkdir -p harness/skills/{loop-recovery,progress-tracking,constraint-setup,harness-orchestration}
mkdir -p harness/commands
mkdir -p harness/tests/fixtures
```

- [ ] **Step 2: Write plugin.json**

Create `harness/.claude-plugin/plugin.json`:

```json
{
  "name": "harness",
  "version": "1.0.0",
  "description": "Harness engineering for Claude Code — loop detection, cross-session progress, architectural constraints, and orchestrated development workflows.",
  "author": {
    "name": "Ryan Mok"
  },
  "license": "MIT",
  "keywords": ["harness", "guardrails", "loop-detection", "progress", "constraints"]
}
```

- [ ] **Step 3: Write hooks.json**

Create `harness/hooks/hooks.json` — this is the complete hooks registration copied from the spec:

```json
{
  "description": "Harness engineering guardrails: loop detection, progress persistence, constraint enforcement",
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/scripts/loop-detect.sh\"",
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/scripts/progress-save.sh\"",
            "timeout": 10
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/scripts/progress-save.sh\"",
            "timeout": 10
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/scripts/progress-load.sh\"",
            "timeout": 5
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/scripts/constraint-check.sh\"",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 4: Write shared library (lib.sh)**

Create `harness/hooks/scripts/lib.sh`:

```bash
#!/usr/bin/env bash
# Shared utilities for harness hook scripts

# JSON escape function — converts a string for safe embedding in JSON.
# Handles backslash, double-quote, newline, carriage return, tab.
# Follows the same pattern as superpowers' session-start hook.
escape_for_json() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Extract the first 8 characters of session_id from hook input JSON.
# Usage: SESSION_PREFIX=$(get_session_prefix "$INPUT")
get_session_prefix() {
    local input="$1"
    echo "$input" | jq -r '.session_id // ""' | cut -c1-8
}

# Extract a field from hook input JSON.
# Usage: TOOL_NAME=$(get_field "$INPUT" ".tool_name")
get_field() {
    local input="$1"
    local field="$2"
    echo "$input" | jq -r "$field // \"\""
}
```

- [ ] **Step 5: Make lib.sh executable and commit**

```bash
chmod +x harness/hooks/scripts/lib.sh
cd ~/repos/claude-plugins && git add harness/ && git commit -m "feat: scaffold harness plugin with plugin.json, hooks.json, and shared lib"
```

---

### Task 2: Write loop detection test fixtures

**Files:**
- Create: `harness/tests/fixtures/post-tool-use-edit.json`
- Create: `harness/tests/fixtures/post-tool-use-bash-fail.json`

- [ ] **Step 1: Create Edit fixture**

Create `harness/tests/fixtures/post-tool-use-edit.json`:

```json
{
  "session_id": "test1234-abcd-efgh-ijkl",
  "cwd": "/tmp/test-project",
  "hook_event_name": "PostToolUse",
  "tool_name": "Edit",
  "tool_input": {
    "file_path": "/tmp/test-project/src/handler.ts",
    "old_string": "old code",
    "new_string": "new code"
  },
  "tool_result": "File edited successfully"
}
```

- [ ] **Step 2: Create Bash fail fixture**

Create `harness/tests/fixtures/post-tool-use-bash-fail.json`:

```json
{
  "session_id": "test1234-abcd-efgh-ijkl",
  "cwd": "/tmp/test-project",
  "hook_event_name": "PostToolUse",
  "tool_name": "Bash",
  "tool_input": {
    "command": "npm test src/handler.test.ts"
  },
  "tool_result": "FAIL src/handler.test.ts\n  ● TypeError: Cannot read property 'id' of undefined"
}
```

- [ ] **Step 3: Commit fixtures**

```bash
cd ~/repos/claude-plugins && git add harness/tests/ && git commit -m "test: add PostToolUse test fixtures for loop detection"
```

---

### Task 3: Write loop detection tests

**Files:**
- Create: `harness/tests/test-loop-detect.sh`

- [ ] **Step 1: Write the test script**

Create `harness/tests/test-loop-detect.sh`:

```bash
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
        ((PASS++))
    else
        echo "  FAIL: $name (expected exit $expected, got $actual)"
        ((FAIL++))
    fi
}

assert_no_loop() {
    local name="$1" output="$2"
    if echo "$output" | grep -q "LOOP DETECTED"; then
        echo "  FAIL: $name (unexpected loop detected)"
        ((FAIL++))
    else
        echo "  PASS: $name (no loop)"
        ((PASS++))
    fi
}

assert_loop_detected() {
    local name="$1" output="$2"
    if echo "$output" | grep -q "LOOP DETECTED"; then
        echo "  PASS: $name (loop detected)"
        ((PASS++))
    else
        echo "  FAIL: $name (expected loop detection)"
        ((FAIL++))
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
    ((PASS++))
else
    echo "  FAIL: rolling window ($line_count lines > 20)"
    ((FAIL++))
fi

# Cleanup
rm -f "${STATE_PREFIX}.jsonl"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 2: Make test script executable**

```bash
chmod +x harness/tests/test-loop-detect.sh
```

- [ ] **Step 3: Run tests — verify they fail (loop-detect.sh doesn't exist yet)**

```bash
cd ~/repos/claude-plugins && bash harness/tests/test-loop-detect.sh
```

Expected: FAIL (script not found or empty)

- [ ] **Step 4: Commit**

```bash
cd ~/repos/claude-plugins && git add harness/tests/ && git commit -m "test: add loop detection tests (red — hook not implemented yet)"
```

---

### Task 4: Implement loop detection hook

**Files:**
- Create: `harness/hooks/scripts/loop-detect.sh`

- [ ] **Step 1: Write loop-detect.sh**

Create `harness/hooks/scripts/loop-detect.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Read all stdin
INPUT=$(cat)

# Extract fields
SESSION_PREFIX=$(get_session_prefix "$INPUT")
TOOL_NAME=$(get_field "$INPUT" ".tool_name")
FILE_PATH=$(get_field "$INPUT" ".tool_input.file_path // .tool_input.command // \"\"")
TOOL_RESULT=$(get_field "$INPUT" ".tool_result // \"\"")

# State file — ephemeral, per-session
STATE_FILE="/tmp/harness-loop-state-${SESSION_PREFIX}.jsonl"

# Extract error fingerprint (first 100 chars of result if it looks like an error)
ERROR_FP=""
if echo "$TOOL_RESULT" | grep -qiE "(error|fail|exception|undefined|cannot|not found)"; then
    ERROR_FP=$(echo "$TOOL_RESULT" | head -c 100)
fi

# Build fingerprint entry
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ENTRY=$(jq -n \
    --arg tool "$TOOL_NAME" \
    --arg file "$FILE_PATH" \
    --arg error "$ERROR_FP" \
    --arg ts "$TIMESTAMP" \
    '{tool: $tool, file: $file, error: $error, ts: $ts}')

# Append to state file
echo "$ENTRY" >> "$STATE_FILE"

# Keep only last 20 entries (rolling window)
if [ -f "$STATE_FILE" ]; then
    TOTAL=$(wc -l < "$STATE_FILE" | tr -d ' ')
    if [ "$TOTAL" -gt 20 ]; then
        TAIL_LINES=$((TOTAL - 20))
        tail -n 20 "$STATE_FILE" > "${STATE_FILE}.tmp"
        mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
fi

# === Detection Pattern 1: Same tool + same file, 4+ times in last 10 ===
if [ -n "$FILE_PATH" ] && [ "$FILE_PATH" != "" ]; then
    SAME_TARGET=$(tail -n 10 "$STATE_FILE" | jq -r --arg tool "$TOOL_NAME" --arg file "$FILE_PATH" \
        'select(.tool == $tool and .file == $file) | .tool' | wc -l | tr -d ' ')
    if [ "$SAME_TARGET" -ge 4 ]; then
        MSG="LOOP DETECTED: You have used $TOOL_NAME on $FILE_PATH $SAME_TARGET times in the last 10 tool calls. STOP. Do not retry the same approach. Use the harness:loop-recovery skill to find a fundamentally different approach."
        ESCAPED_MSG=$(escape_for_json "$MSG")
        cat <<EOF
{"systemMessage": "${ESCAPED_MSG}"}
EOF
        exit 0
    fi
fi

# === Detection Pattern 2: Same error substring, 3+ times in last 10 ===
if [ -n "$ERROR_FP" ]; then
    ESCAPED_ERROR=$(echo "$ERROR_FP" | sed 's/[]\/$*.^[]/\\&/g')
    SAME_ERROR=$(tail -n 10 "$STATE_FILE" | jq -r '.error' | grep -cF "$ERROR_FP" || true)
    if [ "$SAME_ERROR" -ge 3 ]; then
        SHORT_ERR=$(echo "$ERROR_FP" | head -c 60)
        MSG="LOOP DETECTED: The same error has appeared $SAME_ERROR times: \"$SHORT_ERR...\". STOP. Do not retry the same approach. Use the harness:loop-recovery skill to find a fundamentally different approach."
        ESCAPED_MSG=$(escape_for_json "$MSG")
        cat <<EOF
{"systemMessage": "${ESCAPED_MSG}"}
EOF
        exit 0
    fi
fi

# === Detection Pattern 3: Edit-test-fail cycle on same file, 3+ times ===
if [ "$TOOL_NAME" = "Bash" ] && [ -n "$ERROR_FP" ]; then
    COMMAND=$(get_field "$INPUT" ".tool_input.command // \"\"")
    if echo "$COMMAND" | grep -qiE "(test|jest|pytest|cargo test|go test|npm test|vitest|mocha|rspec)"; then
        # Count Edit/Write->failing Bash pairs on the same file in last 10 entries
        CYCLE_COUNT=$(tail -n 10 "$STATE_FILE" | jq -s '
            reduce range(1; length) as $i (0;
                if ((.[$i].tool == "Bash") and ((.[$i].error | length) > 0) and
                    ((.[($i - 1)].tool == "Edit") or (.[($i - 1)].tool == "Write")) and
                    ((.[($i - 1)].file | length) > 0))
                then . + 1
                else .
                end
            )
        ' 2>/dev/null || echo "0")
        if [ "$CYCLE_COUNT" -ge 3 ]; then
            MSG="LOOP DETECTED: Edit-test-fail cycle detected $CYCLE_COUNT times. STOP. The same fix approach is not working. Use the harness:loop-recovery skill to try a fundamentally different approach."
            ESCAPED_MSG=$(escape_for_json "$MSG")
            cat <<EOF
{"systemMessage": "${ESCAPED_MSG}"}
EOF
            exit 0
        fi
    fi
fi

# No loop detected — silent exit
exit 0
```

- [ ] **Step 2: Make executable**

```bash
chmod +x harness/hooks/scripts/loop-detect.sh
```

- [ ] **Step 3: Run tests — verify they pass**

```bash
cd ~/repos/claude-plugins && bash harness/tests/test-loop-detect.sh
```

Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
cd ~/repos/claude-plugins && git add harness/hooks/scripts/loop-detect.sh && git commit -m "feat: implement loop detection hook with 3 detection patterns"
```

---

### Task 5: Write loop-recovery skill

**Files:**
- Create: `harness/skills/loop-recovery/SKILL.md`

- [ ] **Step 1: Write SKILL.md**

Create `harness/skills/loop-recovery/SKILL.md`:

```markdown
---
name: loop-recovery
description: This skill should be used when a "LOOP DETECTED" message appears in context, when the agent has tried the same approach multiple times without success, when stuck in an edit-test-fail cycle, or when the harness loop detection hook fires. Provides structured recovery strategies to break out of repetitive failing patterns.
---

# Loop Recovery

When loop detection fires, the current approach is not working. Continuing to retry wastes tokens and produces broken output. Follow this structured recovery process.

## Recovery Process

### Step 1: Diagnose the loop

Identify and name:
- What was attempted (the specific approach, not just "I tried to fix it")
- Why it failed each time (the specific error or behavior)
- Whether the error changed between attempts or stayed identical

### Step 2: Generate alternatives

Identify at least 2 fundamentally different approaches. "Fundamentally different" means changing the strategy, not tweaking the same code:

- If editing a file repeatedly fails: read more of the surrounding code for context. The bug may be elsewhere.
- If a test keeps failing: question whether the test expectation is correct, or whether the test is testing the wrong thing.
- If an import/dependency is broken: check if the dependency exists, is installed, or has a different API than assumed.
- If a type error persists: re-read the type definitions rather than guessing at fixes.

### Step 3: Decide next action

Choose one of these paths:

1. **Try a different approach** — pick the most promising alternative from step 2 and implement it
2. **Revert and simplify** — use `/rewind` to go back to the last working state, then try a simpler solution
3. **Read more context** — the fix may require understanding code that hasn't been read yet. Read related files, type definitions, or documentation before attempting another fix.
4. **Escalate to the human** — if 2+ fundamentally different approaches have already been tried and failed, ask the user for guidance. Explain what was tried and why it failed.

### Step 4: Reset loop detection

After choosing a new approach, the loop detection state resets naturally as new tool calls with different patterns replace the old ones in the rolling window.

## Anti-patterns

- Do NOT retry the same approach with minor variations (changing variable names, reordering lines)
- Do NOT add more error handling around the same broken logic
- Do NOT suppress or ignore the error to make the test pass
- Do NOT skip the failing test and move on without fixing the underlying issue
```

- [ ] **Step 2: Validate SKILL.md format**

Check:
- Has `name` and `description` in frontmatter
- Description uses third-person ("This skill should be used when...")
- Body uses imperative form (not "you should")
- Under 2000 words

- [ ] **Step 3: Commit**

```bash
cd ~/repos/claude-plugins && git add harness/skills/loop-recovery/ && git commit -m "feat: add loop-recovery skill with structured recovery process"
```

---

## Chunk 2: Cross-Session Progress

### Task 6: Write progress test fixtures

**Files:**
- Create: `harness/tests/fixtures/stop.json`
- Create: `harness/tests/fixtures/pre-compact.json`
- Create: `harness/tests/fixtures/session-start.json`

- [ ] **Step 1: Create Stop fixture**

Create `harness/tests/fixtures/stop.json`:

```json
{
  "session_id": "test1234-abcd-efgh-ijkl",
  "cwd": "/tmp/test-project",
  "hook_event_name": "Stop",
  "stop_hook_reason": "end_turn"
}
```

- [ ] **Step 2: Create PreCompact fixture**

Create `harness/tests/fixtures/pre-compact.json`:

```json
{
  "session_id": "test1234-abcd-efgh-ijkl",
  "cwd": "/tmp/test-project",
  "hook_event_name": "PreCompact"
}
```

- [ ] **Step 3: Create SessionStart fixture**

Create `harness/tests/fixtures/session-start.json`:

```json
{
  "session_id": "test1234-abcd-efgh-ijkl",
  "cwd": "/tmp/test-project",
  "hook_event_name": "SessionStart"
}
```

- [ ] **Step 4: Commit**

```bash
cd ~/repos/claude-plugins && git add harness/tests/fixtures/ && git commit -m "test: add progress hook test fixtures"
```

---

### Task 7: Write progress-save tests

**Files:**
- Create: `harness/tests/test-progress-save.sh`

- [ ] **Step 1: Write the test script**

Create `harness/tests/test-progress-save.sh`:

```bash
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
        ((PASS++))
    else
        echo "  FAIL: $name (pattern '$pattern' not found in $file)"
        ((FAIL++))
    fi
}

assert_file_exists() {
    local name="$1" file="$2"
    if [ -f "$file" ]; then
        echo "  PASS: $name"
        ((PASS++))
    else
        echo "  FAIL: $name ($file not found)"
        ((FAIL++))
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
    ((PASS++))
else
    echo "  FAIL: Stop missing decision:approve (got: $output)"
    ((FAIL++))
fi

echo ""
echo "Test 3: PreCompact event — no decision field"
rm -rf "$PROGRESS_DIR"
output=$(jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/pre-compact.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
if echo "$output" | jq -e '.decision' > /dev/null 2>&1; then
    echo "  FAIL: PreCompact should not have decision field"
    ((FAIL++))
else
    echo "  PASS: PreCompact has no decision field"
    ((PASS++))
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
```

- [ ] **Step 2: Make executable and run — verify fails**

```bash
chmod +x harness/tests/test-progress-save.sh
cd ~/repos/claude-plugins && bash harness/tests/test-progress-save.sh
```

Expected: FAIL

- [ ] **Step 3: Commit**

```bash
cd ~/repos/claude-plugins && git add harness/tests/ && git commit -m "test: add progress-save tests (red)"
```

---

### Task 8: Implement progress-save hook

**Files:**
- Create: `harness/hooks/scripts/progress-save.sh`

- [ ] **Step 1: Write progress-save.sh**

Create `harness/hooks/scripts/progress-save.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

INPUT=$(cat)

SESSION_PREFIX=$(get_session_prefix "$INPUT")
CWD=$(get_field "$INPUT" ".cwd")
EVENT=$(get_field "$INPUT" ".hook_event_name")

# Determine progress directory
PROGRESS_DIR="$CWD/.claude/harness/progress"
mkdir -p "$PROGRESS_DIR"

# Get branch name
BRANCH=$(cd "$CWD" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
# Sanitize branch name for filename (replace / with -)
BRANCH_SAFE=$(echo "$BRANCH" | tr '/' '-')

PROGRESS_FILE="$PROGRESS_DIR/${BRANCH_SAFE}--${SESSION_PREFIX}.md"

# If agent already wrote a progress file, don't overwrite it
if [ ! -f "$PROGRESS_FILE" ]; then
    # Generate fallback from git
    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    RECENT_COMMITS=$(cd "$CWD" && git log --oneline -5 2>/dev/null || echo "(no commits)")
    CHANGED_FILES=$(cd "$CWD" && git diff --name-only HEAD 2>/dev/null || echo "(no changes)")

    cat > "$PROGRESS_FILE" << PROGRESS
# Harness Progress
**Updated:** $TIMESTAMP
**Branch:** $BRANCH
**Session:** $SESSION_PREFIX

## Current Status
Session ended — fallback snapshot from git.

## Recent Commits
$RECENT_COMMITS

## Changed Files
$CHANGED_FILES
PROGRESS
fi

# Regenerate _index.md
{
    echo "# Harness Progress Index"
    echo ""
    echo "Active sessions on this project:"
    echo ""
    for f in "$PROGRESS_DIR"/*.md; do
        [ "$f" = "$PROGRESS_DIR/_index.md" ] && continue
        [ -f "$f" ] || continue
        FNAME=$(basename "$f")
        UPDATED=$(grep -m1 '^\*\*Updated:\*\*' "$f" 2>/dev/null | sed 's/\*\*Updated:\*\* //' || echo "unknown")
        STATUS=$(sed -n '/^## Current Status/{n;p;}' "$f" 2>/dev/null | head -1 || echo "unknown")
        # Check staleness (7 days)
        STALE=""
        if command -v gdate > /dev/null 2>&1; then
            DATE_CMD="gdate"
        else
            DATE_CMD="date"
        fi
        FILE_AGE=$(( ( $(date +%s) - $(stat -f%m "$f" 2>/dev/null || stat -c%Y "$f" 2>/dev/null || echo "0") ) / 86400 ))
        if [ "$FILE_AGE" -ge 7 ]; then
            STALE=" (stale, ${FILE_AGE} days ago)"
        fi
        echo "- **$FNAME**$STALE — $STATUS (updated: $UPDATED)"
    done
} > "$PROGRESS_DIR/_index.md"

# Output based on event type
if [ "$EVENT" = "Stop" ]; then
    echo "{\"decision\": \"approve\", \"reason\": \"Progress saved\", \"systemMessage\": \"Harness progress saved to $PROGRESS_FILE\"}"
else
    # PreCompact — no decision gate
    echo "{}"
fi

exit 0
```

- [ ] **Step 2: Make executable**

```bash
chmod +x harness/hooks/scripts/progress-save.sh
```

- [ ] **Step 3: Run tests — verify they pass**

```bash
cd ~/repos/claude-plugins && bash harness/tests/test-progress-save.sh
```

Expected: All PASS

- [ ] **Step 4: Commit**

```bash
cd ~/repos/claude-plugins && git add harness/hooks/scripts/progress-save.sh && git commit -m "feat: implement progress-save hook with fallback and index generation"
```

---

### Task 9: Write progress-load tests

**Files:**
- Create: `harness/tests/test-progress-load.sh`

- [ ] **Step 1: Write test script**

Create `harness/tests/test-progress-load.sh`:

```bash
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
    ((PASS++))
else
    echo "  FAIL: unexpected output without progress dir"
    ((FAIL++))
fi

echo ""
echo "Test 2: Matching session file — loads it"
mkdir -p "$PROGRESS_DIR"
echo "# Test progress content" > "$PROGRESS_DIR/main--test1234.md"
output=$(jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/session-start.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
if echo "$output" | jq -e '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q "Test progress content"; then
    echo "  PASS: session file loaded"
    ((PASS++))
else
    echo "  FAIL: session file not loaded (got: $output)"
    ((FAIL++))
fi

echo ""
echo "Test 3: No matching session — loads _index.md"
rm -f "$PROGRESS_DIR/main--test1234.md"
echo "# Index content" > "$PROGRESS_DIR/_index.md"
output=$(jq --arg cwd "$TEST_DIR" '.cwd = $cwd' "$FIXTURES/session-start.json" | bash "$HOOK_SCRIPT" 2>&1 || true)
if echo "$output" | jq -e '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q "Index content"; then
    echo "  PASS: index loaded as fallback"
    ((PASS++))
else
    echo "  FAIL: index not loaded (got: $output)"
    ((FAIL++))
fi

# Cleanup
rm -rf "$TEST_DIR"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 2: Make executable and run — verify fails**

```bash
chmod +x harness/tests/test-progress-load.sh
cd ~/repos/claude-plugins && bash harness/tests/test-progress-load.sh
```

Expected: FAIL (progress-load.sh doesn't exist yet)

- [ ] **Step 3: Commit**

```bash
cd ~/repos/claude-plugins && git add harness/tests/test-progress-load.sh && git commit -m "test: add progress-load tests (red)"
```

---

### Task 9b: Implement progress-load hook

**Files:**
- Create: `harness/hooks/scripts/progress-load.sh`

- [ ] **Step 1: Write progress-load.sh**

Create `harness/hooks/scripts/progress-load.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

INPUT=$(cat)

SESSION_PREFIX=$(get_session_prefix "$INPUT")
CWD=$(get_field "$INPUT" ".cwd")

PROGRESS_DIR="$CWD/.claude/harness/progress"

# No progress directory — nothing to load
if [ ! -d "$PROGRESS_DIR" ]; then
    exit 0
fi

# Look for a progress file matching this session
CONTENT=""
for f in "$PROGRESS_DIR"/*--${SESSION_PREFIX}.md; do
    if [ -f "$f" ]; then
        CONTENT=$(cat "$f")
        break
    fi
done

# Fallback: load _index.md if no session-specific file found
if [ -z "$CONTENT" ] && [ -f "$PROGRESS_DIR/_index.md" ]; then
    CONTENT=$(cat "$PROGRESS_DIR/_index.md")
fi

# Nothing to output
if [ -z "$CONTENT" ]; then
    exit 0
fi

# Output using hookSpecificOutput.additionalContext (SessionStart format)
# Always use this format — it is the correct output for Claude Code plugin hooks.
ESCAPED=$(escape_for_json "$CONTENT")

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "${ESCAPED}"
  }
}
EOF

exit 0
```

- [ ] **Step 2: Make executable, run tests**

```bash
chmod +x harness/hooks/scripts/progress-load.sh
cd ~/repos/claude-plugins && bash harness/tests/test-progress-load.sh
```

Expected: All PASS

- [ ] **Step 3: Commit**

```bash
cd ~/repos/claude-plugins && git add harness/hooks/scripts/progress-load.sh && git commit -m "feat: implement progress-load hook with session matching and index fallback"
```

---

### Task 10: Write progress-tracking skill

**Files:**
- Create: `harness/skills/progress-tracking/SKILL.md`

- [ ] **Step 1: Write SKILL.md**

Create `harness/skills/progress-tracking/SKILL.md`:

```markdown
---
name: progress-tracking
description: This skill should be used when working on a long task that spans multiple tool calls, when context compaction is likely, when the harness orchestration skill is active, or when the agent needs to save progress for a future session to continue. Teaches how to write and maintain structured progress files that survive context compaction and session boundaries.
---

# Progress Tracking

Progress files bridge context boundaries — compaction events, session restarts, and multi-agent handoffs. The harness hooks handle loading progress on startup and saving a git-based fallback on exit. This skill teaches how to write rich, agent-maintained progress files that are far more useful than the fallback.

## When to Write Progress

Write or update the progress file at these natural milestones:
- After completing each step in an implementation plan
- After making a key decision that affects future work
- Before a known long-running operation (test suites, builds)
- When switching between different parts of a task

## Progress File Location

Write progress to: `.claude/harness/progress/{branch}--{session-prefix}.md`

To determine the file path:
- Branch: current git branch name with `/` replaced by `-`
- Session prefix: first 8 characters of the session ID (available in hook context, or use an arbitrary prefix if unknown)

## Progress File Format

Follow this structure exactly — the harness hooks parse specific headings:

```
# Harness Progress
**Updated:** {ISO 8601 timestamp}
**Branch:** {branch name}
**Session:** {session prefix}
**Objective:** {one-line description of the overall task}

## Current Status
{1-2 sentences describing what is happening right now}

## Completed
- [x] {completed item with enough detail to not need re-reading the code}
- [x] {another completed item}

## Next Steps
- [ ] {next thing to do, specific enough to act on}
- [ ] {following step}

## Key Decisions
- {decision made and WHY — the "why" is critical for a fresh context window}

## Key Files
- {path/to/important/file — helps a fresh context find relevant code fast}
```

## Writing Effective Progress

**Current Status:** Write what a developer picking up this task RIGHT NOW needs to know. Not what was done, but where things stand.

**Completed items:** Include enough detail that a fresh context does not need to re-read the implementation. "Implemented user auth" is bad. "Implemented JWT-based auth in src/auth/jwt.ts with refresh token rotation" is good.

**Key Decisions:** Always include WHY. "Using JSONL for state tracking" is incomplete. "Using JSONL for state tracking — fast append without needing to parse the full file, and jq can process it line-by-line" tells a fresh context why this choice was made and when to reconsider it.

**Next Steps:** Make these actionable. "Continue working on the feature" is useless. "Write tests for the constraint-check.sh glob matching logic" is actionable.

## Commit Alongside Progress

Commit early and often with descriptive messages. Git history is the most durable form of progress. The progress file supplements git with the semantic context that commit messages lack — why decisions were made, what the plan is, and what a fresh context needs to know.
```

- [ ] **Step 2: Validate SKILL.md format and commit**

```bash
cd ~/repos/claude-plugins && git add harness/skills/progress-tracking/ && git commit -m "feat: add progress-tracking skill"
```

---

## Chunk 3: Constraint Enforcement

### Task 11: Write constraint check test fixtures and tests

**Files:**
- Create: `harness/tests/fixtures/pre-tool-use-write.json`
- Create: `harness/tests/test-constraint-check.sh`

- [ ] **Step 1: Create Write fixture**

Create `harness/tests/fixtures/pre-tool-use-write.json`:

```json
{
  "session_id": "test1234-abcd-efgh-ijkl",
  "cwd": "/tmp/test-project",
  "hook_event_name": "PreToolUse",
  "tool_name": "Write",
  "tool_input": {
    "file_path": "/tmp/test-project/src/api/handler.ts",
    "content": "import { db } from 'src/data/db';\nconsole.log(process.env.API_KEY);\n"
  }
}
```

- [ ] **Step 2: Write test script**

Create `harness/tests/test-constraint-check.sh`:

```bash
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
    ((PASS++))
else
    echo "  FAIL: expected silent exit (got exit=$EXIT_CODE, output=$output)"
    ((FAIL++))
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
    ((PASS++))
else
    echo "  FAIL: expected silent exit for non-matching path"
    ((FAIL++))
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
    ((PASS++))
else
    echo "  FAIL: expected allow + warning (got: $output)"
    ((FAIL++))
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
    ((PASS++))
else
    echo "  FAIL: expected deny (got: $output)"
    ((FAIL++))
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
    ((PASS++))
else
    echo "  FAIL: expected deny for cross-layer import (got: $output)"
    ((FAIL++))
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
    ((PASS++))
else
    echo "  FAIL: expected silent allow (got: $output)"
    ((FAIL++))
fi

# Cleanup
rm -rf "$TEST_DIR" /tmp/harness-constraint-log-test1234.jsonl

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 3: Make executable, run tests — verify they fail**

```bash
chmod +x harness/tests/test-constraint-check.sh
cd ~/repos/claude-plugins && bash harness/tests/test-constraint-check.sh
```

Expected: FAIL

- [ ] **Step 4: Commit**

```bash
cd ~/repos/claude-plugins && git add harness/tests/ && git commit -m "test: add constraint check tests (red)"
```

---

### Task 12: Implement constraint-check hook

**Files:**
- Create: `harness/hooks/scripts/constraint-check.sh`

- [ ] **Step 1: Write constraint-check.sh**

Create `harness/hooks/scripts/constraint-check.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

INPUT=$(cat)

SESSION_PREFIX=$(get_session_prefix "$INPUT")
CWD=$(get_field "$INPUT" ".cwd")
TOOL_NAME=$(get_field "$INPUT" ".tool_name")
FILE_PATH=$(get_field "$INPUT" ".tool_input.file_path")

# Get file content based on tool type
if [ "$TOOL_NAME" = "Write" ]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // ""')
elif [ "$TOOL_NAME" = "Edit" ]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // ""')
else
    exit 0
fi

# Check for constraints file
CONSTRAINTS_FILE="$CWD/.claude/harness/constraints.json"
if [ ! -f "$CONSTRAINTS_FILE" ]; then
    exit 0
fi

# Make file path relative to CWD for glob matching
REL_PATH="${FILE_PATH#$CWD/}"

# Process rules
VIOLATIONS=""
MAX_SEVERITY="none"  # none < warn < block
LOG_FILE="/tmp/harness-constraint-log-${SESSION_PREFIX}.jsonl"

RULE_COUNT=$(jq '.rules | length' "$CONSTRAINTS_FILE")

for i in $(seq 0 $((RULE_COUNT - 1))); do
    RULE=$(jq ".rules[$i]" "$CONSTRAINTS_FILE")
    RULE_NAME=$(echo "$RULE" | jq -r '.name')
    RULE_TYPE=$(echo "$RULE" | jq -r '.type')
    RULE_DESC=$(echo "$RULE" | jq -r '.description')
    SEVERITY=$(echo "$RULE" | jq -r '.severity')

    # Get the glob pattern for file matching
    if [ "$RULE_TYPE" = "import-boundary" ]; then
        GLOB_PATTERN=$(echo "$RULE" | jq -r '.deny.from')
    else
        GLOB_PATTERN=$(echo "$RULE" | jq -r '.deny.in')
    fi

    # Check if file path matches glob (using bash pattern matching)
    # Convert glob to regex: ** -> .*, * -> [^/]*, ? -> .
    GLOB_REGEX=$(echo "$GLOB_PATTERN" | sed 's/\*\*/DOUBLESTAR/g' | sed 's/\*/[^\/]*/g' | sed 's/DOUBLESTAR/.*/g' | sed 's/?/./g')
    if ! echo "$REL_PATH" | grep -qE "^${GLOB_REGEX}$"; then
        continue
    fi

    # File matches this rule's glob — check content
    VIOLATED=false

    if [ "$RULE_TYPE" = "import-boundary" ]; then
        IMPORT_GLOB=$(echo "$RULE" | jq -r '.deny.import')
        IMPORT_REGEX=$(echo "$IMPORT_GLOB" | sed 's/\*\*/DOUBLESTAR/g' | sed 's/\*/[^\/]*/g' | sed 's/DOUBLESTAR/.*/g' | sed 's/?/./g')
        # Extract import paths from content
        IMPORTS=$(echo "$CONTENT" | grep -oE "(import .+ from ['\"]([^'\"]+)['\"]|require\(['\"]([^'\"]+)['\"]\))" | grep -oE "['\"][^'\"]+['\"]" | tr -d "'" | tr -d '"' || true)
        for imp in $IMPORTS; do
            if echo "$imp" | grep -qE "^${IMPORT_REGEX}"; then
                VIOLATED=true
                break
            fi
        done
    else
        # file-pattern or custom: grep for pattern in content
        PATTERN=$(echo "$RULE" | jq -r '.deny.pattern')
        if echo "$CONTENT" | grep -qE "$PATTERN"; then
            VIOLATED=true
        fi
    fi

    if [ "$VIOLATED" = true ]; then
        VIOLATIONS="${VIOLATIONS}${RULE_NAME}: ${RULE_DESC}\n"

        # Log violation
        TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        jq -n --arg name "$RULE_NAME" --arg file "$REL_PATH" --arg severity "$SEVERITY" --arg ts "$TIMESTAMP" \
            '{rule: $name, file: $file, severity: $severity, ts: $ts}' >> "$LOG_FILE"

        if [ "$SEVERITY" = "block" ]; then
            MAX_SEVERITY="block"
        elif [ "$MAX_SEVERITY" != "block" ]; then
            MAX_SEVERITY="warn"
        fi
    fi
done

# No violations — silent exit
if [ "$MAX_SEVERITY" = "none" ]; then
    exit 0
fi

# Build output
ESCAPED_VIOLATIONS=$(escape_for_json "CONSTRAINT VIOLATION(S):\n${VIOLATIONS}")

if [ "$MAX_SEVERITY" = "block" ]; then
    cat <<EOF
{
  "hookSpecificOutput": {
    "permissionDecision": "deny",
    "updatedInput": null
  },
  "systemMessage": "${ESCAPED_VIOLATIONS}"
}
EOF
else
    cat <<EOF
{
  "hookSpecificOutput": {
    "permissionDecision": "allow",
    "updatedInput": null
  },
  "systemMessage": "${ESCAPED_VIOLATIONS}"
}
EOF
fi

exit 0
```

- [ ] **Step 2: Make executable**

```bash
chmod +x harness/hooks/scripts/constraint-check.sh
```

- [ ] **Step 3: Run tests — verify they pass**

```bash
cd ~/repos/claude-plugins && bash harness/tests/test-constraint-check.sh
```

Expected: All PASS

- [ ] **Step 4: Commit**

```bash
cd ~/repos/claude-plugins && git add harness/hooks/scripts/constraint-check.sh && git commit -m "feat: implement constraint-check hook with glob matching and violation logging"
```

---

### Task 13: Write constraint-setup skill

**Files:**
- Create: `harness/skills/constraint-setup/SKILL.md`

- [ ] **Step 1: Write SKILL.md**

Create `harness/skills/constraint-setup/SKILL.md`:

```markdown
---
name: constraint-setup
description: This skill should be used when the user asks to "set up constraints", "add architectural rules", "enforce module boundaries", "create constraints.json", "configure import restrictions", or wants to define project-specific architectural constraints for the harness plugin. Guides creation and maintenance of the .claude/harness/constraints.json configuration file.
---

# Constraint Setup

The harness plugin enforces architectural constraints via a PreToolUse hook that checks every Write and Edit operation against rules defined in `.claude/harness/constraints.json`. This skill teaches how to define effective constraint rules.

## Constraint File Location

Create the file at: `.claude/harness/constraints.json`

This file should be committed to the repository so all team members share the same constraints.

## Rule Types

### import-boundary

Prevents one module from importing another. Use for enforcing layered architecture.

```json
{
  "name": "descriptive-rule-name",
  "type": "import-boundary",
  "description": "Human-readable explanation shown on violation",
  "deny": {
    "from": "src/api/**",
    "import": "src/data/**"
  },
  "severity": "block"
}
```

- `from`: glob pattern matching source file paths that should NOT contain the import
- `import`: glob pattern matching imported module paths that are forbidden
- Extracts `import ... from '...'` and `require('...')` statements from file content

### file-pattern

Prevents specific patterns from appearing in files matching a glob. Use for banning dangerous APIs or enforcing coding standards.

```json
{
  "name": "no-env-in-source",
  "type": "file-pattern",
  "description": "Source files must not read env vars directly — use config module",
  "deny": {
    "in": "src/**",
    "pattern": "process\\.env\\."
  },
  "severity": "warn"
}
```

- `in`: glob pattern matching file paths to check
- `pattern`: regex (extended grep) matched against file content

### custom

Identical to file-pattern. Use for project-specific rules that don't fit the other categories.

## Severity Levels

- **block** — prevents the write entirely. Use for rules that must never be violated (security boundaries, critical architectural invariants).
- **warn** — allows the write but injects a warning into context. Use for guidelines that have legitimate exceptions.

## Defining Good Constraints

### Start with boundaries that already exist

Analyze the codebase to identify architectural layers and module boundaries that are already respected by convention. Turn these into constraints to prevent drift.

### Keep the rule count low

Start with 3-5 critical rules. Too many constraints create friction and false positives. Add rules only when a real violation occurs or when a boundary is critical enough to enforce.

### Write clear descriptions

The description appears in violation messages. Make it explain both WHAT is wrong and WHY, so the agent can self-correct:
- Good: "API layer must not import from data layer directly — use the service layer for data access"
- Bad: "Import not allowed"

### Use warn before block

Start new rules with `warn` severity. Observe whether they trigger correctly before upgrading to `block`. This prevents false positives from blocking legitimate work.

## Checking Constraint Status

Run `/harness-status --constraints` to see all loaded rules and recent violation history.
```

- [ ] **Step 2: Validate and commit**

```bash
cd ~/repos/claude-plugins && git add harness/skills/constraint-setup/ && git commit -m "feat: add constraint-setup skill"
```

---

## Chunk 4: Commands, Orchestration Skill, and README

### Task 14: Write /harness command

**Files:**
- Create: `harness/commands/harness.md`

- [ ] **Step 1: Write harness.md**

Create `harness/commands/harness.md`:

```markdown
---
description: Start a harness-guided development cycle
argument-hint: [task description or JIRA-ID]
---

Start a harness-guided development cycle for the given task.

Input: $ARGUMENTS

## Step 1: Identify task type

Check if the input matches a Jira ticket ID pattern (uppercase letters followed by a hyphen and digits, e.g., PROJ-1234). If the atlassian plugin skills are available, use the atlassian:triage-issue or atlassian:search-company-knowledge skill to pull the ticket's description, acceptance criteria, and comments. If the atlassian plugin is not available, treat the ticket ID as a text label and proceed.

If no input was provided, ask what the user wants to work on before proceeding.

## Step 2: Initialize progress

Create the harness progress file at `.claude/harness/progress/{branch}--{session-prefix}.md` following the format from the harness:progress-tracking skill. Record the task objective.

Ensure `.claude/harness/progress/` is in `.gitignore`.

## Step 3: Check constraints

If `.claude/harness/constraints.json` exists, note how many rules are loaded. If it does not exist, mention that no architectural constraints are configured and the user can set them up with the harness:constraint-setup skill.

## Step 4: Hand off to superpowers

Invoke the superpowers:brainstorming skill with the gathered task context. The superpowers workflow will take over from here: brainstorming → writing-plans → executing-plans → verification → code review → finishing the branch.

Throughout the workflow, maintain harness awareness per the harness:harness-orchestration skill: save progress at phase transitions, follow loop-recovery if loop detection fires, and invoke the simplify skill on changed files after execution completes.
```

- [ ] **Step 2: Commit**

```bash
cd ~/repos/claude-plugins && git add harness/commands/harness.md && git commit -m "feat: add /harness command entry point"
```

---

### Task 15: Write /harness-status command

**Files:**
- Create: `harness/commands/harness-status.md`

- [ ] **Step 1: Write harness-status.md**

Create `harness/commands/harness-status.md`:

```markdown
---
description: Show harness status (loop detection, progress, constraints)
argument-hint: [--progress | --constraints | --reset-loops]
allowed-tools: Read, Bash(cat:*,ls:*,wc:*,jq:*,head:*,find:*,rm:*)
---

Assemble and display the current harness status by reading state files. Check if `jq` is available on the system PATH first — if not, warn the user that harness hooks require jq.

Flag: $ARGUMENTS

## Loop Detection

Find the loop detection state file at `/tmp/harness-loop-state-*.jsonl` for the current project. Report:
- How many tool calls are tracked (line count of the JSONL file)
- How many loops were detected this session (count entries where the hook output a systemMessage — these are logged in the transcript, so just count JSONL entries and report the state file path)

If `$ARGUMENTS` contains `--reset-loops`, delete the loop state file and confirm reset.

## Progress

Read `.claude/harness/progress/_index.md` if it exists. Report:
- Last saved timestamp
- Current branch
- Number of active sessions
- List each session with staleness indication

If `$ARGUMENTS` contains `--progress`, also read and display the full contents of the current session's progress file.

## Constraints

If `.claude/harness/constraints.json` exists, report how many rules are loaded. Check `/tmp/harness-constraint-log-*.jsonl` for violation history this session.

If `$ARGUMENTS` contains `--constraints`, display all rules from the constraints file.

## Format

Present the output as a clean markdown summary matching this structure:

```
## Harness Status

### Loop Detection
State: Active/Inactive
Recent tool calls tracked: N
State file: /tmp/harness-loop-state-XXXX.jsonl

### Progress
Last saved: TIMESTAMP
Branch: BRANCH
Active sessions: N

### Constraints
Rules loaded: N
Violations blocked: N
Warnings issued: N
```
```

- [ ] **Step 2: Commit**

```bash
cd ~/repos/claude-plugins && git add harness/commands/harness-status.md && git commit -m "feat: add /harness-status diagnostic command"
```

---

### Task 16: Write harness-orchestration skill

**Files:**
- Create: `harness/skills/harness-orchestration/SKILL.md`

- [ ] **Step 1: Write SKILL.md**

Create `harness/skills/harness-orchestration/SKILL.md`:

```markdown
---
name: harness-orchestration
description: This skill should be used when the /harness command is invoked, when maintaining harness awareness throughout a superpowers workflow, when transitioning between workflow phases (brainstorming to planning to execution), or when the agent needs guidance on progress tracking during multi-phase development. Teaches how to maintain harness guardrails throughout the full superpowers development lifecycle.
---

# Harness Orchestration

This skill maintains harness awareness throughout the superpowers workflow. The hooks (loop detection, constraint enforcement, progress save/load) are always-on and require no manual intervention. This skill covers the agent's responsibilities at each phase transition.

## Phase Transition Responsibilities

### After brainstorming completes

- Update the progress file: set Current Status to "Design approved, moving to planning"
- Record key design decisions in the Key Decisions section
- Invoke the superpowers:writing-plans skill

### After plan is written

- Update the progress file: set Current Status to "Plan written, ready to execute"
- Add plan file path to Key Files
- Invoke superpowers:executing-plans (or superpowers:subagent-driven-development if subagents are available)

### During execution (between tasks)

- Update the progress file after each completed task
- Move completed items from Next Steps to Completed
- If loop detection fires (a "LOOP DETECTED" systemMessage appears), immediately invoke the harness:loop-recovery skill before continuing

### After execution completes

- Update progress: "Implementation complete, verifying"
- Invoke superpowers:verification-before-completion
- If the code-simplifier plugin's simplify skill is available, invoke it on the files that were changed during execution
- Invoke superpowers:requesting-code-review

### After code review

- Update progress: "Code review complete, finishing branch"
- Invoke superpowers:finishing-a-development-branch
- Update progress file status to "Done"
- If the task originated from a Jira ticket and the atlassian plugin is available, update the ticket status

## Interacting with Harness Hooks

The hooks fire automatically. The agent's responsibility is:

- **Loop detection (PostToolUse):** If a "LOOP DETECTED" message appears in context, stop current work and follow the harness:loop-recovery skill. Do not ignore it.
- **Constraint enforcement (PreToolUse):** If a write is denied, read the constraint description and find an alternative approach that respects the boundary. Do not attempt to bypass constraints.
- **Progress save (Stop/PreCompact):** The hook saves a fallback automatically, but agent-written progress is more useful. Proactively write progress before long operations.
- **Progress load (SessionStart):** Progress from prior sessions appears in context automatically. Read it and continue from where the prior session left off.

## Graceful Degradation

- If superpowers is not installed: the hooks still work, but the orchestration flow cannot invoke superpowers skills. Inform the user and suggest installing superpowers.
- If atlassian plugin is not installed: skip Jira integration silently. Treat ticket IDs as text labels.
- If code-simplifier is not installed: skip the simplify step after execution.
```

- [ ] **Step 2: Validate and commit**

```bash
cd ~/repos/claude-plugins && git add harness/skills/harness-orchestration/ && git commit -m "feat: add harness-orchestration skill for phase transition management"
```

---

### Task 17: Write README

**Files:**
- Create: `harness/README.md`

- [ ] **Step 1: Write README.md**

Create `harness/README.md`:

```markdown
# Harness

Harness engineering for Claude Code. Wraps existing tools and the superpowers workflow with autonomous runtime guardrails.

## What it does

- **Loop Detection** — Detects when the agent is stuck retrying the same failing approach and forces a different strategy
- **Cross-Session Progress** — Saves and restores task progress across context compaction and session boundaries
- **Constraint Enforcement** — Blocks writes that violate architectural boundaries defined in your project
- **Orchestration** — `/harness` command runs the full development cycle with harness awareness

## Installation

```bash
/plugin install harness
```

## Quick Start

```
/harness Fix the login timeout bug
```

This kicks off the full harness-guided workflow: brainstorming → planning → execution → verification → review.

## Commands

- `/harness [task]` — Start a harness-guided development cycle
- `/harness-status` — Show harness status (loop detection, progress, constraints)

## Setting Up Constraints

Create `.claude/harness/constraints.json` in your project:

```json
{
  "rules": [
    {
      "name": "no-cross-layer-imports",
      "type": "import-boundary",
      "description": "API layer must not import from data layer",
      "deny": { "from": "src/api/**", "import": "src/data/**" },
      "severity": "block"
    }
  ]
}
```

## Requirements

- `jq` (for hook scripts)
- superpowers plugin (for `/harness` orchestration)

## Optional Integrations

- atlassian plugin — pull Jira ticket context
- code-simplifier plugin — auto-simplify after execution
- pr-review-toolkit plugin — enhanced code review
```

- [ ] **Step 2: Commit**

```bash
cd ~/repos/claude-plugins && git add harness/README.md && git commit -m "docs: add README with installation and usage instructions"
```

---

### Task 18: Run all tests and final validation

- [ ] **Step 1: Run all test suites**

```bash
cd ~/repos/claude-plugins
echo "=== Loop Detection ===" && bash harness/tests/test-loop-detect.sh
echo "" && echo "=== Progress Save ===" && bash harness/tests/test-progress-save.sh
echo "" && echo "=== Progress Load ===" && bash harness/tests/test-progress-load.sh
echo "" && echo "=== Constraint Check ===" && bash harness/tests/test-constraint-check.sh
```

Expected: All suites PASS

- [ ] **Step 2: Validate plugin structure**

```bash
# Check all required files exist
test -f harness/.claude-plugin/plugin.json && echo "OK: plugin.json"
test -f harness/hooks/hooks.json && echo "OK: hooks.json"
test -f harness/hooks/scripts/lib.sh && echo "OK: lib.sh"
test -f harness/hooks/scripts/loop-detect.sh && echo "OK: loop-detect.sh"
test -f harness/hooks/scripts/progress-save.sh && echo "OK: progress-save.sh"
test -f harness/hooks/scripts/progress-load.sh && echo "OK: progress-load.sh"
test -f harness/hooks/scripts/constraint-check.sh && echo "OK: constraint-check.sh"
test -f harness/skills/loop-recovery/SKILL.md && echo "OK: loop-recovery skill"
test -f harness/skills/progress-tracking/SKILL.md && echo "OK: progress-tracking skill"
test -f harness/skills/constraint-setup/SKILL.md && echo "OK: constraint-setup skill"
test -f harness/skills/harness-orchestration/SKILL.md && echo "OK: harness-orchestration skill"
test -f harness/commands/harness.md && echo "OK: /harness command"
test -f harness/commands/harness-status.md && echo "OK: /harness-status command"
test -f harness/README.md && echo "OK: README"
```

- [ ] **Step 3: Validate SKILL.md frontmatter**

```bash
for skill in harness/skills/*/SKILL.md; do
    echo "--- $skill ---"
    head -5 "$skill"
    echo ""
done
```

Check each skill has `name` and `description` in frontmatter, description uses third-person.

- [ ] **Step 4: Final commit**

```bash
cd ~/repos/claude-plugins && git add -A && git status
```

If there are unstaged changes, commit them. Otherwise, the plugin is complete.
