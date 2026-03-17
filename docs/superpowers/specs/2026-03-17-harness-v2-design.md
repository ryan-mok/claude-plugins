# Harness Plugin v2 Design Specification

**Date:** 2026-03-17
**Status:** Draft
**Builds on:** [v1 spec](./2026-03-13-harness-plugin-design.md)

## Overview

Harness v2 adds three capabilities to the existing plugin, in priority order:

1. **Observability & Analytics** — Persistent event store, dual-signal session outcomes, diagnostic post-mortems, trend analysis
2. **Agent Teams Integration** — Team-level analytics hooks, query-time correlation, orchestration guidance for multi-agent workflows
3. **Semantic Constraints** — LLM-evaluated constraints via agent hooks for rules that can't be expressed as regex

All features ship together as a single v2 release. Development follows bottom-up order (analytics foundation first, then teams, then semantic constraints) to ensure each layer builds on validated ground.

## Design Principles

- **Append-only event store.** No in-place mutations. All analytics data is written via O_APPEND and queried via `jq`. This eliminates race conditions, stale state, and corruption risks from concurrent access.
- **Hooks emit, skills decide.** Hooks are fast, deterministic data emitters. Quality decisions (reopening tasks, restructuring work) happen in the orchestration skill where the agent has full context.
- **Query-time correlation over real-time detection.** Team context, session boundaries, and cross-agent patterns are derived from the event stream at query time, not maintained as mutable shared state.
- **Zero overhead by default.** New capabilities only add latency when explicitly opted into (semantic rules registered, team mode activated by Claude Code).

---

## 1. Analytics Event Store

### Storage

**Location:** `.claude/harness/analytics/events.jsonl`
**Type:** Append-only JSONL, one JSON object per line
**Gitignored:** Yes — the `/harness` and `/harness-auto` commands ensure `.claude/harness/analytics/` is in `.gitignore`
**Retention:** 90 days active, then archived to `events.archived.jsonl` via `/harness-cleanup --analytics`
**Concurrency:** Shell `>>` with O_APPEND is atomic for writes under PIPE_BUF (4096 bytes). Events are ~200-500 bytes. Safe for concurrent hooks and worktrees.
**Centralized:** All hooks resolve the file path via `get_git_root()`, which returns the main repo root even from worktrees. All sessions and worktrees write to the same file.

### Common Event Envelope

Every event shares these fields:

```json
{
  "ts": "2026-03-17T14:30:00Z",
  "event": "session.start",
  "session_id": "7fb1d778",
  "branch": "feat/new-api",
  "scope": "single",
  "worktree": false,
  "repo_root": "/Users/ryanmok/repos/claude-plugins"
}
```

| Field | Source | Description |
|-------|--------|-------------|
| `ts` | `date -u` | ISO 8601 UTC timestamp |
| `event` | Hook logic | Dot-namespaced event type |
| `session_id` | `get_session_prefix()` | First 8 chars of session ID |
| `branch` | `git rev-parse --abbrev-ref HEAD` | Current git branch |
| `scope` | Hardcoded per hook | `"single"` for existing hooks, `"team"` for team hooks |
| `worktree` | Git comparison | `true` if `--show-toplevel` differs from main repo root |
| `repo_root` | `get_git_root()` | Main repo root path |

**Note:** `mode` (harness, harness-auto, organic) is NOT on the envelope. Hooks cannot reliably determine mode at emission time (the `/harness` command may not have been invoked yet). Mode is only on the `session.end` event, where the Stop hook reads it from the progress file.

### Event Types

#### Session lifecycle

**`session.start`** — Emitted by SessionStart hook at the end of progress loading.

```json
{ "event": "session.start", "resumed": true }
```

- `resumed`: `true` if progress was loaded from a prior session, `false` if fresh
- Only emitted when `.claude/harness/progress/` directory exists (indicating harness has been used on this project). Organic sessions on non-harness projects produce no events.

**`session.end`** — Emitted by Stop hook. The primary analytics event.

```json
{
  "event": "session.end",
  "mode": "harness-auto",
  "agent_outcome": "success",
  "heuristic_outcome": "partial",
  "outcome_agreement": false,
  "heuristic_signals": {
    "pr_created": true,
    "pr_check_timeout": false,
    "tests_passing": false,
    "unresolved_loops": 1,
    "constraint_violations_blocked": 0,
    "progress_marked_complete": true
  },
  "duration_seconds": 1847,
  "compaction_count": 2,
  "loop_count": 3,
  "total_violations": 1,
  "semantic_blocks": 1,
  "team_context": false
}
```

