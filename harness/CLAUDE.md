# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with the harness plugin.

## Overview

Harness wraps the superpowers development workflow with autonomous runtime guardrails: loop detection, cross-session progress tracking, architectural constraint enforcement, and team-mode analytics.

## Running Tests

All tests are standalone bash scripts:

```bash
# Run a single test
bash tests/test-loop-detect.sh        # from harness/
bash harness/tests/test-loop-detect.sh # from repo root

# Run all tests
for f in tests/test-*.sh; do bash "$f"; done
```

Tests are hermetic — they create temporary git repos, require no external dependencies, and clean up after themselves.

## Plugin Structure

```
harness/
├── hooks/
│   ├── hooks.json      # Hook event registrations and timeouts
│   └── scripts/        # Hook implementations (*.sh) + shared lib.sh
├── commands/       # User-facing slash commands (/harness, /harness-auto, etc.)
├── skills/         # Workflow guidance skills (orchestration, progress, loop recovery)
└── tests/          # Hermetic bash test suite with fixtures/
```

## Hook System

Hooks are registered in `hooks/hooks.json` and fire on Claude Code events. Each hook has its own activation guard:
- `loop-detect.sh` — only runs if a non-fallback progress file exists for the current session prefix
- `constraint-check.sh` — only runs if `.claude/harness/constraints.json` exists (independent of harness session)
- `progress-save.sh`, `progress-load.sh` — always run but are no-ops without relevant state

| Hook | Event | Purpose |
|------|-------|---------|
| `loop-detect.sh` | PostToolUse | Detects same-file repetition, error echo, edit-test-fail cycles |
| `progress-save.sh` | Stop, PreCompact | Persists progress; on Stop also computes session-end heuristics (outcome, duration, postmortem) using background `gh pr list` |
| `progress-load.sh` | SessionStart | Restores progress from prior sessions |
| `constraint-check.sh` | PreToolUse (Write/Edit) | Validates writes against `.claude/harness/constraints.json` |
| `team-task-verify.sh` | TaskCompleted | Team mode analytics |
| `team-idle-check.sh` | TeammateIdle | Team mode idle tracking |

All hooks use `scripts/lib.sh` for shared utilities (JSON escaping, git root resolution, worktree detection, analytics emission).

## State & Data

- **Progress files:** `.claude/harness/progress/{branch}--{session-prefix}.md` — YAML frontmatter + markdown sections, survive context compaction
- **Analytics:** `.claude/harness/analytics/events.jsonl` — append-only JSONL, queried with `jq`
- **Loop state:** `/tmp/harness-loop-state-{SESSION_PREFIX}.jsonl` — ephemeral, per-session, rolling 20-entry window
- **Constraints:** `.claude/harness/constraints.json` — import-boundary, file-pattern, semantic, and cross-file rules with block/warn severity

## Key Design Decisions

- Hooks are git-worktree-aware (use `git rev-parse --git-common-dir` for root resolution)
- JSONL chosen for analytics to allow fast append without full-file parsing
- Loop state is ephemeral (`/tmp/`) because it's session-local
- `/harness-auto` has 11 explicit autonomous overrides replacing human gates with self-review + expert judgment
- Progress files bridge context compaction and session restarts

## Gotchas

- Hook scripts receive their input as JSON on stdin (piped by Claude Code runtime). All hooks parse with `jq`.
- PreToolUse hooks block actions by outputting JSON to stdout: `{"decision":"block","reason":"..."}`. Returning nothing or `{"decision":"allow"}` permits the action.
- Branch names with slashes (e.g. `feat/foo`) are sanitized to dashes (`feat-foo`) for progress file paths — variable `BRANCH_SAFE` in hooks.
- On macOS, `/tmp` is a symlink to `/private/tmp`. All path comparisons must resolve symlinks with `pwd -P` to avoid mismatches.

## Test Conventions

- Each test file creates a temporary git repo and resolves symlinks for macOS compatibility
- Helper functions: `assert_eq`, `assert_exit_code`, `assert_file_exists`, `assert_contains`, `assert_file_not_exists`
- Test fixtures live in `tests/fixtures/` as sample JSON hook inputs
- Pass/fail summary printed at end; exit code 1 if any failures
