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

## Hook I/O Contract

All hooks receive JSON via stdin from Claude Code. Key fields:

```json
{
  "session_id": "abc123-def456-...",
  "transcript_path": "/path/to/transcript.txt",
  "cwd": "/current/working/dir",
  "hook_event_name": "PostToolUse",
  "tool_name": "Edit",
  "tool_input": { "file_path": "/src/api/handler.ts", "old_string": "...", "new_string": "..." },
  "tool_result": "File edited successfully"
}
```

**Session ID:** Provided by Claude Code in the `session_id` field of every hook input. The first 8 characters are used as the session prefix for progress file naming.

**Command hook output:** Return JSON via stdout. Exit code 0 = success (stdout shown in transcript). Exit code 2 = blocking error (stderr fed back to Claude as context).

```json
{
  "systemMessage": "Message injected into Claude's context",
  "continue": true,
  "suppressOutput": false
}
```

**PreToolUse hook output** (for constraint enforcement):

```json
{
  "hookSpecificOutput": {
    "permissionDecision": "deny",
    "updatedInput": null
  },
  "systemMessage": "CONSTRAINT VIOLATION: no-cross-module-imports — API layer must not import from data layer directly"
}
```

**Prompt hooks** differ from command hooks: instead of running a shell script, they send a prompt to the LLM for evaluation. Configured in hooks.json with `"type": "prompt"` and a `"prompt"` field instead of `"type": "command"`. The LLM returns a structured decision. Prompt hooks have a default 30s timeout vs 60s for command hooks.

## Components

### 1. Loop Detection

**Problem:** Agents get stuck in cycles — editing the same file, running the same failing test, retrying the same approach. This is the #1 cause of wasted tokens and broken output.

**Primitive:** PostToolUse command hook + recovery skill.

**Hook: `loop-detect.sh`**

Fires on every tool call (`matcher: *`). Reads `session_id` from stdin JSON. Appends a fingerprint (tool name + target file + truncated error/result) to a rolling state file at `/tmp/harness-loop-state-${SESSION_ID_PREFIX}.jsonl` (first 8 chars of session_id). Keeps the last 20 entries.

Detection patterns:
- **Same-target repetition:** Same tool + same file path 4+ times in last 10 calls (note: editing the same file 3 times is normal during TDD — threshold is 4 to reduce false positives)
- **Error echo:** Same error message substring (first 100 chars) appears 3+ times in last 10 calls
- **Edit-test-fail cycle:** Write/Edit → Bash → non-zero exit, repeated 3+ times on the same file (the Bash call is identified as a test by checking if the command contains common test runner names: `test`, `jest`, `pytest`, `cargo test`, `go test`, `npm test`, `vitest`, etc.)

When a pattern triggers, the hook exits with code 0 and returns JSON on stdout with a `systemMessage` field:

```json
{
  "systemMessage": "LOOP DETECTED: You have edited src/api/handler.ts 4 times with similar errors. STOP. Do not retry the same approach. Use the harness:loop-recovery skill to find a fundamentally different approach."
}
```

Note: exit code 0, not 2. This is PostToolUse — the tool already ran. We're injecting guidance into context, not blocking an operation.

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

**Two-part responsibility model:** The `progress-tracking` skill teaches the agent to maintain the progress file (writing semantic fields like "Current Status," "Next Steps," and "Key Decisions"). The hooks handle lifecycle boundaries — ensuring the file is loaded on start and that a git-based fallback snapshot exists on stop/compact even if the agent didn't write one.

**Hook: `progress-save.sh`** (Stop + PreCompact)

On session end or pre-compaction. **This hook always approves** — it saves state but never blocks the agent from stopping.

1. Reads `session_id` and `cwd` from stdin JSON
2. If the agent already wrote a progress file (the skill instructs this), leave it as-is
3. If no progress file exists for this session, generate a minimal fallback from git:
   - Branch name, last 5 commits, list of files changed in this session (via `git diff --name-only`)
   - This fallback is less rich than agent-written progress but better than nothing
