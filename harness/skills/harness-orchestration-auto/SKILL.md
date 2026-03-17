---
name: harness-orchestration-auto
description: This skill should be used when the /harness-auto command is invoked, when maintaining autonomous harness awareness throughout a superpowers workflow with no human intervention, or when transitioning between workflow phases autonomously. Teaches how to maintain harness guardrails and make expert decisions at every phase transition without waiting for human input.
---

# Harness Orchestration (Autonomous Mode)

This skill maintains harness awareness throughout the superpowers workflow in fully autonomous mode. All human interaction points are replaced with self-review, expert judgment, and documented reasoning. The hooks (loop detection, constraint enforcement, progress save/load) remain always-on.

## Core Autonomous Principle

At every point where a human would normally provide input, you MUST:

1. **Double-check your results** — re-read relevant code, re-run tests, verify assumptions
2. **Form a professional expert recommendation** — consider trade-offs, risks, and alternatives
3. **Document the decision** — record what you decided and WHY in the progress file's Key Decisions section
4. **Proceed with the recommendation** — do not wait or ask

## Phase Transition Responsibilities

Progress MUST be updated at every phase transition.

### After brainstorming completes

- **Update the progress file immediately**: set Current Status to "Design approved (self-reviewed), moving to planning"
- Record key design decisions and the reasoning behind each in Key Decisions
- Invoke the superpowers:writing-plans skill
- **Autonomous override**: Do not wait for user to approve the design. Self-review it:
  - Does the design solve the stated problem?
  - Is it minimal (YAGNI)?
  - Does it follow existing codebase patterns?
  - Are there obvious gaps or risks?
  - If issues found, fix them and re-review. Then proceed.

### After plan is written

- **Update the progress file immediately**: set Current Status to "Plan written, executing autonomously"
- Add plan file path to Key Files
- **Autonomous override**: Do not offer execution choice. Default to superpowers:subagent-driven-development if subagents are available, otherwise superpowers:executing-plans
- Proceed immediately to execution

### During execution (between tasks)

- **Update the progress file after each completed task** — do not batch updates
- Move completed items from Next Steps to Completed
- If loop detection fires (a "LOOP DETECTED" systemMessage appears), immediately invoke the harness:loop-recovery skill before continuing
- **Autonomous override for batch boundaries**: Do not pause for feedback between batches. Instead:
  1. Self-review the completed batch: do implementations match the plan?
  2. Run all relevant tests
  3. If tests pass and implementation matches plan, continue to next batch
  4. If issues found, fix them before proceeding

### When blocked during execution

- **Autonomous override**: Do not stop and ask for help. Instead:
  1. Document the blocker in the progress file
  2. Attempt up to 3 fundamentally different approaches (not minor variations)
  3. If an approach works, document which one and why in Key Decisions
  4. If all 3 fail, log the blocker, skip the task with a TODO comment in code, and continue with remaining tasks
  5. Only truly halt if the blocker prevents ALL remaining work

### After execution completes

- **Update progress immediately**: "Implementation complete, verifying"
- Invoke superpowers:verification-before-completion — this skill has NO human gates, run it as-is
- If the code-simplifier plugin's simplify skill is available, invoke it on the files that were changed during execution
- Invoke superpowers:requesting-code-review
- **Autonomous override for code review feedback**:
  1. Fix all Critical issues immediately
  2. Fix all Important issues
  3. Note Minor issues but do not block on them
  4. Re-run code review after fixes to verify resolution
  5. Proceed once no Critical or Important issues remain

### After code review

- **Update progress immediately**: "Code review complete, finishing branch"
- Invoke superpowers:finishing-a-development-branch
- **Autonomous override**: Do not present 4 options. Default to **Push and create a Pull Request**:
  1. Verify all tests pass
  2. Push the branch
  3. Create a PR with a well-structured title and description
  4. Report the PR URL
