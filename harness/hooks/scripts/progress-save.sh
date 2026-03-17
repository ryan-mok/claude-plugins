#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- compute_session_end: heuristic-based session.end emission ---
# Called from the Stop event path after fallback/cleanup/index logic.
# Reads progress file, events.jsonl, and loop state to derive outcome.
compute_session_end() {
    local progress_file="$1"
    local events_file
    events_file="$(get_analytics_dir "$CWD")/events.jsonl"
    local loop_state_file="/tmp/harness-loop-state-${SESSION_PREFIX}.jsonl"

    # --- 1. Start gh pr list in background (8s timeout) ---
    local gh_pid=""
    local gh_result_file
    gh_result_file=$(mktemp)
    if command -v gh >/dev/null 2>&1; then
        ( timeout 8 gh pr list --head "$BRANCH" --state open --limit 1 --json number 2>/dev/null || echo "TIMEOUT" ) > "$gh_result_file" &
        gh_pid=$!
    else
        echo "NO_GH" > "$gh_result_file"
    fi

    # --- 2. Read progress file ---
    local agent_outcome="unknown"
    local mode="organic"
    local semantic_blocks=0
    local progress_marked_complete="false"

    if [ -f "$progress_file" ]; then
        # agent_outcome: first word after ## Agent Outcome heading
        local outcome_line
        outcome_line=$(sed -n '/^## Agent Outcome/{n;p;}' "$progress_file" 2>/dev/null | head -1)
        if [ -n "$outcome_line" ]; then
            local first_word
            first_word=$(echo "$outcome_line" | awk '{print tolower($1)}')
            case "$first_word" in
                success|partial|failed|abandoned) agent_outcome="$first_word" ;;
            esac
        fi

        # mode: from YAML frontmatter
        local yaml_mode
        yaml_mode=$(sed -n '/^---$/,/^---$/{ s/^mode: *//p; }' "$progress_file" 2>/dev/null)
        if [ -n "$yaml_mode" ]; then
            mode="$yaml_mode"
        fi

        # semantic_blocks: count lines starting with "- [" in ## Semantic Constraint Notes
        semantic_blocks=$(sed -n '/^## Semantic Constraint Notes/,/^## /{/^- \[/p;}' "$progress_file" 2>/dev/null | wc -l | tr -d ' ')

        # progress_marked_complete: reuse TASK_COMPLETE which is already computed
        if [ "$TASK_COMPLETE" = true ]; then
            progress_marked_complete="true"
        fi
    fi

    # --- 3. Read events.jsonl for counts ---
    local loop_count=0
    local total_violations=0
    local constraint_violations_blocked=0
    local compaction_count=0

    if [ -f "$events_file" ]; then
        loop_count=$(jq -r --arg sid "$SESSION_PREFIX" \
            'select(.event=="loop.detected" and .session_id==$sid) | .event' \
            "$events_file" 2>/dev/null | wc -l | tr -d ' ')
        total_violations=$(jq -r --arg sid "$SESSION_PREFIX" \
            'select(.event=="constraint.violation" and .session_id==$sid) | .event' \
            "$events_file" 2>/dev/null | wc -l | tr -d ' ')
        constraint_violations_blocked=$(jq -r --arg sid "$SESSION_PREFIX" \
            'select(.event=="constraint.violation" and .session_id==$sid and .decision=="deny") | .event' \
            "$events_file" 2>/dev/null | wc -l | tr -d ' ')
        compaction_count=$(jq -r --arg sid "$SESSION_PREFIX" \
            'select(.event=="session.compact" and .session_id==$sid) | .event' \
            "$events_file" 2>/dev/null | wc -l | tr -d ' ')
    fi

    # --- 4. Read loop state file ---
    local tests_passing="null"
    local unresolved_loops=0

    if [ -f "$loop_state_file" ]; then
        # tests_passing: find last Bash entry matching test runner, check error field
        local last_test_entry
        last_test_entry=$(jq -s '[.[] | select(.tool=="Bash" and (.file | test("test|jest|pytest|cargo.test|go.test|npm.test|vitest|mocha|rspec"; "i")))] | last' "$loop_state_file" 2>/dev/null)
        if [ -n "$last_test_entry" ] && [ "$last_test_entry" != "null" ]; then
            local test_error
            test_error=$(echo "$last_test_entry" | jq -r '.error // ""')
            if [ -n "$test_error" ] && [ "$test_error" != "" ]; then
                tests_passing="false"
            else
                tests_passing="true"
            fi
        fi

        # unresolved_loops: for each loop.detected event's (tool,file), check if still in last 10
        if [ -f "$events_file" ] && [ "$loop_count" -gt 0 ]; then
            local loop_patterns
            loop_patterns=$(jq -r --arg sid "$SESSION_PREFIX" \
                'select(.event=="loop.detected" and .session_id==$sid) | "\(.tool)|\(.file)"' \
                "$events_file" 2>/dev/null | sort -u)
            local last_10
            last_10=$(tail -n 10 "$loop_state_file")
            while IFS= read -r pattern; do
                [ -z "$pattern" ] && continue
                local loop_tool loop_file
                loop_tool="${pattern%%|*}"
                loop_file="${pattern#*|}"
                local still_present
                still_present=$(echo "$last_10" | jq -r --arg t "$loop_tool" --arg f "$loop_file" \
                    'select(.tool==$t and .file==$f) | .tool' 2>/dev/null | wc -l | tr -d ' ')
                if [ "$still_present" -gt 0 ]; then
                    unresolved_loops=$((unresolved_loops + 1))
                fi
            done <<< "$loop_patterns"
        fi
    fi

    # --- 5. Wait for gh result ---
    local pr_created="false"
    local pr_check_timeout="false"
    if [ -n "$gh_pid" ]; then
        wait "$gh_pid" 2>/dev/null || true
    fi
    local gh_output
    gh_output=$(cat "$gh_result_file" 2>/dev/null || echo "")
    rm -f "$gh_result_file"
    if [ "$gh_output" = "TIMEOUT" ]; then
        pr_check_timeout="true"
    elif [ "$gh_output" = "NO_GH" ]; then
        pr_check_timeout="true"
    elif echo "$gh_output" | jq -e '.[0].number' >/dev/null 2>&1; then
        pr_created="true"
    fi

    # --- 6. Compute duration_seconds ---
    local duration_seconds="null"
    if [ -f "$events_file" ]; then
        local start_ts
        start_ts=$(jq -r --arg sid "$SESSION_PREFIX" \
            'select(.event=="session.start" and .session_id==$sid) | .ts' \
            "$events_file" 2>/dev/null | head -1)
        if [ -n "$start_ts" ] && [ "$start_ts" != "null" ] && [ "$start_ts" != "" ]; then
            local start_epoch now_epoch
            # macOS date parsing
            start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$start_ts" +%s 2>/dev/null) || \
                start_epoch=$(date -d "$start_ts" +%s 2>/dev/null) || \
                start_epoch=""
            if [ -n "$start_epoch" ]; then
                now_epoch=$(date +%s)
                duration_seconds=$((now_epoch - start_epoch))
            fi
        fi
    fi
    # Fallback: file stat creation time
    if [ "$duration_seconds" = "null" ] && [ -f "$progress_file" ]; then
        local file_ctime now_epoch
        file_ctime=$(stat -f %B "$progress_file" 2>/dev/null) || \
            file_ctime=$(stat -c %W "$progress_file" 2>/dev/null) || \
            file_ctime=""
        if [ -n "$file_ctime" ] && [ "$file_ctime" != "0" ] && [ "$file_ctime" != "" ]; then
            now_epoch=$(date +%s)
            duration_seconds=$((now_epoch - file_ctime))
        fi
    fi

    # --- 7. Derive heuristic_outcome ---
    local heuristic_outcome="partial"
    if [ "$tests_passing" = "false" ] || [ "$constraint_violations_blocked" -gt 0 ]; then
        heuristic_outcome="failed"
    elif { [ "$pr_created" = "true" ] || [ "$progress_marked_complete" = "true" ]; } && \
         { [ "$tests_passing" = "true" ] || [ "$tests_passing" = "null" ]; } && \
         [ "$unresolved_loops" -eq 0 ] && [ "$constraint_violations_blocked" -eq 0 ]; then
        heuristic_outcome="success"
    fi

    # --- 8. Compute outcome_agreement ---
    local outcome_agreement="false"
    if [ "$agent_outcome" = "$heuristic_outcome" ]; then
        outcome_agreement="true"
    fi

    # --- 9. Compute team_context ---
    local team_context="false"
    if [ -f "$events_file" ]; then
        local team_events
        team_events=$(jq -r --arg branch "$BRANCH" \
            'select(.event | startswith("team.")) | select(.branch==$branch) | .event' \
            "$events_file" 2>/dev/null | head -1)
        if [ -n "$team_events" ]; then
            team_context="true"
        fi
    fi

    # --- 10. Emit session.end ---
    local extra_fields
    extra_fields=$(jq -n -c \
        --arg agent_outcome "$agent_outcome" \
        --arg heuristic_outcome "$heuristic_outcome" \
        --argjson outcome_agreement "$outcome_agreement" \
        --arg mode "$mode" \
        --argjson pr_created "$pr_created" \
        --argjson pr_check_timeout "$pr_check_timeout" \
        --argjson progress_marked_complete "$progress_marked_complete" \
        --argjson tests_passing "$tests_passing" \
        --argjson unresolved_loops "$unresolved_loops" \
        --argjson loop_count "$loop_count" \
        --argjson total_violations "$total_violations" \
        --argjson constraint_violations_blocked "$constraint_violations_blocked" \
        --argjson compaction_count "$compaction_count" \
        --argjson semantic_blocks "$semantic_blocks" \
        --argjson duration_seconds "$duration_seconds" \
        --argjson team_context "$team_context" \
        '{
            agent_outcome: $agent_outcome,
            heuristic_outcome: $heuristic_outcome,
            outcome_agreement: $outcome_agreement,
            mode: $mode,
            pr_created: $pr_created,
            pr_check_timeout: $pr_check_timeout,
            progress_marked_complete: $progress_marked_complete,
            tests_passing: $tests_passing,
            unresolved_loops: $unresolved_loops,
            loop_count: $loop_count,
            total_violations: $total_violations,
            constraint_violations_blocked: $constraint_violations_blocked,
            compaction_count: $compaction_count,
            semantic_blocks: $semantic_blocks,
            duration_seconds: $duration_seconds,
            team_context: $team_context
        }')

    emit_event "session.end" "$extra_fields"
}

