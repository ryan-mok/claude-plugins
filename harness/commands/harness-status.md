---
description: Show harness v2 dashboard (session, guardrails, analytics, trends)
argument-hint: [--progress | --reset-loops | --analytics | --trends | --postmortem [session_id] | --team]
allowed-tools: Read, Bash(cat:*,ls:*,wc:*,jq:*,head:*,find:*,rm:*,tail:*,grep:*,sort:*,uniq:*,awk:*,date:*,stat:*)
---

Assemble and display the current harness status dashboard by reading state and analytics files. Check if `jq` is available on the system PATH first — if not, warn the user that harness hooks require jq.

Flag: $ARGUMENTS

---

## Section 1: Current Session

Read the current session's progress file from `.claude/harness/progress/` and its YAML frontmatter. Report:

- **Session ID** — the session prefix from the filename
- **Branch** — from the progress file or `git branch --show-current`
- **Mode** — from the `mode:` field in the progress YAML frontmatter (e.g., `guided`, `autonomous`)
- **Duration** — elapsed time since the session started (from `started:` frontmatter field)
- **Compactions** — count of `compaction` events from `.claude/harness/analytics/events.jsonl` for this session
- **Team context** — if team member metadata exists in the progress frontmatter, show it

Example jq query for compactions:
```bash
jq -s '[.[] | select(.event == "compaction" and .session == "SESSION_ID")] | length' .claude/harness/analytics/events.jsonl
```

If `$ARGUMENTS` contains `--progress`, also read and display the full contents of the current session's progress file.

---

## Section 2: Guardrail Activity

### Loop Detection

Find the loop detection state file at `/tmp/harness-loop-state-*.jsonl` for the current project. Also query `loop.detected` events from `.claude/harness/analytics/events.jsonl` for the current session.

**Loop resolution detection:** For each `loop.detected` event, extract its `(tool, file)` pattern. Then check whether that pattern is still present in the last 10 entries of `/tmp/harness-loop-state-{SESSION}.jsonl`. If the pattern has been cleared, mark it **resolved**. If still present, mark it **unresolved**.

Example jq queries:
```bash
# Get loop events for current session
jq -s '[.[] | select(.event == "loop.detected" and .session == "SESSION_ID")]' .claude/harness/analytics/events.jsonl

# Get last 10 entries from loop state file
tail -10 /tmp/harness-loop-state-SESSION.jsonl | jq -s '.'
```

Report:
- Loops detected: N (M resolved, K unresolved)

### Constraint Violations

Query `constraint.violation` events from `.claude/harness/analytics/events.jsonl` for the current session.

Example jq query:
```bash
jq -s '[.[] | select(.event == "constraint.violation" and .session == "SESSION_ID")] | group_by(.action) | map({action: .[0].action, count: length})' .claude/harness/analytics/events.jsonl
```

Report:
- Constraint violations: N warnings, M blocks

If `$ARGUMENTS` contains `--reset-loops`, delete the loop state file and confirm reset.

---

## Section 3: Session History (last 30 days)

Query `.claude/harness/analytics/events.jsonl` for `session.end` events within the last 30 days.

Example jq queries:
```bash
# Total sessions in last 30 days
CUTOFF=$(date -v-30d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d '30 days ago' +%Y-%m-%dT%H:%M:%S)
jq -s --arg cutoff "$CUTOFF" '[.[] | select(.event == "session.end" and .timestamp > $cutoff)]' .claude/harness/analytics/events.jsonl

# Outcomes breakdown
jq -s --arg cutoff "$CUTOFF" '[.[] | select(.event == "session.end" and .timestamp > $cutoff)] | group_by(.outcome) | map({outcome: .[0].outcome, count: length})' .claude/harness/analytics/events.jsonl

# Agreement rate (sessions where human_agreement is true vs total)
jq -s --arg cutoff "$CUTOFF" '[.[] | select(.event == "session.end" and .timestamp > $cutoff)] | {total: length, agreed: [.[] | select(.human_agreement == true)] | length}' .claude/harness/analytics/events.jsonl

# Average duration
jq -s --arg cutoff "$CUTOFF" '[.[] | select(.event == "session.end" and .timestamp > $cutoff) | .duration_minutes] | add / length' .claude/harness/analytics/events.jsonl
```

Report:
- Total sessions: N
- Outcomes: N success, M partial, K failed
- Agreement rate: X%
- Average duration: Xm

---

## Section 4: Trends

Compare this week vs last week for key metrics.

