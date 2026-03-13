#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

INPUT=$(cat)

SESSION_PREFIX=$(get_session_prefix "$INPUT")
CWD=$(get_field "$INPUT" ".cwd")
TOOL_NAME=$(get_field "$INPUT" ".tool_name")
FILE_PATH=$(get_field "$INPUT" ".tool_input.file_path")

# Get file content based on tool type
if [ "$TOOL_NAME" = "Write" ]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // ""')
elif [ "$TOOL_NAME" = "Edit" ]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // ""')
else
    exit 0
fi

# Check for constraints file
CONSTRAINTS_FILE="$CWD/.claude/harness/constraints.json"
if [ ! -f "$CONSTRAINTS_FILE" ]; then
    exit 0
fi

# Make file path relative to CWD for glob matching
REL_PATH="${FILE_PATH#$CWD/}"

# Process rules
VIOLATIONS=""
MAX_SEVERITY="none"  # none < warn < block
LOG_FILE="/tmp/harness-constraint-log-${SESSION_PREFIX}.jsonl"

RULE_COUNT=$(jq '.rules | length' "$CONSTRAINTS_FILE")

for i in $(seq 0 $((RULE_COUNT - 1))); do
    RULE=$(jq ".rules[$i]" "$CONSTRAINTS_FILE")
    RULE_NAME=$(echo "$RULE" | jq -r '.name')
    RULE_TYPE=$(echo "$RULE" | jq -r '.type')
    RULE_DESC=$(echo "$RULE" | jq -r '.description')
    SEVERITY=$(echo "$RULE" | jq -r '.severity')

    # Get the glob pattern for file matching
    if [ "$RULE_TYPE" = "import-boundary" ]; then
        GLOB_PATTERN=$(echo "$RULE" | jq -r '.deny.from')
    else
        GLOB_PATTERN=$(echo "$RULE" | jq -r '.deny.in')
    fi

    # Check if file path matches glob (using bash pattern matching)
    # Convert glob to regex: ** -> .*, * -> [^/]*, ? -> .
    GLOB_REGEX=$(echo "$GLOB_PATTERN" | sed 's/\*\*/DOUBLESTAR/g' | sed 's/\*/[^\/]*/g' | sed 's/DOUBLESTAR/.*/g' | sed 's/?/./g')
    if ! echo "$REL_PATH" | grep -qE "^${GLOB_REGEX}$"; then
        continue
    fi

    # File matches this rule's glob — check content
    VIOLATED=false

    if [ "$RULE_TYPE" = "import-boundary" ]; then
        IMPORT_GLOB=$(echo "$RULE" | jq -r '.deny.import')
        IMPORT_REGEX=$(echo "$IMPORT_GLOB" | sed 's/\*\*/DOUBLESTAR/g' | sed 's/\*/[^\/]*/g' | sed 's/DOUBLESTAR/.*/g' | sed 's/?/./g')
        # Extract import paths from content
        IMPORTS=$(echo "$CONTENT" | grep -oE "(import .+ from ['\"]([^'\"]+)['\"]|require\(['\"]([^'\"]+)['\"]\))" | grep -oE "['\"][^'\"]+['\"]" | tr -d "'" | tr -d '"' || true)
        for imp in $IMPORTS; do
            if echo "$imp" | grep -qE "^${IMPORT_REGEX}"; then
                VIOLATED=true
                break
            fi
        done
    else
        # file-pattern or custom: grep for pattern in content
        PATTERN=$(echo "$RULE" | jq -r '.deny.pattern')
        if echo "$CONTENT" | grep -qE "$PATTERN"; then
            VIOLATED=true
        fi
    fi

    if [ "$VIOLATED" = true ]; then
        VIOLATIONS="${VIOLATIONS}${RULE_NAME}: ${RULE_DESC}\n"

        # Log violation
        TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        jq -n --arg name "$RULE_NAME" --arg file "$REL_PATH" --arg severity "$SEVERITY" --arg ts "$TIMESTAMP" \
            '{rule: $name, file: $file, severity: $severity, ts: $ts}' >> "$LOG_FILE"

        if [ "$SEVERITY" = "block" ]; then
            MAX_SEVERITY="block"
        elif [ "$MAX_SEVERITY" != "block" ]; then
            MAX_SEVERITY="warn"
        fi
    fi
done

# No violations — silent exit
if [ "$MAX_SEVERITY" = "none" ]; then
    exit 0
fi

# Build output
ESCAPED_VIOLATIONS=$(escape_for_json "CONSTRAINT VIOLATION(S):\n${VIOLATIONS}")

if [ "$MAX_SEVERITY" = "block" ]; then
    cat <<EOF
{
  "hookSpecificOutput": {
    "permissionDecision": "deny",
    "updatedInput": null
  },
  "systemMessage": "${ESCAPED_VIOLATIONS}"
}
EOF
else
    cat <<EOF
{
  "hookSpecificOutput": {
    "permissionDecision": "allow",
    "updatedInput": null
  },
  "systemMessage": "${ESCAPED_VIOLATIONS}"
}
EOF
fi

exit 0