| Field | Source | Description |
|-------|--------|-------------|
| `mode` | Progress file YAML frontmatter | `"harness"`, `"harness-auto"`, or `"organic"` |
| `agent_outcome` | Progress file `## Agent Outcome` section | `"success"`, `"partial"`, `"failed"`, `"abandoned"`, `"unknown"` |
| `heuristic_outcome` | Derived from `heuristic_signals` | `"success"`, `"partial"`, `"failed"` |
| `outcome_agreement` | Comparison | `agent_outcome == heuristic_outcome` |
| `pr_created` | `gh pr list` (8s timeout, background) | Whether a PR exists for this branch |
| `pr_check_timeout` | gh call timing | `true` if the gh call timed out (data incomplete) |
| `tests_passing` | Loop state file — last test runner error fingerprint (see note below) | `true`, `false`, or `null` (no test runner detected) |
| `unresolved_loops` | Loop state file point-in-time check | Count of detected loop patterns still present in last 10 entries at session end |
| `constraint_violations_blocked` | `events.jsonl` count | `constraint.violation` events with `decision: "deny"` for this session |
| `progress_marked_complete` | Progress file | Whether COMPLETE marker exists |
| `duration_seconds` | Fallback chain: (1) `session.start.ts` for this session in `events.jsonl`, (2) progress file creation time via `stat`, (3) `null` if neither available | Seconds from session start to end |
| `compaction_count` | `events.jsonl` count | `session.compact` events for this session |
| `loop_count` | `events.jsonl` count | `loop.detected` events for this session |
| `total_violations` | `events.jsonl` count | All `constraint.violation` events for this session (block + warn). Distinct from `heuristic_signals.constraint_violations_blocked` which counts only `decision: "deny"` events. |
| `semantic_blocks` | Progress file `## Semantic Constraint Notes` | Count of entries in that section |
| `team_context` | `events.jsonl` query | `true` if any `team.*` events exist for this branch in last 24h |

**Heuristic outcome derivation:**

```
success: (pr_created OR progress_marked_complete)
         AND (tests_passing == true OR tests_passing == null)
         AND unresolved_loops == 0
         AND constraint_violations_blocked == 0

failed:  tests_passing == false
         OR constraint_violations_blocked > 0

partial: everything else
```

Note: `tests_passing: null` (no test runner detected) does NOT trigger "failed". This prevents documentation-only sessions from being marked as failures.

**`tests_passing` derivation:** The loop state file stores fingerprints as `{"tool": "...", "file": "...", "error": "...", "ts": "..."}`. The `file` field contains the command string for Bash tool calls. The `error` field is a non-empty string when the tool result contains error patterns, or empty when successful. To determine `tests_passing`: scan the loop state JSONL for the last entry where `tool == "Bash"` and the `file` field matches a test runner pattern (`test`, `jest`, `pytest`, `cargo test`, `go test`, `npm test`, `vitest`, `mocha`, `rspec`). If the `error` field is non-empty → `tests_passing: false`. If empty → `tests_passing: true`. If no matching entry found → `tests_passing: null`.

**`session.compact`** — Emitted by PreCompact hook.

```json
{ "event": "session.compact", "compaction_count": 2 }
```

- `compaction_count`: Number of compactions for this session so far (including this one). Computed by counting existing `session.compact` events for this `session_id` in `events.jsonl` + 1.

#### Guardrail events

**`loop.detected`** — Emitted by loop-detect hook when a pattern fires.

```json
{ "event": "loop.detected", "pattern": "same-target", "tool": "Edit", "file": "src/api/handler.ts", "count": 4 }
```

- Only emitted when harness is active (existing guard: agent-written progress file exists for this session).
- `pattern`: `"same-target"`, `"error-echo"`, or `"edit-test-fail"`

**`constraint.violation`** — Emitted by constraint-check hook when a pattern-based rule matches.

```json
{ "event": "constraint.violation", "rule": "no-direct-db-in-api", "file": "src/api/users.ts", "severity": "block", "decision": "deny" }
```

- Replaces the ephemeral `/tmp/harness-constraint-log-*.jsonl` from v1. The `/tmp` log is removed in v2.
- `decision`: `"deny"` (blocked) or `"allow"` (warned)

#### Team events

**`team.task_completed`** — Emitted by team-task-verify.sh (TaskCompleted hook).

```json
{
  "event": "team.task_completed",
  "task_id": "5",
  "advisory_signals": {
    "recent_blocked_violations": 1,
    "recent_warn_violations": 0,
    "recent_loops_on_branch": 2
  }
}
```

- `advisory_signals`: Computed from `events.jsonl` — violations and loops on this branch since the last `team.task_completed` event.
- Informational only. The hook always exits 0 (never blocks task completion).

**`team.agent_idle`** — Emitted by team-idle-check.sh (TeammateIdle hook).

```json
{ "event": "team.agent_idle" }
```

- Minimal event — records that a teammate went idle.
- The hook always exits 0 (never redirects teammates).

### Events NOT in the schema

The following were considered and explicitly excluded:

| Event | Reason excluded |
|-------|----------------|
| `loop.recovered` | No hook can reliably detect recovery. Recovery is inferred at query time from the loop state file (detected pattern clears from rolling window). |
| `constraint.semantic_eval` | Agent hooks (which evaluate semantic constraints) have no Write access to `events.jsonl`. Semantic evaluation data is captured in the progress file's "Semantic Constraint Notes" section and summarized in `session.end.semantic_blocks`. |
| `team.start` / `team.end` | Derived at query time from earliest/latest `team.*` events per branch. Avoids coordination problems between hooks. |

---

## 2. Session Lifecycle Hook Modifications

### SessionStart hook (`progress-load.sh`)

**Existing behavior (unchanged):** Check for progress directory, apply priority-based search, load progress into context via `hookSpecificOutput.additionalContext`.

**New behavior:** After progress loading completes, emit `session.start` event to `events.jsonl`.

- `mkdir -p` the analytics directory before first write
- `resumed` is set based on whether progress was loaded
- Only emits if `.claude/harness/progress/` directory exists
- Timeout remains 5s (analytics emission adds ~50ms)

### PreCompact hook (`progress-save.sh`)

**Existing behavior (unchanged):** Save progress fallback.

**New behavior:** Also emit `session.compact` event.

- `compaction_count` computed from existing events in `events.jsonl`
- Timeout remains 10s

### PostToolUse hook (`loop-detect.sh`)

**Existing behavior (unchanged):** Rolling window pattern detection, LOOP DETECTED message injection.

**New behavior:** When a loop IS detected, also emit `loop.detected` event.

- Emission happens inside the detection logic, not on every tool call
- Timeout remains 5s (emission adds ~1ms)

### PreToolUse hook (`constraint-check.sh`)

**Existing behavior (unchanged):** Pattern-based constraint evaluation, block/warn decisions.

**New behavior:** When a violation IS found, emit `constraint.violation` event to `events.jsonl` instead of writing to `/tmp`.

- The `/tmp/harness-constraint-log-*.jsonl` files are no longer written
- Timeout remains 5s

### Stop hook (`progress-save.sh`)

**Existing behavior (unchanged):** Save progress fallback, regenerate index, clean stale files, always approve.

**New behavior:** Compute heuristic outcome, emit `session.end`, generate post-mortem.

**Timeout increased from 10s to 15s** to accommodate the `gh` network call.

**Execution flow:**

```
1. Start gh pr list in background (8s timeout)     ──┐
2. Save progress fallback (existing)                  │ parallel
3. Clean stale files, regenerate index (existing)     │
4. Read progress file for agent_outcome               │
5. Read events.jsonl for loop/violation counts        │
6. Check loop state file for unresolved patterns      │
7. Wait for gh result                               ──┘
8. Compute heuristic_signals and heuristic_outcome
9. Read progress file for mode and semantic_blocks
10. Emit session.end event
11. Check post-mortem trigger criteria
12. If triggered: generate post-mortem file
13. Return { "decision": "approve" }
```

**Timing budget:** Steps 2-6 ~1.5s, step 7 up to 8s (background), steps 8-12 ~1s. Total worst case ~10.5s within 15s budget with ~4.5s buffer.

---

## 3. Diagnostic Post-Mortems

### Trigger criteria

A post-mortem is generated when the session is "interesting" — at least one of:

- `outcome_agreement == false`
- `loop_count > 0`
- `constraint_violations_blocked > 0`
- `heuristic_outcome == "failed"` or `"partial"`
- `compaction_count >= 3`

Clean, fully-successful sessions don't get post-mortems.

### Storage

**Location:** `.claude/harness/analytics/postmortems/{branch}--{session_id}.md`
**Branch sanitization:** Slashes in branch names are replaced with hyphens (e.g., `feat/new-api` → `feat-new-api`), consistent with progress file naming convention.
**Gitignored:** Yes (covered by `.claude/harness/analytics/` gitignore entry)
**Retention:** 90 days, then removed by `/harness-cleanup --analytics`

### Format

```markdown
# Session Post-Mortem
**Session:** 7fb1d778
**Branch:** feat/new-api
**Date:** 2026-03-17T14:30:00Z
**Duration:** 30m 47s
**Mode:** harness-auto
**Outcome:** agent=success, heuristic=failed (DISAGREEMENT)

## Timeline
- 14:30:00 — Session started (fresh)
- 14:32:15 — loop.detected: same-target Edit on src/api/handler.ts (4x)
- 14:33:01 — loop.detected: error-echo "Cannot find module 'express'" (3x)
- 14:35:22 — constraint.violation: no-direct-db-in-api on src/api/users.ts (blocked)
- 14:38:00 — session.compact (1st compaction)
- 14:45:00 — session.compact (2nd compaction)
- 15:00:47 — Session ended

## Loops (2)
| Time | Pattern | Target | Count |
|------|---------|--------|-------|
| 14:32 | same-target | src/api/handler.ts | 4 |
| 14:33 | error-echo | "Cannot find module..." | 3 |

## Constraint Violations (1)
| Time | Rule | File | Severity | Decision |
|------|------|------|----------|----------|
| 14:35 | no-direct-db-in-api | src/api/users.ts | block | deny |

## Outcome Analysis
**Agent said:** success (progress marked COMPLETE)
**Heuristic said:** failed
**Disagreement reason:** tests_passing=false, constraint_violations_blocked=1

## Signals
- PR created: yes
- Tests passing: no
- Unresolved loops: 1
- Blocked violations: 1
- Progress marked complete: yes
- Compactions: 2
- Semantic blocks: 0
```

