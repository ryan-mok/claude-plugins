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