- **Update progress file status to "COMPLETE"**
- If the task originated from a Jira ticket and the atlassian plugin is available, update the ticket status

## Interacting with Harness Hooks

The hooks fire automatically. The agent's responsibility is:

- **Loop detection (PostToolUse):** If a "LOOP DETECTED" message appears in context, stop current work and follow the harness:loop-recovery skill. Do not ignore it.
- **Constraint enforcement (PreToolUse):** If a write is denied, read the constraint description and find an alternative approach that respects the boundary. Do not attempt to bypass constraints.
- **Progress save (Stop/PreCompact):** The hook saves a fallback automatically, but agent-written progress is more useful. Proactively write progress before long operations.
- **Progress load (SessionStart):** Progress from prior sessions appears in context automatically. Read it and continue from where the prior session left off.

## Planning Requirements

When the plan modifies a class constructor, method signature, or public API, the plan MUST include a step to grep for all call sites and constructors of the modified class/method. This catches compilation errors in test files and other consumers that the plan might not account for.

When the plan references specific methods, classes, or APIs from the codebase, verify they actually exist before finalizing the plan. Check method names, parameter types, and class hierarchies against actual code — not assumptions from the ticket description. This verification should happen during brainstorming (for bug tickets with clear direction) or during plan review. Example plan step: "Find all call sites: grep for `new ModifiedClass(` and `ModifiedClass.builder()` across the codebase."

## Multi-Repo Awareness

Some tasks require coordinated changes across multiple repositories. When the task involves more than one repo:

- Structure the plan with clearly labeled chunks per repo (e.g., "Chunk 1: extend-api", "Chunk 2: astrada-integrator")
- Note the deploy order if changes have runtime dependencies
- Track progress per repo in the progress file's Key Files section
- Each repo may need its own branch, PR, and verification step
- **Autonomous override**: Create PRs in dependency order and document the deploy sequence in each PR description

## Quality Gates (Self-Enforced)

Since no human is reviewing intermediate results, apply these quality gates yourself:

1. **Design gate**: Before proceeding from brainstorming, verify the design covers all acceptance criteria from the task
2. **Plan gate**: Before proceeding from planning, verify every task has exact file paths, complete code, and test commands
3. **Implementation gate**: After each task, verify tests pass and implementation matches the plan step
4. **Completion gate**: Before creating the PR, run the full test suite, verify all acceptance criteria are met, and check for regressions

Each gate allows a maximum of 3 self-review iterations. If issues persist after 3 iterations, document the remaining concerns in the PR description and proceed.

## Graceful Degradation

- If superpowers is not installed: the hooks still work, but the orchestration flow cannot invoke superpowers skills. Log an error in progress and halt.
- If atlassian plugin is not installed: skip Jira integration silently. Treat ticket IDs as text labels.
- If code-simplifier is not installed: skip the simplify step after execution.

## Analytics Awareness

- Check `/harness-status` after every 3rd implementation step (balance thoroughness with speed)
- If `outcome_agreement` has been `false` in recent sessions on this branch, increase self-verification rigor
- If loop count > 3 or violation count > 2, pause and invoke the harness:loop-recovery skill before continuing

## Team Mode

- When using agent teams, decompose work into tasks with explicit file ownership — no two tasks should modify the same file
- After each task completion, self-review advisory signals via `/harness-status --team` and decide whether to reopen tasks — no waiting for human input
- If a task had high `recent_loops_on_branch` or `recent_blocked_violations`, reopen it via the task list and re-execute
- Run the full test suite before accepting the team's collective output
- Write `team_context: true` in progress file YAML frontmatter
- Document all team-related decisions in the progress file's Key Decisions section

## Semantic Constraint Handling

- When a semantic constraint blocks a write (`ok: false`), log it in the progress file's "Semantic Constraint Notes" section with timestamp, rule name, and the alternative approach taken
- Do not attempt to bypass semantic constraints — restructure the code to comply
- Document all constraint-driven restructuring decisions in the progress file