### Generation

Built by the Stop hook using `jq` queries + `printf` formatting. All events for the session are read from `events.jsonl`, sorted by `ts`, and templated. No LLM reasoning — deterministic and fast (~200-300ms).

### Access

- `/harness-status --postmortem` — most recent post-mortem
- `/harness-status --postmortem {session_id}` — specific post-mortem
- Direct file read

---

## 4. Agent Teams Integration

### Activation

Fully automatic. Team-specific hooks (`TaskCompleted`, `TeammateIdle`) are registered in the plugin's `hooks.json` but only fire when Claude Code is running agent teams. Zero overhead in solo sessions.

```
/harness → brainstorming → planning → execution
                                         ↓
                               Agent decides to use teams?
                               ├── No → solo, team hooks dormant
                               └── Yes → team hooks activate
```

No flags. No marker files. No detection logic.

### New hooks (2)

Both hooks are **analytics emitters only** — they always exit 0 and never block or redirect. Quality enforcement happens in the orchestration skill.

**Rationale:** Shell hooks lack the context for reliable quality gating. A TaskCompleted hook can't reliably determine if a task's output is good — it doesn't have access to the task list, the teammate's test results, or enough context to make a sound judgment. Blocking on unreliable signals is worse than not blocking.

#### `team-task-verify.sh` — TaskCompleted hook

```json
{
  "event": "TaskCompleted",
  "matcher": "*",
  "hooks": [{
    "type": "command",
    "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/scripts/team-task-verify.sh\"",
    "timeout": 15
  }]
}
```

1. Compute advisory signals by querying `events.jsonl`:
   - `recent_blocked_violations`: count `constraint.violation` events with `decision: "deny"` on this branch since the last `team.task_completed` event
   - `recent_warn_violations`: count with `decision: "allow"` (warned)
   - `recent_loops_on_branch`: count `loop.detected` events in the same window
2. Emit `team.task_completed` event with advisory signals
3. Exit 0 (always)

#### `team-idle-check.sh` — TeammateIdle hook

```json
{
  "event": "TeammateIdle",
  "matcher": "*",
  "hooks": [{
    "type": "command",
    "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/scripts/team-idle-check.sh\"",
    "timeout": 10
  }]
}
```

1. Emit `team.agent_idle` event
2. Exit 0 (always)

### Why NOT SubagentStop

`SubagentStop` fires for ALL subagents — exploration agents, code review agents, not just team members. Without a reliable way to filter team subagents from non-team subagents, the hook would emit spurious team events. Team lifecycle boundaries are derived at query time instead.

### Team context detection

**No marker files. No mutable shared state.**

Team context is determined at query time:

```bash
# Is this session part of a team?
jq -s '[.[] | select((.event | startswith("team.")) and .branch=="feat/new-api"
  and .ts > "2026-03-16T14:00:00Z")] | length > 0' events.jsonl

# Team summary for a branch
jq -s '
  [.[] | select((.event | startswith("team.")) and .branch=="feat/new-api")] |
  {
    tasks_completed: [.[] | select(.event=="team.task_completed")] | length,
    agents_idle: [.[] | select(.event=="team.agent_idle")] | length,
    first_event: (sort_by(.ts) | first | .ts),
    last_event: (sort_by(.ts) | last | .ts)
  }
' events.jsonl
```

The `session.end` event includes `team_context: bool` derived from this query.

### Investigation items

These assumptions need verification during implementation:

| Item | Assumption | How to verify |
|------|-----------|---------------|
| TaskCompleted hook input schema | Contains `task_id` and task metadata | Test with a sample team session or check Claude Code docs |
| TeammateIdle hook input schema | Contains agent identifier | Same |
| Hook execution context | Team hooks run with access to main repo's `events.jsonl` | Test — affects path resolution |
| TaskCompleted exit code 2 behavior | If exit code 2 blocks completion and sends feedback, this could enable future upgrade from analytics-only to gating hooks. Current design uses exit 0 only. | Verify in Claude Code docs for future consideration |

---

## 5. Semantic Constraints

### Hook type clarification