# --- generate_postmortem: create a markdown post-mortem for "interesting" sessions ---
# Called right after compute_session_end in the Stop path.
# Only generates when the session hit loops, violations, failures, disagreement, or heavy compaction.
generate_postmortem() {
    local events_file
    events_file="$(get_analytics_dir "$CWD")/events.jsonl"

    # Need events.jsonl to exist
    [ -f "$events_file" ] || return 0

    # Read the session.end event for this session
    local end_event
    end_event=$(jq -c --arg sid "$SESSION_PREFIX" \
        'select(.event=="session.end" and .session_id==$sid)' \
        "$events_file" 2>/dev/null | tail -1)

    [ -n "$end_event" ] || return 0

    # --- Check trigger criteria ---
    local outcome_agreement heuristic_outcome loop_count constraint_violations_blocked compaction_count
    outcome_agreement=$(echo "$end_event" | jq -r '.outcome_agreement')
    heuristic_outcome=$(echo "$end_event" | jq -r '.heuristic_outcome')
    loop_count=$(echo "$end_event" | jq -r '.loop_count')
    constraint_violations_blocked=$(echo "$end_event" | jq -r '.constraint_violations_blocked')
    compaction_count=$(echo "$end_event" | jq -r '.compaction_count')

    local dominated=false
    [ "$outcome_agreement" = "false" ] && dominated=true
    [ "$loop_count" -gt 0 ] 2>/dev/null && dominated=true
    [ "$constraint_violations_blocked" -gt 0 ] 2>/dev/null && dominated=true
    [ "$heuristic_outcome" = "failed" ] || [ "$heuristic_outcome" = "partial" ] && dominated=true
    [ "$compaction_count" -ge 3 ] 2>/dev/null && dominated=true

    # Clean successful sessions get no post-mortem
    if [ "$dominated" = "false" ]; then
        return 0
    fi

    # --- Gather fields from session.end ---
    local agent_outcome mode duration_seconds pr_created tests_passing
    local unresolved_loops total_violations semantic_blocks progress_marked_complete
    agent_outcome=$(echo "$end_event" | jq -r '.agent_outcome')
    mode=$(echo "$end_event" | jq -r '.mode')
    duration_seconds=$(echo "$end_event" | jq -r '.duration_seconds')
    pr_created=$(echo "$end_event" | jq -r '.pr_created')
    tests_passing=$(echo "$end_event" | jq -r '.tests_passing')
    unresolved_loops=$(echo "$end_event" | jq -r '.unresolved_loops')
    total_violations=$(echo "$end_event" | jq -r '.total_violations')
    semantic_blocks=$(echo "$end_event" | jq -r '.semantic_blocks')
    progress_marked_complete=$(echo "$end_event" | jq -r '.progress_marked_complete')

    local end_ts
    end_ts=$(echo "$end_event" | jq -r '.ts')
    local end_date
    end_date=$(echo "$end_ts" | cut -dT -f1)

    # Format duration as human-readable
    local duration_display="unknown"
    if [ "$duration_seconds" != "null" ] && [ -n "$duration_seconds" ]; then
        local mins secs
        mins=$((duration_seconds / 60))
        secs=$((duration_seconds % 60))
        if [ "$mins" -gt 0 ]; then
            duration_display="${mins}m ${secs}s"
        else
            duration_display="${secs}s"
        fi
    fi

    # --- Create postmortem directory and file ---
    local postmortem_dir
    postmortem_dir="$(get_analytics_dir "$CWD")/postmortems"
    mkdir -p "$postmortem_dir"

    local postmortem_file="$postmortem_dir/${BRANCH_SAFE}--${SESSION_PREFIX}.md"

    # --- Build the timeline from events.jsonl ---
    local timeline
    timeline=$(jq -r --arg sid "$SESSION_PREFIX" \
        'select(.session_id==$sid) | "| \(.ts) | \(.event) | \(.scope // "-") |"' \
        "$events_file" 2>/dev/null)

    # --- Build loops table ---
    local loops_table=""
    if [ "$loop_count" -gt 0 ] 2>/dev/null; then
        loops_table=$(jq -r --arg sid "$SESSION_PREFIX" \
            'select(.event=="loop.detected" and .session_id==$sid) | "| \(.ts) | \(.tool // "-") | \(.file // "-") | \(.count // "-") |"' \
            "$events_file" 2>/dev/null)
    fi

    # --- Build constraint violations table ---
    local violations_table=""
    if [ "$total_violations" -gt 0 ] 2>/dev/null; then
        violations_table=$(jq -r --arg sid "$SESSION_PREFIX" \
            'select(.event=="constraint.violation" and .session_id==$sid) | "| \(.ts) | \(.rule // "-") | \(.severity // "-") | \(.decision // "-") |"' \
            "$events_file" 2>/dev/null)
    fi

    # --- Build signals list ---
    local signals=""
    [ "$outcome_agreement" = "false" ] && signals="${signals}- Outcome disagreement: agent=${agent_outcome}, heuristic=${heuristic_outcome}\n"
    [ "$loop_count" -gt 0 ] 2>/dev/null && signals="${signals}- ${loop_count} loop(s) detected (${unresolved_loops} unresolved)\n"
    [ "$constraint_violations_blocked" -gt 0 ] 2>/dev/null && signals="${signals}- ${constraint_violations_blocked} constraint violation(s) blocked\n"
    [ "$compaction_count" -ge 3 ] 2>/dev/null && signals="${signals}- High compaction count: ${compaction_count}\n"
    [ "$tests_passing" = "false" ] && signals="${signals}- Tests failing at session end\n"
    [ "$pr_created" = "false" ] && [ "$progress_marked_complete" = "true" ] && signals="${signals}- Marked complete but no PR created\n"

    # --- Write the markdown ---
    {
        echo "# Post-Mortem: ${SESSION_PREFIX}"
        echo ""
        echo "| Field | Value |"
        echo "|-------|-------|"
        echo "| Session | ${SESSION_PREFIX} |"
        echo "| Branch | ${BRANCH} |"
        echo "| Date | ${end_date} |"
        echo "| Duration | ${duration_display} |"
        echo "| Mode | ${mode} |"
        echo "| Outcome (agent) | ${agent_outcome} |"
        echo "| Outcome (heuristic) | ${heuristic_outcome} |"
        echo "| Agreement | ${outcome_agreement} |"
        echo ""
        echo "## Timeline"
        echo ""
        echo "| Timestamp | Event | Scope |"
        echo "|-----------|-------|-------|"
        if [ -n "$timeline" ]; then
            echo "$timeline"
        else
            echo "| (no events) | - | - |"
        fi
        echo ""

        if [ -n "$loops_table" ]; then
            echo "## Loops"
            echo ""
            echo "| Timestamp | Tool | File | Count |"
            echo "|-----------|------|------|-------|"
            echo "$loops_table"
            echo ""
        fi

        if [ -n "$violations_table" ]; then
            echo "## Constraint Violations"
            echo ""
            echo "| Timestamp | Rule | Severity | Decision |"
            echo "|-----------|------|----------|----------|"
            echo "$violations_table"
            echo ""
        fi

        echo "## Outcome Analysis"
        echo ""
        echo "- **Agent outcome:** ${agent_outcome}"
        echo "- **Heuristic outcome:** ${heuristic_outcome}"
        if [ "$outcome_agreement" = "true" ]; then
            echo "- **Agreement:** yes"
        else
            echo "- **Agreement:** no -- agent and heuristic disagree"
        fi
        echo "- **PR created:** ${pr_created}"
        echo "- **Tests passing:** ${tests_passing}"
        echo "- **Progress complete:** ${progress_marked_complete}"
        echo ""

        echo "## Signals"
        echo ""
        if [ -n "$signals" ]; then
            printf '%b' "$signals"
        else
            echo "- (none)"
        fi
    } > "$postmortem_file"
}

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
    # Check YAML frontmatter for status: complete
    if [ "$TASK_COMPLETE" = false ]; then
        YAML_STATUS=$(sed -n '/^---$/,/^---$/{ s/^status: *//p; }' "$PROGRESS_FILE" 2>/dev/null)
        if echo "$YAML_STATUS" | grep -qiE 'complete|done'; then
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
        UPDATED=$(grep -m1 '^\*\*Updated:\*\*' "$f" 2>/dev/null | sed 's/\*\*Updated:\*\* //' || echo "")
        # Fall back to YAML frontmatter session_start, then file mtime
        if [ -z "$UPDATED" ]; then
            UPDATED=$(sed -n '/^---$/,/^---$/{ s/^session_start: *//p; }' "$f" 2>/dev/null)
        fi
        if [ -z "$UPDATED" ]; then
            UPDATED=$(stat -f%Sm -t%Y-%m-%dT%H:%M:%SZ "$f" 2>/dev/null || stat -c%y "$f" 2>/dev/null || echo "unknown")
        fi
        STATUS=$(sed -n '/^## Current Status/{n;p;}' "$f" 2>/dev/null | head -1 || echo "")
        # Also check for non-standard status headers
        if [ -z "$STATUS" ]; then
            STATUS=$(grep -m1 '^## Status:' "$f" 2>/dev/null | sed 's/^## Status: //' || echo "")
        fi
        # Fall back to YAML frontmatter status/phase
        if [ -z "$STATUS" ]; then
            YAML_STATUS=$(sed -n '/^---$/,/^---$/{ s/^status: *//p; }' "$f" 2>/dev/null)
            YAML_PHASE=$(sed -n '/^---$/,/^---$/{ s/^phase: *//p; }' "$f" 2>/dev/null)
            if [ -n "$YAML_STATUS" ] && [ -n "$YAML_PHASE" ]; then
                STATUS="$YAML_STATUS ($YAML_PHASE)"
            elif [ -n "$YAML_STATUS" ]; then
                STATUS="$YAML_STATUS"
            else
                STATUS="unknown"
            fi
        fi
        echo "- **$FNAME** — $STATUS (updated: $UPDATED)"
    done
    if [ "$HAS_ENTRIES" = false ]; then
        echo "(no active sessions)"
    fi
} > "$PROGRESS_DIR/_index.md"

# Emit session.compact event (PreCompact only)
if [[ "$EVENT" == "PreCompact" && -d "$PROGRESS_DIR" ]]; then
    EVENTS_FILE="$(get_analytics_dir "$CWD")/events.jsonl"
    COMPACT_COUNT=1
    if [[ -f "$EVENTS_FILE" ]]; then
        COMPACT_COUNT=$(( $(jq -r "select(.event==\"session.compact\" and .session_id==\"$SESSION_PREFIX\")" "$EVENTS_FILE" 2>/dev/null | wc -l | tr -d ' ') + 1 ))
    fi
    emit_event "session.compact" "{\"compaction_count\":$COMPACT_COUNT}"
fi

# Emit session.end event and generate post-mortem (Stop only)
if [ "$EVENT" = "Stop" ]; then
    compute_session_end "$PROGRESS_FILE"
    generate_postmortem
fi

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
