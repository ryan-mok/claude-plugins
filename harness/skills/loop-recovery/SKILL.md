---
name: loop-recovery
description: This skill should be used when a "LOOP DETECTED" message appears in context, when the agent has tried the same approach multiple times without success, when stuck in an edit-test-fail cycle, or when the harness loop detection hook fires. Provides structured recovery strategies to break out of repetitive failing patterns.
---

# Loop Recovery

When loop detection fires, the current approach is not working. Continuing to retry wastes tokens and produces broken output. Follow this structured recovery process.

## Escalation Levels

The harness uses a 4-level graduated response system. The level determines how urgently you must change course:

- **Level 1 (nudge):** A "Harness notice" advisory. You are approaching a loop. Proactively try a different approach before the pattern escalates.
- **Level 2 (warn):** A "LOOP DETECTED" warning. The current approach has clearly failed. Follow the recovery process below to find a fundamentally different strategy.
- **Level 3 (redirect):** A "LOOP DETECTED (escalated)" warning. You MUST stop working on the current file/approach immediately. Read different files for context. The current strategy has fundamentally failed — do not continue with variations of it. Change your approach entirely.
- **Level 4 (circuit breaker):** A "LOOP DETECTED (circuit breaker)" critical alert. STOP ALL WORK on this file. Save your progress immediately, document what was attempted and why it failed, and escalate to the user. Do not attempt any further fixes.

At Level 3 or above, you must read new files and change strategy entirely before making any further edits. At Level 4, your only action should be to save progress and ask the user for help.

## Recovery Process

### Step 1: Diagnose the loop

Identify and name:
- What was attempted (the specific approach, not just "I tried to fix it")
- Why it failed each time (the specific error or behavior)
- Whether the error changed between attempts or stayed identical

### Step 2: Generate alternatives

Identify at least 2 fundamentally different approaches. "Fundamentally different" means changing the strategy, not tweaking the same code:

- If editing a file repeatedly fails: read more of the surrounding code for context. The bug may be elsewhere.
- If a test keeps failing: question whether the test expectation is correct, or whether the test is testing the wrong thing.
- If an import/dependency is broken: check if the dependency exists, is installed, or has a different API than assumed.
- If a type error persists: re-read the type definitions rather than guessing at fixes.

### Step 3: Decide next action

Choose one of these paths:

1. **Try a different approach** — pick the most promising alternative from step 2 and implement it
2. **Revert and simplify** — check `git stash list` for harness checkpoints (entries starting with `harness-checkpoint:`) that represent the last known good state. Use `git stash apply stash@{N}` to restore. If no checkpoints exist, use git diff/reset to go back to the last commit.
3. **Read more context** — the fix may require understanding code that hasn't been read yet. Read related files, type definitions, or documentation before attempting another fix.
4. **Escalate to the human** — if 2+ fundamentally different approaches have already been tried and failed, ask the user for guidance. Explain what was tried and why it failed.

### Step 4: Reset loop detection

After choosing a new approach, the loop detection state resets naturally as new tool calls with different patterns replace the old ones in the rolling window.

## Anti-patterns

- Do NOT retry the same approach with minor variations (changing variable names, reordering lines)
- Do NOT add more error handling around the same broken logic
- Do NOT suppress or ignore the error to make the test pass
- Do NOT skip the failing test and move on without fixing the underlying issue
