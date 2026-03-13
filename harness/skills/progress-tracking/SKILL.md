---
name: progress-tracking
description: This skill should be used when working on a long task that spans multiple tool calls, when context compaction is likely, when the harness orchestration skill is active, or when the agent needs to save progress for a future session to continue. Teaches how to write and maintain structured progress files that survive context compaction and session boundaries.
---

# Progress Tracking

Progress files bridge context boundaries — compaction events, session restarts, and multi-agent handoffs. The harness hooks handle loading progress on startup and saving a git-based fallback on exit. This skill teaches how to write rich, agent-maintained progress files that are far more useful than the fallback.

## When to Write Progress

Write or update the progress file at these natural milestones:
- After completing each step in an implementation plan
- After making a key decision that affects future work
- Before a known long-running operation (test suites, builds)
- When switching between different parts of a task

## Progress File Location

Write progress to: `.claude/harness/progress/{branch}--{session-prefix}.md`

To determine the file path:
- Branch: current git branch name with `/` replaced by `-`
- Session prefix: first 8 characters of the session ID (available in hook context, or use an arbitrary prefix if unknown)

## Progress File Format

Follow this structure exactly — the harness hooks parse specific headings:

```
# Harness Progress
**Updated:** {ISO 8601 timestamp}
**Branch:** {branch name}
**Session:** {session prefix}
**Objective:** {one-line description of the overall task}

## Current Status
{1-2 sentences describing what is happening right now}

## Completed
- [x] {completed item with enough detail to not need re-reading the code}
- [x] {another completed item}

## Next Steps
- [ ] {next thing to do, specific enough to act on}
- [ ] {following step}

## Key Decisions
- {decision made and WHY — the "why" is critical for a fresh context window}

## Key Files
- {path/to/important/file — helps a fresh context find relevant code fast}
```

## Writing Effective Progress

**Current Status:** Write what a developer picking up this task RIGHT NOW needs to know. Not what was done, but where things stand.

**Completed items:** Include enough detail that a fresh context does not need to re-read the implementation. "Implemented user auth" is bad. "Implemented JWT-based auth in src/auth/jwt.ts with refresh token rotation" is good.

**Key Decisions:** Always include WHY. "Using JSONL for state tracking" is incomplete. "Using JSONL for state tracking — fast append without needing to parse the full file, and jq can process it line-by-line" tells a fresh context why this choice was made and when to reconsider it.

**Next Steps:** Make these actionable. "Continue working on the feature" is useless. "Write tests for the constraint-check.sh glob matching logic" is actionable.

## Commit Alongside Progress

Commit early and often with descriptive messages. Git history is the most durable form of progress. The progress file supplements git with the semantic context that commit messages lack — why decisions were made, what the plan is, and what a fresh context needs to know.
