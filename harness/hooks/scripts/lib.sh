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
    local analytics_dir
    analytics_dir=$(get_analytics_dir "$CWD")
    mkdir -p "$analytics_dir"

    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local wt=false
    if is_worktree "$CWD"; then
        wt=true
    fi

    local root
    root=$(get_git_root "$CWD")

    local envelope
    envelope=$(jq -n \
        --arg ts "$ts" \
        --arg event "$event_type" \
        --arg session_id "$SESSION_PREFIX" \
        --arg branch "$BRANCH" \
        --arg scope "$scope" \
        --argjson worktree "$wt" \
        --arg repo_root "$root" \
        '{ts: $ts, event: $event, session_id: $session_id, branch: $branch, scope: $scope, worktree: $worktree, repo_root: $repo_root}')

    local merged
    merged=$(echo "$envelope" | jq --argjson extra "$extra_fields" '. + $extra')

    echo "$merged" | jq -c '.' >> "$analytics_dir/events.jsonl"
}
