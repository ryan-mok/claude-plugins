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

# Only run for Bash tool
TOOL_NAME=$(get_field "$INPUT" ".tool_name")
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

COMMAND=$(get_field "$INPUT" ".tool_input.command // \"\"")
TOOL_RESULT=$(get_field "$INPUT" ".tool_result // \"\"")

if ! echo "$COMMAND" | grep -qiE "(test|jest|pytest|cargo test|go test|npm test|vitest|mocha|rspec)"; then
    exit 0
fi

if echo "$TOOL_RESULT" | grep -qiE "(error|fail|exception|FAIL)"; then
    exit 0
fi

# Rate limiting: max one checkpoint per 5 minutes
RATE_FILE="/tmp/harness-checkpoint-ts-${SESSION_PREFIX}"
if [ -f "$RATE_FILE" ]; then
    LAST_TS=$(tr -d '[:space:]' < "$RATE_FILE")
    NOW=$(date +%s)
    ELAPSED=$((NOW - LAST_TS))
    if [ "$ELAPSED" -lt 300 ]; then
        exit 0
    fi
fi

if [ -z "$(git -C "$CWD" status --porcelain 2>/dev/null)" ]; then
    exit 0
fi

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
STASH_HASH=$(git -C "$CWD" stash create 2>/dev/null || echo "")
if [ -z "$STASH_HASH" ]; then
    exit 0
fi

git -C "$CWD" stash store -m "harness-checkpoint: ${TIMESTAMP} — tests passing" "$STASH_HASH" 2>/dev/null || exit 0

date +%s > "$RATE_FILE"

BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
emit_event "checkpoint.created" "$(jq -n -c --arg hash "$STASH_HASH" '{trigger:"tests_passing",stash_hash:$hash}')"

exit 0
