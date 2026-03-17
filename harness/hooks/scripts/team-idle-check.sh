#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

INPUT=$(cat)
export SESSION_PREFIX=$(get_session_prefix "$INPUT")
export CWD=$(get_field "$INPUT" ".cwd")
export BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

emit_event "team.agent_idle" "{}" "team"

exit 0
