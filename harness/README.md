# Harness

Harness engineering for Claude Code. Wraps the [superpowers](https://github.com/anthropics/claude-plugins-official/tree/main/superpowers) development workflow with autonomous runtime guardrails — loop detection, cross-session progress persistence, and architectural constraint enforcement.

## What It Does

Harness has two layers:

1. **Always-on hooks** that fire automatically on every tool call — no setup needed beyond installing the plugin.
2. **Commands** that orchestrate the full development lifecycle with harness awareness baked in.

### Always-On Hooks

| Hook | Event | What It Does |
|------|-------|-------------|
| **Loop Detection** | `PostToolUse` | Tracks tool calls in a rolling window. Detects three patterns: same file edited 4+ times, same error 3+ times, or edit-test-fail cycles. Fires a `LOOP DETECTED` warning when triggered. |
| **Progress Save** | `Stop`, `PreCompact` | Saves task progress to disk when a session ends or context is compacted. Cleans up stale files older than 7 days. |
| **Progress Load** | `SessionStart` | Restores prior progress into context when a session starts or resumes. |
| **Constraint Check** | `PreToolUse` (Write/Edit) | Blocks or warns when a file write violates architectural rules defined in `constraints.json`. |

### Commands

| Command | Description |
|---------|-------------|
| `/harness [task]` | Start a harness-guided development cycle. Walks through brainstorming, planning, execution, verification, code review, and branch finishing — with progress tracking and loop recovery throughout. |
| `/harness-auto [task]` | Same as `/harness` but fully autonomous — no human intervention required. At every decision point where `/harness` would ask for input, Claude instead self-reviews, forms an expert recommendation, and proceeds. Creates a PR automatically when done. |
| `/harness-status` | Show current harness state: loop detection activity, progress files, and constraint rules loaded. Supports `--progress`, `--constraints`, and `--reset-loops` flags. |
| `/harness-cleanup` | Remove stale harness state files (progress, loop state, constraint logs). Supports `--progress`, `--loops`, `--constraints`, and `--dry-run` flags. |

### Skills

| Skill | When It Activates |
|-------|-------------------|
| `harness-orchestration` | Maintains harness awareness during the `/harness` workflow — updates progress at phase transitions, handles loop recovery, invokes simplify after execution. |
| `harness-orchestration-auto` | Same as above but for `/harness-auto` — replaces all human gates with self-review and documented expert judgment. |
| `progress-tracking` | Teaches how to write and maintain structured progress files that survive context compaction. |
| `loop-recovery` | Activated when `LOOP DETECTED` fires. Guides structured recovery: diagnose the loop, generate fundamentally different alternatives, decide next action. |
| `constraint-setup` | Guides creation of `.claude/harness/constraints.json` for architectural boundary enforcement. |

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

## Setting Up Constraints

Constraints enforce architectural boundaries at write time. Create `.claude/harness/constraints.json` in your project root (or use `/harness:constraint-setup` for guided setup):

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

| Type | Purpose | `deny` Fields |
|------|---------|---------------|
| `import-boundary` | Prevent one module from importing another | `from` (glob), `import` (glob) |
| `file-pattern` | Prevent patterns from appearing in files | `in` (glob), `pattern` (regex) |
| `custom` | Same as `file-pattern`, for project-specific rules | `in` (glob), `pattern` (regex) |

### Severity Levels

- **`block`** — Prevents the write entirely. Use for critical architectural boundaries.
- **`warn`** — Allows the write but injects a warning. Use for guidelines that may have legitimate exceptions.

## How Progress Tracking Works

Progress files are stored at `.claude/harness/progress/{branch}--{session-prefix}.md` and contain:

- **Current Status** — What's happening right now
- **Completed** — What's been done (with implementation details)
- **Next Steps** — Actionable items remaining
- **Key Decisions** — Decisions made and WHY
- **Key Files** — Important file paths

The `Stop` and `PreCompact` hooks save progress automatically. The `SessionStart` hook restores it. This means task context survives both context compaction (long sessions) and session restarts.

## How Loop Detection Works

The loop detector tracks the last 20 tool calls in a rolling window and watches for three patterns:

1. **Same-target repetition** — Same tool used on the same file 4+ times in the last 10 calls
2. **Error echo** — Same error message appears 3+ times in the last 10 calls
3. **Edit-test-fail cycle** — Edit/Write followed by a test command followed by an error, repeated 3+ times

When a loop is detected, a `LOOP DETECTED` system message is injected. The `loop-recovery` skill then guides the agent to try a fundamentally different approach rather than retrying the same thing.

## Running Tests

```bash
cd harness
bash tests/test-loop-detect.sh
bash tests/test-progress-save.sh
bash tests/test-constraint-check.sh
```
