#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

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

echo "$ENTRY" >> "$STATE_FILE"

# Keep only last 20 entries (rolling window)
TOTAL=$(wc -l < "$STATE_FILE" | tr -d ' ')
if [ "$TOTAL" -gt 20 ]; then
    tail -n 20 "$STATE_FILE" > "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
fi

# Lazy BRANCH resolution — only computed when emit_event is called
resolve_branch() {
    if [ -z "${BRANCH:-}" ]; then
        BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    fi
}

# === Budget Advisory ===
# Persistent counter (separate from rolling state file which caps at 20)
BUDGET_FILE="/tmp/harness-budget-${SESSION_PREFIX}"
if [ -f "$BUDGET_FILE" ]; then
    BUDGET_COUNT=$(tr -d '[:space:]' < "$BUDGET_FILE")
    # Default to 0 if file is empty or corrupted
    [[ "$BUDGET_COUNT" =~ ^[0-9]+$ ]] || BUDGET_COUNT=0
else
    BUDGET_COUNT=0
fi
BUDGET_COUNT=$((BUDGET_COUNT + 1))
echo "$BUDGET_COUNT" > "$BUDGET_FILE"

# Budget advisories fire exactly once per threshold (== not >=)
BUDGET_MSG=""
if [ "$BUDGET_COUNT" -eq 150 ]; then
    BUDGET_MSG="Budget critical: $BUDGET_COUNT tool calls in this session. Finish current work immediately and save progress."
    resolve_branch; emit_event "budget.advisory" "$(jq -n -c --argjson count "$BUDGET_COUNT" --arg level "critical" '{count:$count,level:$level}')"
elif [ "$BUDGET_COUNT" -eq 100 ]; then
    BUDGET_MSG="Budget warning: $BUDGET_COUNT tool calls in this session. Prioritize wrapping up current task."
    resolve_branch; emit_event "budget.advisory" "$(jq -n -c --argjson count "$BUDGET_COUNT" --arg level "warning" '{count:$count,level:$level}')"
elif [ "$BUDGET_COUNT" -eq 50 ]; then
    BUDGET_MSG="Budget advisory: $BUDGET_COUNT tool calls in this session. Stay focused on completing the current task."
    resolve_branch; emit_event "budget.advisory" "$(jq -n -c --argjson count "$BUDGET_COUNT" --arg level "advisory" '{count:$count,level:$level}')"
fi

if [ -n "$BUDGET_MSG" ]; then
    ESCAPED_BUDGET=$(escape_for_json "$BUDGET_MSG")
    cat <<EOF
{"systemMessage": "${ESCAPED_BUDGET}"}
EOF
    exit 0
fi

# Graduated loop response — level determines severity, exits the script.
# Level 1: advisory only (no event). Level 2-4: emit event + graduated message.
emit_loop_message() {
    local level="$1"
    local description="$2"
    local event_payload="$3"

    local msg=""
    if [ "$level" -eq 1 ]; then
        msg="Harness notice: $description Consider trying a different approach before this becomes a loop."
    elif [ "$level" -eq 2 ]; then
        resolve_branch; emit_event "loop.detected" "$event_payload"
        msg="LOOP DETECTED: $description STOP. Do not retry the same approach. Use the harness:loop-recovery skill to find a fundamentally different approach."
    elif [ "$level" -eq 3 ]; then
        resolve_branch; emit_event "loop.detected" "$event_payload"
        msg="LOOP DETECTED (escalated): $description You MUST stop working on this file/approach immediately. Read different files for context. The current strategy has fundamentally failed."
    elif [ "$level" -ge 4 ]; then
        resolve_branch; emit_event "loop.detected" "$event_payload"
        msg="LOOP DETECTED (circuit breaker): $description STOP ALL WORK on this file. Save progress immediately, document what was attempted and why it failed, and escalate to the user. Do not attempt any further fixes."
    fi

    local escaped_msg
    escaped_msg=$(escape_for_json "$msg")
    cat <<EOF
{"systemMessage": "${escaped_msg}"}
EOF
    exit 0
}

# === Evaluate all patterns and find the highest severity match ===
# Each pattern computes a level (0 = no match, 1-4 = escalation level).
# The pattern with the highest level fires. On ties, earlier patterns win.
BEST_LEVEL=0
BEST_DESC=""
BEST_PAYLOAD=""

