#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

INPUT=$(cat)

SESSION_PREFIX=$(get_session_prefix "$INPUT")
CWD=$(get_field "$INPUT" ".cwd")
# Resolve symlinks for consistency (macOS /var -> /private/var)
CWD=$(cd "$CWD" && pwd -P)

# Resolve to main git root (works across worktrees)
GIT_ROOT=$(get_git_root "$CWD")

PROGRESS_DIR="$GIT_ROOT/.claude/harness/progress"

# No progress directory — nothing to load
if [ ! -d "$PROGRESS_DIR" ]; then
    exit 0
fi

# Get current branch name (from the actual working directory, not git root)
BRANCH=$(cd "$CWD" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
BRANCH_SAFE=$(echo "$BRANCH" | tr '/' '-')

CONTENT=""

# Priority 1: Exact session match — same branch, same session
for f in "$PROGRESS_DIR"/${BRANCH_SAFE}--${SESSION_PREFIX}.md; do
    if [ -f "$f" ]; then
        CONTENT=$(cat "$f")
        break
    fi
done

# Priority 2: Branch match — same branch, different session (most recent non-complete file)
if [ -z "$CONTENT" ]; then
    LATEST_FILE=""
    LATEST_MTIME=0
    for f in "$PROGRESS_DIR"/${BRANCH_SAFE}--*.md; do
        [ -f "$f" ] || continue
        # Skip complete tasks
        STATUS_LINE=$(sed -n '/^## Current Status/{n;p;}' "$f" 2>/dev/null | head -1)
        if echo "$STATUS_LINE" | grep -qiE 'complete|done' 2>/dev/null; then
            continue
        fi
        if grep -qiE '## Status: COMPLETE' "$f" 2>/dev/null; then
            continue
        fi
        # Pick the most recently modified file
        MTIME=$(stat -f%m "$f" 2>/dev/null || stat -c%Y "$f" 2>/dev/null || echo "0")
        if [ "$MTIME" -gt "$LATEST_MTIME" ]; then
            LATEST_MTIME=$MTIME
            LATEST_FILE="$f"
        fi
    done
    if [ -n "$LATEST_FILE" ]; then
        CONTENT=$(cat "$LATEST_FILE")
    fi
fi

# Priority 3: Fallback to _index.md
if [ -z "$CONTENT" ] && [ -f "$PROGRESS_DIR/_index.md" ]; then
    CONTENT=$(cat "$PROGRESS_DIR/_index.md")
fi

# Nothing to output
if [ -z "$CONTENT" ]; then
    exit 0
fi

# Output using hookSpecificOutput.additionalContext (SessionStart format)
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