The v1 spec referenced "prompt hooks" (`type: "prompt"`) as a future option for semantic constraints. v2 uses `type: "agent"` hooks instead. These are distinct Claude Code hook types:

- **`type: "prompt"`** — Single-turn LLM evaluation. The model receives the prompt + hook input and returns `{ok, reason}`. Cannot read files.
- **`type: "agent"`** — Multi-turn subagent with tool access (Read, Grep, Glob, WebFetch). Up to 50 turns. Returns `{ok, reason}`.

v2 requires `type: "agent"` because semantic constraints need to Read `constraints.json` dynamically, and cross-file constraints need to Read/Glob context files. `type: "prompt"` cannot do this (no tool access). Both types use a `prompt` field in the hook configuration and the same `{ok, reason}` response format.

### Constraint types (v1 + v2)

| Type | Mechanism | Severity | Analytics | Latency | Hook location |
|------|-----------|----------|-----------|---------|---------------|
| `import-boundary` | Regex on imports | block, warn | Real-time JSONL | <50ms | Plugin `hooks.json` |
| `file-pattern` | Regex on content | block, warn | Real-time JSONL | <50ms | Plugin `hooks.json` |
| `custom` | Regex on content | block, warn | Real-time JSONL | <50ms | Plugin `hooks.json` |
| `semantic` (v2) | Agent hook — LLM evaluates content | block only | Via progress file | ~3-30s | Project `settings.json` |
| `cross-file` (v2) | Agent hook — subagent reads multiple files | block only | Via progress file | ~3-30s | Project `settings.json` |

### Why block only for semantic/cross-file

Agent hooks return `{ok: true}` or `{ok: false, reason: "..."}`. This is binary — block or allow. There is no mechanism to inject an advisory warning while allowing the action to proceed. The `command` hook type supports this via `permissionDecision: "allow"` + `systemMessage`, but agent hooks do not.

### Zero overhead by default

The agent hook is **not registered in the plugin's `hooks.json`**. It is added to the project's `.claude/settings.json` by the constraint-setup skill when the user creates their first `semantic` or `cross-file` rule.

- No semantic/cross-file rules → no agent hook registered → zero overhead on all writes
- Semantic/cross-file rules exist → agent hook fires on all Write/Edit → ~3-5s overhead for non-matching files (fast path), ~10-30s for matching files (evaluation)
- All semantic/cross-file rules removed → skill removes agent hook from `settings.json`

### Hook architecture

Both hooks fire in **parallel** on PreToolUse Write|Edit (Claude Code runs all matching hooks in parallel):

```
Write/Edit attempted
    ↓
┌─ constraint-check.sh (command, 5s) ─── pattern rules
│
├─ agent hook (agent, 60s) ──────────── semantic/cross-file rules
│                                        (only if registered in settings.json)
↓
Results merged: any deny → action blocked
```

If both hooks are registered and both deny, the action is blocked with both reasons fed to Claude. If only one denies, the action is blocked. If neither denies, the action proceeds.

### Agent hook configuration

Added to `.claude/settings.json` by the constraint-setup skill:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "agent",
            "prompt": "PRIORITY: Exit early if possible.\n\nStep 1: Extract the file_path from the tool input below.\nStep 2: Read .claude/harness/constraints.json. If it does not exist, immediately return {\"ok\": true}.\nStep 3: Find rules with type 'semantic' or 'cross-file' AND severity 'block'. If none exist, immediately return {\"ok\": true}.\nStep 4: Check if file_path matches any matching rule's 'check.in' glob. If no glob matches, immediately return {\"ok\": true}.\nStep 5: For matching 'semantic' rules — if this is an Edit operation, Read the full target file for context. Evaluate whether the PROPOSED CHANGE introduces a violation per the rule's 'description' and 'check.prompt' fields. Do not flag pre-existing violations in unchanged code.\nStep 6: For matching 'cross-file' rules — use Glob to find files matching 'context_files' patterns, Read relevant matches, and verify the constraint described in the 'verify' field.\nStep 7: If any block-severity rule is violated, return {\"ok\": false, \"reason\": \"Rule [name]: [description]\"}. Otherwise return {\"ok\": true}.\n\nTool input: $ARGUMENTS",
            "timeout": 60
          }
        ]
      }
    ]
  }
}
```

The agent hook prompt is structured as a decision tree with early exits at steps 2, 3, and 4 to minimize work for the common case (non-matching files).

### constraints.json format (v2 additions)

```json
{
  "rules": [
    {
      "name": "no-business-logic-in-controllers",
      "type": "semantic",
      "description": "Controller files should only handle HTTP request/response. Business logic belongs in the service layer.",
      "check": {
        "in": "src/controllers/**",
        "prompt": "Does this code contain business logic (data transformation, validation rules, complex conditionals, database queries) rather than just HTTP request handling and delegation to services?"
      },
      "severity": "block"
    },
    {
      "name": "api-endpoints-must-have-tests",
      "type": "cross-file",
      "description": "Every exported function in src/api/ must have a corresponding test in tests/api/",
      "check": {
        "in": "src/api/**",
        "verify": "Check if the function being added or modified has a corresponding test file in tests/api/ with at least one test case for this function.",
        "context_files": ["tests/api/**"]
      },
      "severity": "block"
    }
  ]
}
```

### Known limitations

1. **Block only:** Semantic/cross-file rules cannot use `warn` severity. The agent hook format (`{ok, reason}`) has no middle ground.
2. **No real-time analytics:** Agent hooks can't write to `events.jsonl`. Semantic evaluations are logged by the agent in the progress file's "Semantic Constraint Notes" section and summarized in `session.end.semantic_blocks`.
3. **Per-write overhead:** When registered, the agent hook adds ~3-5s to every Write/Edit (fast path) or ~10-30s (evaluation path). This is acceptable in Claude Code's agentic loop (5-30s reasoning between tool calls) but should be documented.
4. **Skill-managed lifecycle:** The constraint-setup skill must be used to add/remove semantic/cross-file rules so the agent hook registration stays in sync.

---

## 6. Status Dashboard

### `/harness-status` v2 output

```
## Harness Status