4. Regenerates `_index.md` by listing all progress files with their `**Updated:**` timestamps and first line of `## Current Status`

**Hook: `progress-load.sh`** (SessionStart)

On session start (including after compaction and resume):
- Reads `session_id` from stdin JSON
- If a progress file exists for this session ID prefix, outputs its contents as `systemMessage`
- Otherwise, if `_index.md` exists, outputs it so the agent can see what other sessions have been working on
- Returns exit code 0 with JSON: `{"systemMessage": "<file contents>"}`

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

**Gitignore:** The `.claude/harness/progress/` directory should be added to `.gitignore`. Progress files are ephemeral session state — they should not appear in diffs, PRs, or the repo history. The hook scripts will create the directory if it does not exist.

### 3. Architectural Constraint Enforcement

**Problem:** CLAUDE.md rules are suggestions that rely on the LLM honoring text instructions. For critical boundaries, you need deterministic enforcement.

**Primitive:** PreToolUse command hook + setup skill.

**Hook: `constraint-check.sh`** on `Write|Edit`

A single deterministic command hook. All v1 constraint types (import-boundary, file-pattern, custom) are pattern-based and can be evaluated with glob matching and regex — no LLM reasoning needed. This keeps constraint enforcement fast (<50ms) and predictable.

The hook:
1. Reads the target file path from `tool_input.file_path` in stdin JSON
2. If `.claude/harness/constraints.json` does not exist, exits immediately (exit 0)
3. Checks each rule's `from`/`in` glob against the target file path. If no rules match, exits (exit 0)
4. For matching rules, evaluates the proposed content (`tool_input.new_string` for Edit, `tool_input.content` for Write) against the rule's `pattern` or `import` field using `grep -E`
5. If a `block` severity rule is violated: returns `permissionDecision: "deny"` with the rule name and description
6. If only `warn` severity rules are violated: returns `permissionDecision: "allow"` with a systemMessage warning
7. If no violations: exits (exit 0)

Semantic constraints ("this file shouldn't contain business logic") are deferred to v2, which will add a prompt hook for `custom-semantic` type rules.

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
- After execution completes, invoke the `simplify` skill on changed files (from code-simplifier plugin, if installed)
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
simplify skill on changed files (if code-simplifier installed)
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
│       ├── progress-load.sh
│       └── constraint-check.sh
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

**hooks.json:**

```json
{
  "description": "Harness engineering guardrails: loop detection, progress persistence, constraint enforcement",
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
            "timeout": 10
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
        "matcher": "startup|resume|compact",
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
    ]
  }
}
```

Note: Constraint enforcement is a single deterministic command hook in v1. All constraint types as defined (import-boundary, file-pattern, custom) are pattern-based and don't require LLM reasoning. A prompt hook for semantic constraints (`custom-semantic` type) is planned for v2.

**Runtime dependency:** `jq` is required for hook scripts (loop detection, progress save/load, constraint check). The `/harness-status` command should warn if `jq` is not found on the system PATH.

## Dependencies

**Required:**
- superpowers plugin (workflow skills)

**Optional (enhanced experience):**
- atlassian plugin (Jira ticket context for `/harness` command)
- code-simplifier plugin (simplify skill on completion)
- pr-review-toolkit plugin (enhanced review on completion)

**Graceful degradation:** The hooks (loop detection, progress, constraints) are fully independent and work without superpowers. The `/harness` command requires superpowers — if not installed, it should inform the user and suggest installing it. The `/harness` command detects Jira ticket IDs via the pattern `[A-Z][A-Z0-9]+-\d+` (e.g., `PROJ-1234`). If the atlassian plugin is not installed, it treats the ticket ID as a text label and proceeds without fetching context.

## Out of Scope for v1

The following harness components are deferred to future versions:
- Adaptive tool selection (pruning available tools per task phase)
- Model routing (dynamically choosing Opus vs Sonnet per subtask)
- Garbage collection agent (periodic audits of docs/tests/rules)
- Self-repair / automated rollback
- Observability telemetry (cross-session success/failure tracking)
- Harness self-improvement (analyzing failures to propose harness upgrades)
