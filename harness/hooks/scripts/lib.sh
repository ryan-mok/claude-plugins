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

# Resolve the main git repository root, even when running inside a worktree.
# In a regular repo, this returns the repo root.
# In a worktree, this returns the main repo root (not the worktree directory).
# Usage: GIT_ROOT=$(get_git_root "$CWD")
get_git_root() {
    local cwd="$1"
    # Get the common git dir (shared across all worktrees)
    local git_common_dir
    git_common_dir=$(cd "$cwd" && git rev-parse --git-common-dir 2>/dev/null) || { echo "$cwd"; return; }

    local result
    # If it's just ".git", we're in the main repo — use --show-toplevel
    if [ "$git_common_dir" = ".git" ]; then
        result=$(cd "$cwd" && git rev-parse --show-toplevel 2>/dev/null) || { echo "$cwd"; return; }
    else
        # In a worktree, --git-common-dir points to /path/to/main-repo/.git
        # Resolve to absolute path then go up one level
        local abs_git_dir
        abs_git_dir=$(cd "$cwd" && cd "$git_common_dir" && pwd)
        result=$(dirname "$abs_git_dir")
    fi

    # Resolve symlinks for consistency (macOS /var -> /private/var)
    if [ -d "$result" ]; then
        result=$(cd "$result" && pwd -P)
    fi
    echo "$result"
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

# Return the analytics directory path under the main repo root.
# Usage: ANALYTICS_DIR=$(get_analytics_dir "$CWD")
get_analytics_dir() {
    local cwd="${1:-$CWD}"
    local root
    root=$(get_git_root "$cwd")
    echo "$root/.claude/harness/analytics"
}

# Return true (exit 0) if running in a git worktree, false (exit 1) otherwise.
# Compares git show-toplevel with the main repo root from get_git_root.
# Usage: if is_worktree "$CWD"; then ...
is_worktree() {
    local cwd="${1:-$CWD}"
    local toplevel
    toplevel=$(cd "$cwd" && git rev-parse --show-toplevel 2>/dev/null) || return 1
    # Resolve symlinks for consistent comparison
    if [ -d "$toplevel" ]; then
        toplevel=$(cd "$toplevel" && pwd -P)
    fi
    local root
    root=$(get_git_root "$cwd")
    [ "$toplevel" != "$root" ]
}

# Append an analytics event to events.jsonl.
# Requires CWD, SESSION_PREFIX, BRANCH to be set by caller.
# Usage: emit_event "session.start" '{"extra":"data"}' "single"
emit_event() {
    local event_type="$1"
    local extra_fields="${2:-"{}"}"
    local scope="${3:-single}"

    # Cache git root — called once instead of 3 times
    local git_root
    git_root=$(get_git_root "$CWD")
    local analytics_dir="$git_root/.claude/harness/analytics"
    mkdir -p "$analytics_dir"

    local ts repo_root worktree_val
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    repo_root="$git_root"

    # Inline worktree check using cached git_root
    local toplevel
    toplevel=$(cd "$CWD" && git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -n "$toplevel" && "$toplevel" != "$git_root" ]]; then
        worktree_val="true"
    else
        worktree_val="false"
    fi

    # Single jq call for envelope + merge
    local merged
    merged=$(jq -n -c \
        --arg ts "$ts" \
        --arg event "$event_type" \
        --arg sid "${SESSION_PREFIX:-unknown}" \
        --arg branch "${BRANCH:-unknown}" \
        --arg scope "$scope" \
        --arg repo "$repo_root" \
        --argjson wt "$worktree_val" \
        --argjson extra "$extra_fields" \
        '{ts:$ts, event:$event, session_id:$sid, branch:$branch, scope:$scope, worktree:$wt, repo_root:$repo} + $extra'
    )

    echo "$merged" >> "$analytics_dir/events.jsonl"
}
