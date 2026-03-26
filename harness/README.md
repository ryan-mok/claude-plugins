# Harness

Runtime guardrails for autonomous Claude Code development. Wraps the [superpowers](https://github.com/anthropics/claude-plugins-official/tree/main/superpowers) workflow with graduated loop detection, git checkpointing, budget tracking, cross-session progress persistence, architectural constraint enforcement, session-end heuristics, post-mortem generation, and team-mode analytics.

## What It Does

Harness has two layers:

1. **Always-on hooks** that fire automatically on every tool call — no setup needed beyond installing the plugin.
2. **Commands** that orchestrate the full development lifecycle with harness awareness baked in.

### Always-On Hooks

| Hook | Event | What It Does |
|------|-------|-------------|
| **Loop Detection** | `PostToolUse` | 4-level graduated response (nudge, warn, redirect, circuit-breaker) for three patterns: same-target repetition, error echo, and edit-test-fail cycles. Also tracks tool call budget with advisories at 50/100/150 calls. |
| **Git Checkpoint** | `PostToolUse` (Bash) | Creates non-destructive git stash checkpoints after passing test runs. Rate-limited to one checkpoint per 5 minutes. Provides a "last known good state" for rollback during loop recovery. |
| **Progress Save** | `Stop`, `PreCompact` | Saves task progress to disk when a session ends or context is compacted. On Stop, computes session-end heuristics (outcome, duration, post-mortem). Cleans up stale files older than 7 days. |
| **Progress Load** | `SessionStart` | Restores prior progress into context when a session starts or resumes. Priority: exact session match > same branch match > fallback index. |
| **Constraint Check** | `PreToolUse` (Write/Edit) | Blocks or warns when a file write violates architectural rules defined in `constraints.json`. Supports pattern-based, import-boundary, semantic, and cross-file rule types. |
| **Team Task Verify** | `TaskCompleted` | Emits team analytics with advisory signals (recent violations, loops) for multi-agent coordination. |
| **Team Idle Check** | `TeammateIdle` | Tracks agent idle events for team-mode observability. |

### Commands

| Command | Description |
|---------|-------------|
| `/harness [task]` | Start a harness-guided development cycle. Walks through brainstorming, planning, execution, verification, code review, and branch finishing — with progress tracking and loop recovery throughout. |
| `/harness-auto [task]` | Fully autonomous mode — no human intervention required. At every decision point, Claude self-reviews, forms an expert recommendation, and proceeds. Creates a PR automatically when done. Has 11 explicit overrides replacing human gates. |
| `/harness-status [flags]` | Dashboard showing session state, guardrail activity, session history, trends, and post-mortems. Flags: `--progress`, `--constraints`, `--analytics`, `--trends`, `--postmortem [id]`, `--team`, `--reset-loops`. |
| `/harness-cleanup [flags]` | Remove stale harness state files. Flags: `--all`, `--progress`, `--loops`, `--analytics`, `--dry-run`. Archives events older than 90 days. |

### Skills

| Skill | When It Activates |
|-------|-------------------|
| `harness-orchestration` | Maintains harness awareness during `/harness` — updates progress at phase transitions, handles loop recovery, invokes simplify after execution. |
| `harness-orchestration-auto` | Same as above for `/harness-auto` — replaces all human gates with self-review and documented expert judgment. |
| `progress-tracking` | Teaches structured progress files that survive context compaction and session restarts. |
| `loop-recovery` | Activated on loop detection. Guides recovery with level-specific strategies: read more context at Level 3, save progress and escalate at Level 4. |
| `constraint-setup` | Guides creation of `.claude/harness/constraints.json` with all rule types including semantic and cross-file constraints. |

## Installation

```bash
/plugin install harness
```

### Requirements

- **`jq`** — required by hook scripts for JSON parsing. Install with `brew install jq` (macOS) or `apt install jq` (Linux).
- **superpowers plugin** — required for `/harness` and `/harness-auto` orchestration. The always-on hooks work without it.

### Optional Integrations

- **atlassian plugin** — pull Jira ticket context into `/harness` workflows and update ticket status on completion.
- **code-simplifier plugin** — auto-simplify changed files after execution completes.

## Quick Start

### Interactive (with human input)

```
/harness Fix the login timeout bug
```

Claude will brainstorm the approach with you, ask clarifying questions, propose a design, write a plan, execute it, and walk you through code review and PR creation.

### Autonomous (no human input)

```
/harness-auto Add rate limiting to the /api/users endpoint
```

Claude will research the codebase, make all design decisions autonomously, implement the solution, self-review, and create a PR — all without asking for input. Decisions are documented in the progress file for post-hoc review.

## How Loop Detection Works

The loop detector tracks the last 20 tool calls in a rolling window and watches for three patterns:

| Pattern | Description |
|---------|-------------|
| **Same-target repetition** | Same tool used on the same file repeatedly in the last 10 calls |
| **Error echo** | Same error message appearing repeatedly in the last 10 calls |
| **Edit-test-fail cycle** | Edit/Write followed by a test command followed by an error, repeated |

### Graduated Escalation

Each pattern has independent thresholds per escalation level:

| Level | Name | same-target | error-echo | edit-test-fail | Behavior |
|-------|------|-------------|------------|----------------|----------|
| 1 | Nudge | 3 | 2 | 2 | Advisory message, no event emitted |
| 2 | Warn | 4 | 3 | 3 | `LOOP DETECTED` + loop-recovery skill |
| 3 | Redirect | 6 | 5 | 4 | Escalated warning, must change strategy entirely |
| 4 | Circuit breaker | 8 | 7 | 5 | Stop all work, save progress, escalate to user |

When multiple patterns fire simultaneously, the highest-severity match wins.

### Budget Tracking

A monotonic tool call counter fires advisories at fixed thresholds:

| Calls | Level | Message |
|-------|-------|---------|
| 50 | Advisory | Stay focused on completing the current task |
| 100 | Warning | Prioritize wrapping up |
| 150 | Critical | Finish current work immediately and save progress |

Each advisory fires exactly once (== not >=).

## How Git Checkpointing Works

After every passing test run, the checkpoint hook:

1. Checks if harness is active and the session has changes
2. Verifies the rate limit (max one checkpoint per 5 minutes)
3. Creates a stash commit with `git stash create` + `git stash store` (non-destructive, doesn't touch the working tree)
4. Emits a `checkpoint.created` analytics event with the stash hash

Checkpoints can be recovered via `git stash list` (entries prefixed with `harness-checkpoint:`) and `git stash apply stash@{N}`. The loop-recovery skill references these for rollback during stuck states.

## How Progress Tracking Works

Progress files are stored at `.claude/harness/progress/{branch}--{session-prefix}.md` and contain:

- **Current Status** — What's happening right now
- **Completed** — What's been done (with implementation details)
- **Next Steps** — Actionable items remaining
- **Key Decisions** — Decisions made and WHY
- **Key Files** — Important file paths
- **Agent Outcome** — success, partial, failed, or abandoned

The `Stop` and `PreCompact` hooks save progress automatically. The `SessionStart` hook restores it with priority-based loading (exact session > same branch > fallback index). This means task context survives both context compaction and session restarts.

### Session-End Heuristics

On session stop, the harness computes a heuristic outcome by analyzing:

- Whether tests are passing (from loop state)
- Whether a PR was created (via `gh pr list`)
- Whether the agent marked progress complete
- Unresolved loops and constraint violations
- Compaction count

The heuristic outcome (success/partial/failed) is compared against the agent's self-reported outcome. Disagreement triggers a post-mortem.

### Post-Mortems

Automatically generated for "interesting" sessions — those with loops, blocked constraint violations, outcome disagreement, test failures, or high compaction (3+). Stored at `.claude/harness/analytics/postmortems/{branch}--{session}.md` with:

- Session metadata and duration
- Event timeline
- Loops and constraint violations tables
- Outcome analysis (agent vs heuristic)
- Signal summary

## Setting Up Constraints

Constraints enforce architectural boundaries at write time. Create `.claude/harness/constraints.json` in your project root (or use the `constraint-setup` skill for guided setup):

```json
{
  "rules": [
    {
      "name": "no-cross-layer-imports",
      "type": "import-boundary",
      "description": "API layer must not import from data layer directly",
      "deny": { "from": "src/api/**", "import": "src/data/**" },
      "severity": "block"
    },
    {
      "name": "no-env-in-source",
      "type": "file-pattern",
      "description": "Source files must not read env vars directly — use config module",
      "deny": { "in": "src/**", "pattern": "process\\.env\\." },
      "severity": "warn"
    }
  ]
}
```

### Rule Types

| Type | Purpose | Fields | Severity |
|------|---------|--------|----------|
| `import-boundary` | Prevent one module from importing another | `deny.from` (glob), `deny.import` (glob) | block, warn |
| `file-pattern` | Prevent patterns from appearing in files | `deny.in` (glob), `deny.pattern` (regex) | block, warn |
| `custom` | Same as `file-pattern`, for project-specific rules | `deny.in` (glob), `deny.pattern` (regex) | block, warn |
| `semantic` | LLM-evaluated code quality rules | `check.in` (glob), `check.prompt` (question) | block only |
| `cross-file` | Enforce invariants across multiple files | `check.in` (glob), `check.verify` (instruction), `check.context_files` (globs) | block only |

Semantic and cross-file rules require an agent hook in `.claude/settings.json` (the `constraint-setup` skill manages this automatically).

### Security Constraint Recipes

Ready-to-use security rules are shipped at `examples/constraints.security.json`:

| Rule | Type | Severity |
|------|------|----------|
| `no-hardcoded-secrets` | Detects hardcoded passwords, API keys, tokens | block |
| `no-console-in-production` | Flags console.log/warn/error in `src/` | warn |
| `no-eval` | Prevents `eval()` usage | block |
| `no-sql-string-concat` | Detects SQL queries built with string concatenation | block |
| `no-any-type` | Flags TypeScript `any` type usage | warn |

Copy the rules you need into your project's `.claude/harness/constraints.json` and adjust the `in` glob patterns to match your project structure.

## Analytics

All hook activity is recorded as append-only JSONL at `.claude/harness/analytics/events.jsonl`. Event types:

| Event | Source | Key Fields |
|-------|--------|------------|
| `session.start` | progress-load | `resumed` |
| `session.compact` | progress-save | `compaction_count` |
| `session.end` | progress-save | `agent_outcome`, `heuristic_outcome`, `outcome_agreement`, `tests_passing`, `pr_created`, `duration_seconds` |
| `loop.detected` | loop-detect | `pattern`, `level`, `tool`, `file`, `count` |
| `budget.advisory` | loop-detect | `count`, `level` |
| `checkpoint.created` | checkpoint | `trigger`, `stash_hash` |
| `constraint.violation` | constraint-check | `rule`, `file`, `severity`, `decision` |
| `team.task_completed` | team-task-verify | `task_id`, `advisory_signals` |
| `team.agent_idle` | team-idle-check | — |

Query with `jq`:

```bash
# Count loops in current session
jq -s '[.[] | select(.event=="loop.detected" and .session_id=="SESSION_ID")] | length' .claude/harness/analytics/events.jsonl

# List all constraint violations
jq 'select(.event=="constraint.violation")' .claude/harness/analytics/events.jsonl

# View session outcomes
jq 'select(.event=="session.end") | {session_id, heuristic_outcome, agent_outcome, outcome_agreement}' .claude/harness/analytics/events.jsonl
```

Events older than 90 days are archived to `events.archived.jsonl` by `/harness-cleanup --analytics`.

## Team Mode

When using Claude Code's multi-agent features, the harness provides:

- **Task completion signals**: `team.task_completed` events with advisory signals (recent violations, loops on the branch) so the orchestrator can decide whether to accept a task agent's output.
- **Idle tracking**: `team.agent_idle` events for scheduling decisions.
- **Shared analytics**: All events include `scope` (single/team), `branch`, and `worktree` fields for filtering.
- **File ownership**: The `/harness` orchestration skills guide decomposing work so no two tasks modify the same file.

Set `team_context: true` in the progress file frontmatter when working in team mode.

## State Files

| File | Location | Lifetime |
|------|----------|----------|
| Progress files | `.claude/harness/progress/{branch}--{session}.md` | 7 days (auto-cleaned) |
| Analytics | `.claude/harness/analytics/events.jsonl` | 90 days (then archived) |
| Post-mortems | `.claude/harness/analytics/postmortems/` | 90 days |
| Loop state | `/tmp/harness-loop-state-{session}.jsonl` | Session (ephemeral) |
| Budget counter | `/tmp/harness-budget-{session}` | Session (ephemeral) |
| Checkpoint timestamp | `/tmp/harness-checkpoint-ts-{session}` | Session (ephemeral) |
| Constraints | `.claude/harness/constraints.json` | Permanent (committed to repo) |

## Running Tests

```bash
cd harness

# Run all tests
for f in tests/test-*.sh; do bash "$f"; done

# Run individual test suites
bash tests/test-loop-detect.sh       # Graduated loop detection + budget tracking
bash tests/test-checkpoint.sh        # Git checkpointing
bash tests/test-constraint-check.sh  # Constraint enforcement
bash tests/test-progress-save.sh     # Progress save + session-end heuristics
bash tests/test-progress-load.sh     # Progress restoration
bash tests/test-session-end.sh       # Session-end heuristic computation
bash tests/test-postmortem.sh        # Post-mortem generation
bash tests/test-team-hooks.sh        # Team mode analytics
bash tests/test-lib.sh               # Shared utilities
```

Tests are hermetic — they create temporary git repos, require no external dependencies beyond `bash`, `jq`, and `git`, and clean up after themselves.
