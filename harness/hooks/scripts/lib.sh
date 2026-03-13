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
