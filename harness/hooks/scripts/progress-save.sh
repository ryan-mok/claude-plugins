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
