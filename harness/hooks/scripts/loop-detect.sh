#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Read all stdin
INPUT=$(cat)

# Only run if harness is active in this session (agent-written progress file exists)
SESSION_PREFIX=$(get_session_prefix "$INPUT")
CWD=$(get_field "$INPUT" ".cwd")
CWD=$(cd "$CWD" && pwd -P)
GIT_ROOT=$(get_git_root "$CWD")
PROGRESS_DIR="$GIT_ROOT/.claude/harness/progress"
HARNESS_ACTIVE=false
if [ -d "$PROGRESS_DIR" ]; then
    for f in "$PROGRESS_DIR"/*--"${SESSION_PREFIX}".md; do
        if [ -f "$f" ] && ! grep -q '<!-- harness-fallback -->' "$f" 2>/dev/null; then
            HARNESS_ACTIVE=true
            break
        fi
    done
fi
if [ "$HARNESS_ACTIVE" = false ]; then
    exit 0
fi
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
ENTRY=$(jq -cn \
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
        BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        emit_event "loop.detected" "$(jq -n -c --arg p "same-target" --arg t "$TOOL_NAME" --arg f "$FILE_PATH" --argjson c "$SAME_TARGET" '{pattern:$p,tool:$t,file:$f,count:$c}')"
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
        BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        emit_event "loop.detected" "$(jq -n -c --arg p "error-echo" --arg t "$TOOL_NAME" --arg f "$FILE_PATH" --arg e "$SHORT_ERR" --argjson c "$SAME_ERROR" '{pattern:$p,tool:$t,file:$f,error:$e,count:$c}')"
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
            . as $arr |
            reduce range(1; ($arr | length)) as $i (0;
                if (($arr[$i].tool == "Bash") and (($arr[$i].error | length) > 0) and
                    (($arr[$i - 1].tool == "Edit") or ($arr[$i - 1].tool == "Write")) and
                    (($arr[$i - 1].file | length) > 0))
                then . + 1
                else .
                end
            )
        ' 2>/dev/null || echo "0")
        if [ "$CYCLE_COUNT" -ge 3 ]; then
            BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
            emit_event "loop.detected" "$(jq -n -c --arg p "edit-test-fail" --arg t "Edit" --arg f "$FILE_PATH" --argjson c "$CYCLE_COUNT" '{pattern:$p,tool:$t,file:$f,count:$c}')"
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