### Current Session
Session: 7fb1d778 | Branch: feat/new-api | Mode: harness-auto
Duration: 32m | Compactions: 1 | Team context: no

### Guardrail Activity (this session)
Loops detected: 2 (1 resolved, 1 unresolved)
Constraint violations: 3 (2 warn, 1 block)

### Session History (last 30 days)
Total sessions: 18
Outcomes: 12 success, 4 partial, 2 failed
Agreement rate: 83% (15/18 agent & heuristic agree)
Avg duration: 28m

### Trends
Loop rate: 1.4/session (↓ from 2.1 last week)
Most violated rule: no-env-in-source (7 times)
Highest disagreement: harness-auto mode (3/8 disagree)

### Recent Post-Mortems
- feat/auth-refactor--a3c2e891 (failed) — edit-test-fail loop on jwt.ts
- feat/new-api--f9d1b445 (partial) — PR created but tests failing
```

**Note:** "Semantic evaluations" are NOT shown in the live session view. They lack real-time JSONL events and only appear in post-mortems and session history (derived from `session.end`).

**Loop resolution detection (live):** The status command determines "resolved" vs "unresolved" loops by reading the current loop state file (`/tmp/harness-loop-state-{SESSION}.jsonl`). For each `loop.detected` event's (tool, file) pattern, check if that pattern is still present in the last 10 entries. If cleared → resolved. If still present → unresolved. This is the same logic the Stop hook uses for `session.end.unresolved_loops`.

### Flags

| Flag | Description |
|------|-------------|
| `--progress` | Full progress file contents (existing) |
| `--constraints` | All loaded constraint rules (existing) |
| `--reset-loops` | Clear loop detection state (existing) |
| `--analytics` | All events for current session from `events.jsonl` |
| `--trends` | Extended trend analysis: per-rule, per-mode, per-branch breakdowns |
| `--postmortem` | Most recent post-mortem. `--postmortem {session_id}` for specific. |
| `--team` | Team-specific view (see below) |

### Team view (`--team`)

```
### Team Activity (branch: feat/new-api)
Task completions: 7
  - Clean (no advisory signals): 5
  - With advisory signals: 2 (recent loops: 1, recent violations: 1)
Agent idle events: 3
```

Computed from `team.task_completed` and `team.agent_idle` events filtered by branch.

### Implementation

The status command is a slash command (markdown file) that instructs the agent to run `jq` queries against `events.jsonl` and format results. No new hook scripts. Consistent with v1's approach.

---

## 7. Skill and Command Updates

### 7a. Progress file format (v2)

```markdown
---
status: in_progress
team_context: false
mode: harness-auto
---

# Harness Progress
**Updated:** 2026-03-17T15:00:00Z
**Branch:** feat/new-api
**Session:** 7fb1d778
**Objective:** Add user authentication API

## Current Status
Implementing JWT middleware. Tests passing for token generation.

## Completed
- [x] Designed auth flow with refresh token rotation (src/auth/jwt.ts)

## Next Steps
- [ ] Add middleware integration tests

## Key Decisions
- Using RS256 over HS256 — asymmetric keys allow separate signing/verification services

## Key Files
- src/auth/jwt.ts
- src/middleware/auth.ts

## Semantic Constraint Notes
- [14:35] Rule no-business-logic-in-controllers blocked edit to src/controllers/users.ts — moved validation logic to src/services/user-validation.ts

