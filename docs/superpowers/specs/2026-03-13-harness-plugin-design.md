# Harness Plugin — v1 Design Spec

## Overview

The `harness` plugin implements harness engineering around existing Claude Code tools and the superpowers workflow. It adds autonomous runtime infrastructure — deterministic guardrails, progress persistence, and architectural enforcement — that make agents reliable without human supervision at every step.

The harness wraps **above and below** superpowers:
- **Above:** A `/harness` entry point and orchestration skill that sequence phases and inject context
- **Below:** Always-on hooks that monitor every tool call, acting as guardrails on the agent's natural behavior

## Architecture

```
┌─────────────────────────────────────────────┐
│  /harness command (entry point)             │  ← Harness: entry + sequencing
│  harness-orchestration skill                │
├─────────────────────────────────────────────┤
│  superpowers skills (brainstorm, plan,      │  ← Superpowers: workflow
│  execute, verify, review, finish)           │
├─────────────────────────────────────────────┤
│  Agent's natural behavior                   │  ← Claude: write → test → fix
│  (write → test → fix → repeat)             │
├─────────────────────────────────────────────┤
│  Harness hooks (always-on guardrails)       │  ← Harness: monitoring + enforcement
│  - loop-detect.sh on every tool call        │
│  - constraints on every write/edit          │
│  - progress on compact/stop/start           │
└─────────────────────────────────────────────┘
```

## Components

### 1. Loop Detection

**Problem:** Agents get stuck in cycles — editing the same file, running the same failing test, retrying the same approach. This is the #1 cause of wasted tokens and broken output.

**Primitive:** PostToolUse command hook + recovery skill.

**Hook: `loop-detect.sh`**

Fires on every tool call (`matcher: *`). Appends a fingerprint (tool name + target file + truncated error/result) to a rolling state file at `/tmp/harness-loop-state-${SESSION_ID}.jsonl`. Keeps the last 20 entries.

Detection patterns:
- **Same-target repetition:** Same tool + same file path 3+ times in last 10 calls
- **Error echo:** Same error message substring appears 3+ times
- **Edit-test-fail cycle:** Write/Edit → Bash(test) → fail → repeat, 3+ iterations

When a pattern triggers, the hook exits with code 2 and returns a systemMessage:

> "LOOP DETECTED: You have attempted [pattern description] [N] times. STOP. Do not retry the same approach. Consult the harness:loop-recovery skill."

**Performance:** Must complete in <100ms. Uses `jq` for JSONL append and pattern matching. No LLM reasoning in the hot path.

**Skill: `loop-recovery`**

Teaches the agent a structured recovery process:
1. Name what you tried and why it failed
2. Identify at least 2 fundamentally different approaches
3. If you've already tried 2+ different approaches, escalate to the human
4. Consider: revert to last known good state (`/rewind`), read more context, simplify the problem

### 2. Cross-Session Progress

**Problem:** Long tasks span multiple sessions. When context compacts or a new session starts, the agent loses track of what was done, what's next, and what decisions were made.

**Primitive:** SessionStart + PreCompact + Stop command hooks + skill.

**Progress files** are scoped by branch and session to prevent multi-agent conflicts:

```
.claude/harness/progress/
├── main--abc123.md              # session abc123 on main branch
├── feat-loop-detect--def456.md  # session def456 on feature branch
└── _index.md                    # auto-generated summary of all sessions
```

Naming convention: `{branch-name}--{session-id-prefix}.md`

**Hook: `progress-save.sh`** (Stop + PreCompact)

Captures a progress snapshot:
- Reads recent git log (last 5 commits)
- Writes structured markdown: current status, completed items, next steps, key decisions, key files touched
- Regenerates `_index.md` with all active sessions

**Hook: `progress-load.sh`** (SessionStart)

On session start (including after compaction and resume):
- Loads the session-specific progress file if resuming
- Otherwise loads `_index.md` so the agent can see what other sessions have been working on
- Outputs as systemMessage

**Progress file format:**

```markdown
# Harness Progress
**Updated:** 2026-03-13T14:30:00
**Branch:** feat-loop-detect
**Session:** def456
**Objective:** Implement loop detection hook

## Current Status
Writing the loop detection bash script...

## Completed
- [x] Plugin scaffold created
- [x] hooks.json configured

## Next Steps
- [ ] Write loop detection bash script
- [ ] Write recovery skill

## Key Decisions
- Using JSONL for state tracking (fast append, easy to parse)
- Session-scoped progress files to avoid multi-agent conflicts

## Key Files
- hooks/scripts/loop-detect.sh
- skills/loop-recovery/SKILL.md
```

**Skill: `progress-tracking`**

Teaches agents to proactively write progress entries at natural milestones:
- Update progress file after completing each plan step
- Record why decisions were made, not just what was done
- Note anything a fresh context window would need to know
- Commit early and often with descriptive messages

**Cleanup:** Progress files older than 7 days are noted as stale in `_index.md`. The `/harness-status` command can show and prune them.

### 3. Architectural Constraint Enforcement

**Problem:** CLAUDE.md rules are suggestions that rely on the LLM honoring text instructions. For critical boundaries, you need deterministic enforcement.

**Primitive:** PreToolUse prompt hook + setup skill.

**Hook: prompt-based PreToolUse** on `Write|Edit`

A prompt hook that reads `.claude/harness/constraints.json` and evaluates the proposed file change against the rules. Uses LLM reasoning because constraints are often semantic ("this file shouldn't contain business logic"), not just syntactic.

**Constraint config** at `.claude/harness/constraints.json`:

```json
{
  "rules": [
    {
      "name": "no-cross-module-imports",
      "type": "import-boundary",
      "description": "API layer must not import from data layer directly",
      "deny": { "from": "src/api/**", "import": "src/data/**" },
      "severity": "block"
    },
    {
      "name": "no-env-in-source",
      "type": "file-pattern",
      "description": "Source files must not read env vars directly",
      "deny": { "in": "src/**", "pattern": "process\\.env\\." },
      "severity": "warn"
    },
    {
      "name": "tests-must-use-fixtures",
      "type": "custom",
      "description": "Tests must not create database connections directly",
      "deny": { "in": "tests/**", "pattern": "new DatabaseConnection" },
      "severity": "block"
    }
  ]
}
```

**Severity levels:**
- `block` — hook returns `deny`, preventing the write
- `warn` — hook returns `allow` but injects a systemMessage explaining the violation

**Skill: `constraint-setup`**

Teaches how to define constraints for a project:
- Analyze existing architecture to identify boundaries worth enforcing
- Write effective constraint rules (type, pattern, severity)
- When to use `block` vs `warn`
- How constraints interact with the rest of the harness

**Scope:** Only gates new writes. Does not enforce constraints on existing code.

### 4. Harness Orchestration

**Problem:** The harness guardrails are always-on, but there's no entry point that says "take this task and run the full harness-aware development cycle."

**Primitive:** `/harness` command + orchestration skill.

**Command: `/harness`**

Accepts flexible input:
- `/harness Fix the login timeout bug` — free text description
- `/harness PROJ-1234` — Jira ticket ID (pulls context via atlassian plugin if installed)
- `/harness` with no args — asks what you're working on

On kickoff:
1. Gather context — if Jira ticket, pull description/comments/acceptance criteria
2. Initialize progress — create session progress file, record task objective
3. Check constraints — load constraints.json if it exists
4. Hand off to superpowers — invoke brainstorming skill with gathered context

**Skill: `harness-orchestration`**

Teaches the agent to maintain harness awareness throughout the superpowers workflow:
- Save progress at each phase transition
- After execution completes, run `/simplify` on changed files
- On completion, update progress file to "done" and optionally update Jira ticket
- If loop detection fires during execution, follow the recovery skill before continuing

**Orchestrated flow:**

```
/harness PROJ-1234
    │
    ├─ Pull Jira context (if atlassian plugin available)
    ├─ Initialize progress file
    ├─ Check constraints loaded
    │
    ▼
superpowers:brainstorming (with task context injected)
    ▼
superpowers:writing-plans
    ▼
superpowers:executing-plans
    │  ├─ Loop detection active (hook, always-on)
    │  ├─ Constraint enforcement active (hook, always-on)
    │  └─ Progress saved at each step (skill behavior)
    ▼
superpowers:verification-before-completion
    ▼
/simplify on changed files
    ▼
superpowers:requesting-code-review
    ▼
superpowers:finishing-a-development-branch
    │
    ├─ Progress file marked complete
    └─ Jira ticket updated (optional)
```

### 5. Harness Dashboard

**Problem:** The harness does things in the background. The user needs visibility.

**Primitive:** `/harness-status` command.

Assembles a diagnostic view from the harness state files:

```
## Harness Status

### Loop Detection
State: Active
Recent tool calls tracked: 14
Loops detected this session: 0
State file: /tmp/harness-loop-state-abc123.jsonl

### Progress
Last saved: 2026-03-13T14:30:00
Branch: feat-loop-detect
Active sessions on this project: 2
  - feat-loop-detect--def456 (this session)
  - main--ghi789 (stale, 3 days ago)

### Constraints
Rules loaded: 3
Violations blocked this session: 1
  - no-cross-module-imports (src/api/handler.ts → src/data/db.ts)
Warnings issued: 0
```

Optional flags:
- `/harness-status --progress` — show full progress file contents
- `/harness-status --constraints` — show all constraint rules
- `/harness-status --reset-loops` — clear loop detection state

## Plugin Structure

```
harness/
├── .claude-plugin/
│   └── plugin.json
├── hooks/
│   ├── hooks.json
│   └── scripts/
│       ├── loop-detect.sh
│       ├── progress-save.sh
│       └── progress-load.sh
├── skills/
│   ├── loop-recovery/
│   │   └── SKILL.md
│   ├── progress-tracking/
│   │   └── SKILL.md
│   ├── constraint-setup/
│   │   └── SKILL.md
│   └── harness-orchestration/
│       └── SKILL.md
├── commands/
│   ├── harness.md
│   └── harness-status.md
└── README.md
```

**hooks.json** registers:
- `PostToolUse *` → `loop-detect.sh`
- `Stop *` → `progress-save.sh`
- `PreCompact *` → `progress-save.sh`
- `SessionStart startup|resume|compact` → `progress-load.sh`
- `PreToolUse Write|Edit` → prompt hook (constraint enforcement, inline)

## Dependencies

**Required:**
- superpowers plugin (workflow skills)

**Optional (enhanced experience):**
- atlassian plugin (Jira ticket context for `/harness` command)
- code-simplifier plugin (`/simplify` on completion)
- pr-review-toolkit plugin (enhanced review on completion)

## Out of Scope for v1

The following harness components are deferred to future versions:
- Adaptive tool selection (pruning available tools per task phase)
- Model routing (dynamically choosing Opus vs Sonnet per subtask)
- Garbage collection agent (periodic audits of docs/tests/rules)
- Self-repair / automated rollback
- Observability telemetry (cross-session success/failure tracking)
- Harness self-improvement (analyzing failures to propose harness upgrades)