Example jq queries:
```bash
# Loop rate this week vs last week
THIS_WEEK=$(date -v-7d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d '7 days ago' +%Y-%m-%dT%H:%M:%S)
LAST_WEEK=$(date -v-14d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d '14 days ago' +%Y-%m-%dT%H:%M:%S)

jq -s --arg tw "$THIS_WEEK" --arg lw "$LAST_WEEK" '{
  this_week: [.[] | select(.event == "loop.detected" and .timestamp > $tw)] | length,
  last_week: [.[] | select(.event == "loop.detected" and .timestamp > $lw and .timestamp <= $tw)] | length
}' .claude/harness/analytics/events.jsonl

# Most violated constraint rule
jq -s '[.[] | select(.event == "constraint.violation")] | group_by(.rule_id) | sort_by(-length) | .[0] | {rule: .[0].rule_id, count: length}' .claude/harness/analytics/events.jsonl

# Highest disagreement by mode
jq -s '[.[] | select(.event == "session.end" and .human_agreement == false)] | group_by(.mode) | map({mode: .[0].mode, count: length}) | sort_by(-(.count))' .claude/harness/analytics/events.jsonl
```

Report:
- Loop rate: N this week vs M last week (trend arrow)
- Most violated rule: rule_id (N times)
- Highest disagreement by mode: mode_name (N sessions)

---

## Section 5: Recent Post-Mortems

List post-mortem files from `.claude/harness/analytics/postmortems/` directory, most recent first.

```bash
ls -lt .claude/harness/analytics/postmortems/*.md 2>/dev/null | head -5
```

Report the last 5 post-mortems with their session ID and date.

---

## Additional Flags

### `--analytics`

If `$ARGUMENTS` contains `--analytics`, display all events for the current session from `.claude/harness/analytics/events.jsonl`:

```bash
jq -s '[.[] | select(.session == "SESSION_ID")]' .claude/harness/analytics/events.jsonl
```

### `--trends`

If `$ARGUMENTS` contains `--trends`, show extended breakdowns:

```bash
# Per-rule violation breakdown
jq -s '[.[] | select(.event == "constraint.violation")] | group_by(.rule_id) | map({rule: .[0].rule_id, count: length, warn: [.[] | select(.action == "warn")] | length, block: [.[] | select(.action == "block")] | length}) | sort_by(-(.count))' .claude/harness/analytics/events.jsonl

# Per-mode session outcomes
jq -s '[.[] | select(.event == "session.end")] | group_by(.mode) | map({mode: .[0].mode, total: length, outcomes: (group_by(.outcome) | map({outcome: .[0].outcome, count: length}))})' .claude/harness/analytics/events.jsonl

# Per-branch loop frequency
jq -s '[.[] | select(.event == "loop.detected")] | group_by(.branch) | map({branch: .[0].branch, count: length}) | sort_by(-(.count))' .claude/harness/analytics/events.jsonl
```

### `--postmortem [session_id]`

If `$ARGUMENTS` contains `--postmortem`, display a post-mortem. If a session_id is provided, read `.claude/harness/analytics/postmortems/{session_id}.md`. If no session_id, display the most recent post-mortem:

```bash
ls -t .claude/harness/analytics/postmortems/*.md 2>/dev/null | head -1
```

### `--team`

If `$ARGUMENTS` contains `--team`, show team activity view:

```bash
# Task completions with advisory signals
jq -s '[.[] | select(.event == "task.completed")] | group_by(.team_member) | map({member: .[0].team_member, completed: length, advisory_signals: [.[] | select(.advisory_signal != null)] | length})' .claude/harness/analytics/events.jsonl

# Idle events
jq -s '[.[] | select(.event == "session.idle")] | sort_by(.timestamp) | reverse | .[0:10]' .claude/harness/analytics/events.jsonl
```

---

## Format

Present the output as a clean markdown summary matching this structure:

```
## Harness Status Dashboard

### Current Session
Session: SESSION_ID
Branch: BRANCH
Mode: MODE
Duration: Xh Xm
Compactions: N
Team: CONTEXT

### Guardrail Activity
Loops detected: N (M resolved, K unresolved)
Constraint violations: N warnings, M blocks

### Session History (last 30 days)
Total sessions: N
Outcomes: N success, M partial, K failed
Agreement rate: X%
Avg duration: Xm

### Trends
Loop rate: N this week vs M last week
Most violated rule: RULE_ID (N times)
Highest disagreement: MODE (N sessions)

### Recent Post-Mortems
- SESSION_ID (DATE) — SUMMARY
- SESSION_ID (DATE) — SUMMARY
```