## Agent Outcome
success
```

**New YAML frontmatter fields:**

| Field | Values | Purpose |
|-------|--------|---------|
| `team_context` | `true`/`false` | Secondary signal for Stop hook's team detection |
| `mode` | `"harness"`, `"harness-auto"`, `"organic"` | Read by Stop hook for `session.end.mode` |

**New sections:**

| Section | Purpose | Consumer |
|---------|---------|----------|
| `## Semantic Constraint Notes` | Agent logs semantic blocks (timestamp, rule, action taken) | Stop hook → `session.end.semantic_blocks` |
| `## Agent Outcome` | Explicit self-reported outcome | Stop hook → `session.end.agent_outcome` |

`## Agent Outcome` values: `success`, `partial`, `failed`, `abandoned`. The Stop hook reads the first word of the line after the heading. If missing or unrecognized, defaults to `"unknown"`.

### 7b. Harness orchestration skill updates

Three new sections added to the skill:

**Analytics Awareness:**
- After each completed implementation step, check `/harness-status` for anomalies (rising loop count, constraint violations)
- If `outcome_agreement` has been `false` in recent sessions on this branch, increase self-verification rigor

**Team Mode:**
- When using agent teams, decompose work into tasks with explicit file ownership — no two tasks should modify the same file
- After each task completion, review advisory signals via `/harness-status --team`
- If a task had high `recent_loops_on_branch` or `recent_blocked_violations`, consider reopening it via the task list
- Run the full test suite before accepting the team's collective output
- Write `team_context: true` in progress file YAML frontmatter

**Semantic Constraint Handling:**
- When a semantic constraint blocks a write (`ok: false`), log it in the progress file's "Semantic Constraint Notes" section with timestamp, rule name, and the alternative approach taken
- Do not attempt to bypass semantic constraints — restructure the code to comply

### 7c. Harness orchestration auto skill updates

Same additions as 7b, with autonomous decision-making:

- Check `/harness-status` after every 3rd implementation step (balance thoroughness with speed)
- If loop count > 3 or violation count > 2, pause and invoke loop-recovery skill
- After team task completions, self-review advisory signals and decide whether to reopen tasks — no waiting for human input
- Document all decisions in progress file

### 7d. Constraint setup skill updates

- Document `semantic` and `cross-file` rule types with examples and guidance
- **Validate severity:** Reject `warn` severity on semantic/cross-file rules with clear error message explaining the limitation
- **Agent hook lifecycle:**
  - Adding first semantic/cross-file rule → add agent hook to `.claude/settings.json`
  - Removing last semantic/cross-file rule → remove agent hook from `.claude/settings.json`
  - Handle edge cases: settings.json doesn't exist (create it), exists but has no hooks section (add one), exists with other hooks (merge, don't clobber)
- **Document performance:** "Semantic/cross-file rules add ~3-5s to every file write operation when registered. Use narrow globs to minimize impact."

### 7e. Harness cleanup command updates

**New `--analytics` flag:**
- Archive events older than 90 days: move matching lines from `events.jsonl` to `events.archived.jsonl`
- Remove post-mortems older than 90 days from `postmortems/`

**`--constraints` flag deprecated:**
- Constraint violation data now lives in `events.jsonl` (managed by `--analytics`)
- Flag prints: "Constraint logs are now in analytics. Use --analytics to manage."

**`--all` updated:** Now includes analytics cleanup. The existing behavior of "no flags = clean everything" is preserved, and now "everything" includes analytics.

### 7f. Harness command updates (/harness, /harness-auto)

**Gitignore setup:** Both commands ensure `.claude/harness/analytics/` is in `.gitignore`, alongside the existing `.claude/harness/progress/` entry.

---

## 8. Updated hooks.json

The plugin's `hooks.json` with all v2 additions:

```json
{
  "description": "Harness engineering guardrails: loop detection, progress persistence, constraint enforcement, team analytics",
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/scripts/loop-detect.sh\"",
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/scripts/progress-save.sh\"",
            "timeout": 15
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/scripts/progress-save.sh\"",
            "timeout": 10
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/scripts/progress-load.sh\"",
            "timeout": 5
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/scripts/constraint-check.sh\"",
            "timeout": 5
          }
        ]
      }
    ],
    "TaskCompleted": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/scripts/team-task-verify.sh\"",
            "timeout": 15
          }
        ]
      }
    ],
    "TeammateIdle": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/scripts/team-idle-check.sh\"",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

**Changes from v1:**
- Stop hook timeout: 10s → 15s (for `gh` call in heuristic computation)
- Added `TaskCompleted` hook (team analytics)
- Added `TeammateIdle` hook (team analytics)
- Semantic constraint agent hook is NOT here — it lives in project `.claude/settings.json`, managed by the constraint-setup skill

---

## 9. New Files Summary

| File | Type | Purpose |
|------|------|---------|
| `hooks/scripts/team-task-verify.sh` | Hook script | TaskCompleted analytics emitter |
| `hooks/scripts/team-idle-check.sh` | Hook script | TeammateIdle analytics emitter |
| `.claude/harness/analytics/events.jsonl` | Data (gitignored) | Persistent event store |
| `.claude/harness/analytics/postmortems/*.md` | Data (gitignored) | Per-session diagnostic reports |
| `.claude/harness/analytics/events.archived.jsonl` | Data (gitignored) | Archived events (90+ days old) |

## 10. Modified Files Summary

| File | Changes |
|------|---------|
| `hooks/hooks.json` | Stop timeout 15s, add TaskCompleted and TeammateIdle hooks |
| `hooks/scripts/progress-load.sh` | Emit `session.start` event |
| `hooks/scripts/progress-save.sh` | Emit `session.compact`, compute and emit `session.end`, generate post-mortems |
| `hooks/scripts/loop-detect.sh` | Emit `loop.detected` event |
| `hooks/scripts/constraint-check.sh` | Switch from `$CWD` to `get_git_root()` for path resolution (worktree fix), emit `constraint.violation` to `events.jsonl`, remove `/tmp` log |
| `hooks/scripts/lib.sh` | Add analytics helpers (emit_event, get_analytics_dir) |
| `skills/harness-orchestration/SKILL.md` | Analytics awareness, team mode, semantic constraint sections |
| `skills/harness-orchestration-auto/SKILL.md` | Same additions with autonomous overrides |
| `skills/progress-tracking/SKILL.md` | New progress file sections (frontmatter, semantic notes, agent outcome) |
| `skills/constraint-setup/SKILL.md` | Semantic/cross-file rule types, severity validation, agent hook lifecycle |
| `commands/harness.md` | Gitignore analytics directory |
| `commands/harness-auto.md` | Gitignore analytics directory |
| `commands/harness-status.md` | v2 dashboard with analytics, trends, post-mortems, team view |
| `commands/harness-cleanup.md` | --analytics flag, --constraints deprecation |

---

## Appendix A: Example jq Queries

```bash
# Success rate (last 30 days)
jq 'select(.event=="session.end" and .ts>"2026-02-15")
  | .heuristic_outcome' events.jsonl | sort | uniq -c

# Disagreement rate
jq 'select(.event=="session.end" and .outcome_agreement==false)' events.jsonl

# Most violated constraint rules
jq 'select(.event=="constraint.violation") | .rule' events.jsonl \
  | sort | uniq -c | sort -rn

# Loop rate per session (requires slurp)
jq -s '
  [.[] | select(.event=="loop.detected")]
  | group_by(.session_id)
  | map(length)
  | add / length
' events.jsonl

# Sessions with outcome disagreement by mode
jq -s '
  [.[] | select(.event=="session.end" and .outcome_agreement==false)]
  | group_by(.mode)
  | map({mode: .[0].mode, count: length})
' events.jsonl

# Team summary for a branch
jq -s '
  [.[] | select((.event | startswith("team.")) and .branch=="feat/new-api")]
  | {
      tasks: [.[] | select(.event=="team.task_completed")] | length,
      with_signals: [.[] | select(.event=="team.task_completed")
        | select(.advisory_signals.recent_loops_on_branch > 0
          or .advisory_signals.recent_blocked_violations > 0)] | length,
      idle_events: [.[] | select(.event=="team.agent_idle")] | length
    }
' events.jsonl

# Token efficiency proxy: compactions per session
jq -s '
  [.[] | select(.event=="session.end")]
  | map({session: .session_id, compactions: .compaction_count, outcome: .heuristic_outcome})
  | sort_by(.compactions) | reverse
' events.jsonl
```

## Appendix B: Migration from v1

| v1 | v2 | Migration |
|----|-----|-----------|
| `/tmp/harness-constraint-log-*.jsonl` | `events.jsonl` (`constraint.violation` events) | Automatic — v2 hooks write to new location |
| `/harness-cleanup --constraints` | `/harness-cleanup --analytics` | Flag deprecated with message |
| `/harness-status` constraint queries | Reads `events.jsonl` instead of `/tmp` | Automatic — v2 status command updated |
| Progress file format | Gains YAML frontmatter, new sections | Backward compatible — new sections are optional, Stop hook defaults to `"unknown"` for missing data. Fallback-generated progress files (from git) do NOT include YAML frontmatter; the Stop hook treats missing frontmatter as `mode: "unknown"`, `team_context: false`. |
| v1 "prompt hooks" for semantic constraints | v2 uses `type: "agent"` hooks | Agent hooks were chosen over prompt hooks because semantic constraints require Read access to `constraints.json` and cross-file constraints require Glob/Read for context files. See Section 5 "Hook type clarification". |
| v1 `custom-semantic` constraint type | v2 uses `semantic` and `cross-file` types | Split into two types for clarity: `semantic` (single-file LLM evaluation) and `cross-file` (multi-file subagent verification). |
