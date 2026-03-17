---
name: harness-orchestration
description: This skill should be used when the /harness command is invoked, when maintaining harness awareness throughout a superpowers workflow, when transitioning between workflow phases (brainstorming to planning to execution), or when the agent needs guidance on progress tracking during multi-phase development. Teaches how to maintain harness guardrails throughout the full superpowers development lifecycle.
---

# Harness Orchestration

This skill maintains harness awareness throughout the superpowers workflow. The hooks (loop detection, constraint enforcement, progress save/load) are always-on and require no manual intervention. This skill covers the agent's responsibilities at each phase transition.

## Phase Transition Responsibilities

Progress MUST be updated at every phase transition — not just at the start and end. This ensures context survives compaction and session restarts.

### After brainstorming completes

- **Update the progress file immediately**: set Current Status to "Design approved, moving to planning"
- Record key design decisions in the Key Decisions section
- Invoke the superpowers:writing-plans skill

### After plan is written

- **Update the progress file immediately**: set Current Status to "Plan written, ready to execute"
- Add plan file path to Key Files
- Invoke superpowers:executing-plans (or superpowers:subagent-driven-development if subagents are available)

### During execution (between tasks)

- **Update the progress file after each completed task** — do not batch updates
- Move completed items from Next Steps to Completed
- If loop detection fires (a "LOOP DETECTED" systemMessage appears), immediately invoke the harness:loop-recovery skill before continuing

### After execution completes

- **Update progress immediately**: "Implementation complete, verifying"
- Invoke superpowers:verification-before-completion
- If the code-simplifier plugin's simplify skill is available, invoke it on the files that were changed during execution
- Invoke superpowers:requesting-code-review

### After code review

- **Update progress immediately**: "Code review complete, finishing branch"
- Invoke superpowers:finishing-a-development-branch
- **Update progress file status to "COMPLETE"**
- If the task originated from a Jira ticket and the atlassian plugin is available, update the ticket status

## Interacting with Harness Hooks

The hooks fire automatically. The agent's responsibility is:

- **Loop detection (PostToolUse):** If a "LOOP DETECTED" message appears in context, stop current work and follow the harness:loop-recovery skill. Do not ignore it.
- **Constraint enforcement (PreToolUse):** If a write is denied, read the constraint description and find an alternative approach that respects the boundary. Do not attempt to bypass constraints.
- **Progress save (Stop/PreCompact):** The hook saves a fallback automatically, but agent-written progress is more useful. Proactively write progress before long operations.
- **Progress load (SessionStart):** Progress from prior sessions appears in context automatically. Read it and continue from where the prior session left off.

## Planning Requirements

When the plan modifies a class constructor, method signature, or public API, the plan MUST include a step to grep for all call sites and constructors of the modified class/method. This catches compilation errors in test files and other consumers that the plan might not account for. Example plan step: "Find all call sites: grep for `new ModifiedClass(` and `ModifiedClass.builder()` across the codebase."

When the plan references specific methods, classes, or APIs from the codebase, verify they actually exist before finalizing the plan. Check method names, parameter types, and class hierarchies against actual code — not assumptions from the ticket description. This verification should happen during brainstorming (for bug tickets with clear direction) or during plan review.

## Multi-Repo Awareness

Some tasks require coordinated changes across multiple repositories. When the task involves more than one repo:

- Structure the plan with clearly labeled chunks per repo (e.g., "Chunk 1: extend-api", "Chunk 2: astrada-integrator")
- Note the deploy order if changes have runtime dependencies
- Track progress per repo in the progress file's Key Files section
- Each repo may need its own branch, PR, and verification step

## Graceful Degradation

- If superpowers is not installed: the hooks still work, but the orchestration flow cannot invoke superpowers skills. Inform the user and suggest installing superpowers.
- If atlassian plugin is not installed: skip Jira integration silently. Treat ticket IDs as text labels.
- If code-simplifier is not installed: skip the simplify step after execution.

## Analytics Awareness

- After each completed implementation step, check `/harness-status` for anomalies (rising loop count, constraint violations)
- If `outcome_agreement` has been `false` in recent sessions on this branch, increase self-verification rigor

## Team Mode

- When using agent teams, decompose work into tasks with explicit file ownership — no two tasks should modify the same file
- After each task completion, review advisory signals via `/harness-status --team`
- If a task had high `recent_loops_on_branch` or `recent_blocked_violations`, consider reopening it via the task list
- Run the full test suite before accepting the team's collective output
- Write `team_context: true` in progress file YAML frontmatter

## Semantic Constraint Handling

- When a semantic constraint blocks a write (`ok: false`), log it in the progress file's "Semantic Constraint Notes" section with timestamp, rule name, and the alternative approach taken
- Do not attempt to bypass semantic constraints — restructure the code to comply
