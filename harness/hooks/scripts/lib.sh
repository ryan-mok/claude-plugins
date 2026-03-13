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
