#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

INPUT=$(cat)

SESSION_PREFIX=$(get_session_prefix "$INPUT")
CWD=$(get_field "$INPUT" ".cwd")
# Resolve symlinks for consistency (macOS /var -> /private/var)
CWD=$(cd "$CWD" && pwd -P)
EVENT=$(get_field "$INPUT" ".hook_event_name")

# Resolve to main git root (works across worktrees)
GIT_ROOT=$(get_git_root "$CWD")

# Determine progress directory (always at main repo root)
PROGRESS_DIR="$GIT_ROOT/.claude/harness/progress"

# If the progress directory doesn't exist, harness was never used in this project — exit silently
if [ ! -d "$PROGRESS_DIR" ]; then
    if [ "$EVENT" = "Stop" ]; then
        echo '{"decision": "approve"}'
    else
        echo "{}"
    fi
    exit 0
fi

# Get branch name
BRANCH=$(cd "$CWD" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
# Sanitize branch name for filename (replace / with -)
BRANCH_SAFE=$(echo "$BRANCH" | tr '/' '-')

PROGRESS_FILE="$PROGRESS_DIR/${BRANCH_SAFE}--${SESSION_PREFIX}.md"

# Check if the agent wrote a progress file for this session.
# Fallback files (created by this script) contain a marker — exclude those.
AGENT_WROTE_PROGRESS=false
if [ -f "$PROGRESS_FILE" ]; then
    if ! grep -q '<!-- harness-fallback -->' "$PROGRESS_FILE" 2>/dev/null; then
        AGENT_WROTE_PROGRESS=true
    fi
fi

# Check if the task is already marked complete
TASK_COMPLETE=false
if [ "$AGENT_WROTE_PROGRESS" = true ]; then
    # Check for explicit status markers on the same line
    if grep -qiE '## Status: COMPLETE|status to "Done"' "$PROGRESS_FILE" 2>/dev/null; then
        TASK_COMPLETE=true
    fi
    # Check if the line AFTER "## Current Status" contains complete/done
    if [ "$TASK_COMPLETE" = false ]; then
        STATUS_LINE=$(sed -n '/^## Current Status/{n;p;}' "$PROGRESS_FILE" 2>/dev/null | head -1)
        if echo "$STATUS_LINE" | grep -qiE 'complete|done'; then
            TASK_COMPLETE=true
        fi
    fi
fi

# Only create a fallback progress file if the agent wrote one (meaning harness was active)
# but it was for a different branch. Don't create fallbacks for sessions that never used harness.
if [ "$AGENT_WROTE_PROGRESS" = false ]; then
    # Check if this session has ANY progress file (agent may have written one on a different branch)
    SESSION_HAS_PROGRESS=false
    for f in "$PROGRESS_DIR"/*--"${SESSION_PREFIX}".md; do
        [ -f "$f" ] && SESSION_HAS_PROGRESS=true && break
    done

    if [ "$SESSION_HAS_PROGRESS" = false ]; then
        # Harness was not active in this session — skip fallback creation
        # Still clean up stale files and regenerate index
        :
    else
        # Session used harness on another branch, save fallback for current branch
        TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        RECENT_COMMITS=$(cd "$CWD" && git log --oneline -5 2>/dev/null || echo "(no commits)")
        CHANGED_FILES=$(cd "$CWD" && git diff --name-only HEAD 2>/dev/null || echo "(no changes)")

        cat > "$PROGRESS_FILE" << PROGRESS
<!-- harness-fallback -->
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
fi

# Clean up stale progress files (older than 7 days)
for f in "$PROGRESS_DIR"/*.md; do
    [ "$f" = "$PROGRESS_DIR/_index.md" ] && continue
    [ -f "$f" ] || continue
    FILE_AGE=$(( ( $(date +%s) - $(stat -f%m "$f" 2>/dev/null || stat -c%Y "$f" 2>/dev/null || echo "0") ) / 86400 ))
    if [ "$FILE_AGE" -ge 7 ]; then
        rm -f "$f"
    fi
done

# Regenerate _index.md
{
    echo "# Harness Progress Index"
    echo ""
    echo "Active sessions on this project:"
    echo ""
    HAS_ENTRIES=false
    for f in "$PROGRESS_DIR"/*.md; do
        [ "$f" = "$PROGRESS_DIR/_index.md" ] && continue
        [ -f "$f" ] || continue
        HAS_ENTRIES=true
        FNAME=$(basename "$f")
        UPDATED=$(grep -m1 '^\*\*Updated:\*\*' "$f" 2>/dev/null | sed 's/\*\*Updated:\*\* //' || echo "unknown")
        STATUS=$(sed -n '/^## Current Status/{n;p;}' "$f" 2>/dev/null | head -1 || echo "unknown")
        # Also check for non-standard status headers
        if [ "$STATUS" = "unknown" ] || [ -z "$STATUS" ]; then
            STATUS=$(grep -m1 '^## Status:' "$f" 2>/dev/null | sed 's/^## Status: //' || echo "unknown")
        fi
        echo "- **$FNAME** — $STATUS (updated: $UPDATED)"
    done
    if [ "$HAS_ENTRIES" = false ]; then
        echo "(no active sessions)"
    fi
} > "$PROGRESS_DIR/_index.md"

# Output based on event type
if [ "$EVENT" = "Stop" ]; then
    if [ "$TASK_COMPLETE" = true ]; then
        # Task already complete — no need to notify
        echo '{"decision": "approve"}'
    elif [ "$AGENT_WROTE_PROGRESS" = true ]; then
        echo "{\"decision\": \"approve\", \"reason\": \"Progress saved\", \"systemMessage\": \"Harness progress saved to $PROGRESS_FILE\"}"
    else
        # Harness wasn't active in this session — silent approve
        echo '{"decision": "approve"}'
    fi
else
    # PreCompact — no decision gate
    echo "{}"
fi

exit 0
