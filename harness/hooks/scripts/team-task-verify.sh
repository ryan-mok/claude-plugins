#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

INPUT=$(cat)
SESSION_PREFIX=$(get_session_prefix "$INPUT")
CWD=$(get_field "$INPUT" ".cwd")
CWD=$(cd "$CWD" 2>/dev/null && pwd -P || echo "$CWD")
BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

TASK_ID=$(get_field "$INPUT" ".task_id")
[[ -z "$TASK_ID" ]] && TASK_ID="unknown"
EVENTS_FILE="$(get_analytics_dir "$CWD")/events.jsonl"

# Compute advisory signals
RECENT_BLOCKED=0
RECENT_WARN=0
RECENT_LOOPS=0

if [[ -f "$EVENTS_FILE" ]]; then
  LAST_TC_TS=$(jq -s -r --arg branch "$BRANCH" \
      '[.[] | select(.event=="team.task_completed" and .branch==$branch)] | sort_by(.ts) | last | .ts // "1970-01-01T00:00:00Z"' "$EVENTS_FILE" 2>/dev/null)

  RECENT_BLOCKED=$(jq -r --arg branch "$BRANCH" --arg since "$LAST_TC_TS" \
      'select(.event=="constraint.violation" and .branch==$branch and .decision=="deny" and .ts > $since)' "$EVENTS_FILE" 2>/dev/null | wc -l | tr -d ' ')
  RECENT_WARN=$(jq -r --arg branch "$BRANCH" --arg since "$LAST_TC_TS" \
      'select(.event=="constraint.violation" and .branch==$branch and .decision=="allow" and .ts > $since)' "$EVENTS_FILE" 2>/dev/null | wc -l | tr -d ' ')
  RECENT_LOOPS=$(jq -r --arg branch "$BRANCH" --arg since "$LAST_TC_TS" \
      'select(.event=="loop.detected" and .branch==$branch and .ts > $since)' "$EVENTS_FILE" 2>/dev/null | wc -l | tr -d ' ')
fi

emit_event "team.task_completed" "$(jq -n -c \
  --arg tid "$TASK_ID" \
  --argjson rb "$RECENT_BLOCKED" \
  --argjson rw "$RECENT_WARN" \
  --argjson rl "$RECENT_LOOPS" \
  '{task_id:$tid, advisory_signals:{recent_blocked_violations:$rb, recent_warn_violations:$rw, recent_loops_on_branch:$rl}}'
)" "team"

exit 0
