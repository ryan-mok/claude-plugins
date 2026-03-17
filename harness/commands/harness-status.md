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
- **Mode** — from the `mode:` field in the progress YAML frontmatter (`harness`, `harness-auto`, `organic`)
- **Duration** — elapsed time since the session started
- **Compactions** — count of `session.compact` events from `.claude/harness/analytics/events.jsonl` for this session
- **Team context** — if `team_context: true` in the progress frontmatter

Example jq query for compactions:
```bash
jq -c 'select(.event == "session.compact" and .session_id == "SESSION_ID")' .claude/harness/analytics/events.jsonl | wc -l
```

If `$ARGUMENTS` contains `--progress`, also read and display the full contents of the current session's progress file.

---

## Section 2: Guardrail Activity

### Loop Detection

Find the loop detection state file at `/tmp/harness-loop-state-*.jsonl` for the current session. Also query `loop.detected` events from `.claude/harness/analytics/events.jsonl` for the current session.

**Loop resolution detection:** For each `loop.detected` event, extract its `(tool, file)` pattern. Then check whether that pattern is still present in the last 10 entries of `/tmp/harness-loop-state-{SESSION}.jsonl`. If the pattern has been cleared, mark it **resolved**. If still present, mark it **unresolved**.

Example jq queries:
```bash
# Get loop events for current session
jq -c 'select(.event == "loop.detected" and .session_id == "SESSION_ID")' .claude/harness/analytics/events.jsonl

# Get last 10 entries from loop state file
tail -10 /tmp/harness-loop-state-SESSION.jsonl | jq -s '.'
```

Report:
- Loops detected: N (M resolved, K unresolved)

### Constraint Violations

Query `constraint.violation` events from `.claude/harness/analytics/events.jsonl` for the current session.

Example jq query:
```bash
jq -s --arg sid "SESSION_ID" '[.[] | select(.event == "constraint.violation" and .session_id == $sid)] | group_by(.decision) | map({decision: .[0].decision, count: length})' .claude/harness/analytics/events.jsonl
```

Report:
- Constraint violations: N warnings (decision="allow"), M blocks (decision="deny")

If `$ARGUMENTS` contains `--reset-loops`, delete the loop state file and confirm reset.

---

## Section 3: Session History (last 30 days)

Query `.claude/harness/analytics/events.jsonl` for `session.end` events within the last 30 days.

Example jq queries:
```bash
# Total sessions in last 30 days
CUTOFF=$(date -v-30d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)
jq -s --arg cutoff "$CUTOFF" '[.[] | select(.event == "session.end" and .ts > $cutoff)]' .claude/harness/analytics/events.jsonl

# Outcomes breakdown
jq -s --arg cutoff "$CUTOFF" '[.[] | select(.event == "session.end" and .ts > $cutoff)] | group_by(.heuristic_outcome) | map({outcome: .[0].heuristic_outcome, count: length})' .claude/harness/analytics/events.jsonl

# Agreement rate (sessions where outcome_agreement is true vs total)
jq -s --arg cutoff "$CUTOFF" '[.[] | select(.event == "session.end" and .ts > $cutoff)] | {total: length, agreed: [.[] | select(.outcome_agreement == true)] | length}' .claude/harness/analytics/events.jsonl

# Average duration
jq -s --arg cutoff "$CUTOFF" '[.[] | select(.event == "session.end" and .ts > $cutoff) | .duration_seconds] | if length > 0 then (add / length / 60 | floor) else 0 end' .claude/harness/analytics/events.jsonl
```

Report:
- Total sessions: N
- Outcomes: N success, M partial, K failed
- Agreement rate: X% (N/M agent & heuristic agree)
- Average duration: Xm

---

## Section 4: Trends

Compare this week vs last week for key metrics.