# --- Pattern 1: Same tool + same file in last 10 ---
if [ -n "$FILE_PATH" ]; then
    SAME_TARGET=$(tail -n 10 "$STATE_FILE" | jq -r --arg tool "$TOOL_NAME" --arg file "$FILE_PATH" \
        'select(.tool == $tool and .file == $file) | .tool' | wc -l | tr -d ' ')
    P1_LEVEL=0
    if [ "$SAME_TARGET" -ge 8 ]; then P1_LEVEL=4
    elif [ "$SAME_TARGET" -ge 6 ]; then P1_LEVEL=3
    elif [ "$SAME_TARGET" -ge 4 ]; then P1_LEVEL=2
    elif [ "$SAME_TARGET" -ge 3 ]; then P1_LEVEL=1
    fi
    if [ "$P1_LEVEL" -gt "$BEST_LEVEL" ]; then
        BEST_LEVEL=$P1_LEVEL
        BEST_DESC="You have used $TOOL_NAME on $FILE_PATH $SAME_TARGET times in the last 10 tool calls."
        BEST_PAYLOAD=$(jq -n -c --arg p "same-target" --arg t "$TOOL_NAME" --arg f "$FILE_PATH" --argjson c "$SAME_TARGET" --argjson l "$P1_LEVEL" '{pattern:$p,tool:$t,file:$f,count:$c,level:$l}')
    fi
fi

# --- Pattern 2: Same error substring in last 10 ---
if [ -n "$ERROR_FP" ]; then
    SAME_ERROR=$(tail -n 10 "$STATE_FILE" | jq -r --arg fp "$ERROR_FP" 'select(.error | contains($fp)) | "match"' | wc -l | tr -d ' ')
    P2_LEVEL=0
    if [ "$SAME_ERROR" -ge 7 ]; then P2_LEVEL=4
    elif [ "$SAME_ERROR" -ge 5 ]; then P2_LEVEL=3
    elif [ "$SAME_ERROR" -ge 3 ]; then P2_LEVEL=2
    elif [ "$SAME_ERROR" -ge 2 ]; then P2_LEVEL=1
    fi
    if [ "$P2_LEVEL" -gt "$BEST_LEVEL" ]; then
        BEST_LEVEL=$P2_LEVEL
        SHORT_ERR=$(echo "$ERROR_FP" | head -c 60)
        BEST_DESC="The same error has appeared $SAME_ERROR times: \"$SHORT_ERR...\"."
        BEST_PAYLOAD=$(jq -n -c --arg p "error-echo" --arg t "$TOOL_NAME" --arg f "$FILE_PATH" --arg e "$SHORT_ERR" --argjson c "$SAME_ERROR" --argjson l "$P2_LEVEL" '{pattern:$p,tool:$t,file:$f,error:$e,count:$c,level:$l}')
    fi
fi

# --- Pattern 3: Edit-test-fail cycle in last 10 ---
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
        P3_LEVEL=0
        if [ "$CYCLE_COUNT" -ge 5 ]; then P3_LEVEL=4
        elif [ "$CYCLE_COUNT" -ge 4 ]; then P3_LEVEL=3
        elif [ "$CYCLE_COUNT" -ge 3 ]; then P3_LEVEL=2
        elif [ "$CYCLE_COUNT" -ge 2 ]; then P3_LEVEL=1
        fi
        if [ "$P3_LEVEL" -gt "$BEST_LEVEL" ]; then
            BEST_LEVEL=$P3_LEVEL
            BEST_DESC="Edit-test-fail cycle detected $CYCLE_COUNT times. The same fix approach is not working."
            BEST_PAYLOAD=$(jq -n -c --arg p "edit-test-fail" --arg t "Edit" --arg f "$FILE_PATH" --argjson c "$CYCLE_COUNT" --argjson l "$P3_LEVEL" '{pattern:$p,tool:$t,file:$f,count:$c,level:$l}')
        fi
    fi
fi

# Fire the highest-severity match, if any
if [ "$BEST_LEVEL" -gt 0 ]; then
    emit_loop_message "$BEST_LEVEL" "$BEST_DESC" "$BEST_PAYLOAD"
fi

# No loop detected — silent exit
exit 0