Example jq queries:
```bash
# Loop rate this week vs last week
THIS_WEEK=$(date -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
LAST_WEEK=$(date -v-14d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ)

jq -s --arg tw "$THIS_WEEK" --arg lw "$LAST_WEEK" '{
  this_week: [.[] | select(.event == "loop.detected" and .ts > $tw)] | length,
  last_week: [.[] | select(.event == "loop.detected" and .ts > $lw and .ts <= $tw)] | length
}' .claude/harness/analytics/events.jsonl

# Most violated constraint rule
jq -s '[.[] | select(.event == "constraint.violation")] | group_by(.rule) | sort_by(-length) | .[0] | {rule: .[0].rule, count: length}' .claude/harness/analytics/events.jsonl

# Highest disagreement by mode
jq -s '[.[] | select(.event == "session.end" and .outcome_agreement == false)] | group_by(.mode) | map({mode: .[0].mode, count: length}) | sort_by(-(.count))' .claude/harness/analytics/events.jsonl
```

Report:
- Loop rate: N this week vs M last week (trend arrow)
- Most violated rule: rule_name (N times)
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
jq -c --arg sid "SESSION_ID" 'select(.session_id == $sid)' .claude/harness/analytics/events.jsonl
```

### `--trends`

If `$ARGUMENTS` contains `--trends`, show extended breakdowns:

```bash
# Per-rule violation breakdown
jq -s '[.[] | select(.event == "constraint.violation")] | group_by(.rule) | map({rule: .[0].rule, count: length, warn: [.[] | select(.decision == "allow")] | length, block: [.[] | select(.decision == "deny")] | length}) | sort_by(-(.count))' .claude/harness/analytics/events.jsonl

# Per-mode session outcomes
jq -s '[.[] | select(.event == "session.end")] | group_by(.mode) | map({mode: .[0].mode, total: length, success: [.[] | select(.heuristic_outcome == "success")] | length, partial: [.[] | select(.heuristic_outcome == "partial")] | length, failed: [.[] | select(.heuristic_outcome == "failed")] | length})' .claude/harness/analytics/events.jsonl

# Per-branch loop frequency
jq -s '[.[] | select(.event == "loop.detected")] | group_by(.branch) | map({branch: .[0].branch, count: length}) | sort_by(-(.count))' .claude/harness/analytics/events.jsonl
```

### `--postmortem [session_id]`

If `$ARGUMENTS` contains `--postmortem`, display a post-mortem. If a session_id is provided, find the matching file in `.claude/harness/analytics/postmortems/`. If no session_id, display the most recent post-mortem:

```bash
ls -t .claude/harness/analytics/postmortems/*.md 2>/dev/null | head -1
```

### `--team`

If `$ARGUMENTS` contains `--team`, show team activity view:

```bash
# Task completions with advisory signals
jq -s '[.[] | select(.event == "team.task_completed")] | {
  total: length,
  clean: [.[] | select(.advisory_signals.recent_blocked_violations == 0 and .advisory_signals.recent_loops_on_branch == 0)] | length,
  with_signals: [.[] | select(.advisory_signals.recent_blocked_violations > 0 or .advisory_signals.recent_loops_on_branch > 0)] | length
}' .claude/harness/analytics/events.jsonl

# Idle events
jq -s '[.[] | select(.event == "team.agent_idle")] | length' .claude/harness/analytics/events.jsonl
```

---

## Format

Present the output as a clean markdown summary matching this structure:

```
## Harness Status Dashboard

### Current Session
Session: SESSION_ID | Branch: BRANCH | Mode: MODE
Duration: Xh Xm | Compactions: N | Team context: yes/no

### Guardrail Activity (this session)
Loops detected: N (M resolved, K unresolved)
Constraint violations: N warn, M block

### Session History (last 30 days)
Total sessions: N
Outcomes: N success, M partial, K failed
Agreement rate: X% (N/M agent & heuristic agree)
Avg duration: Xm

### Trends
Loop rate: N/session (arrow from M last week)
Most violated rule: RULE (N times)
Highest disagreement: MODE (N sessions)

### Recent Post-Mortems
- BRANCH--SESSION (DATE) — OUTCOME
- BRANCH--SESSION (DATE) — OUTCOME
```
