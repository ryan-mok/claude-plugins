---
name: harness-orchestration
description: This skill should be used when the /harness command is invoked, when maintaining harness awareness throughout a superpowers workflow, when transitioning between workflow phases (brainstorming to planning to execution), or when the agent needs guidance on progress tracking during multi-phase development. Teaches how to maintain harness guardrails throughout the full superpowers development lifecycle.
---

# Harness Orchestration

This skill maintains harness awareness throughout the superpowers workflow. The hooks (loop detection, constraint enforcement, progress save/load) are always-on and require no manual intervention. This skill covers the agent's responsibilities at each phase transition.

## Phase Transition Responsibilities

### After brainstorming completes

- Update the progress file: set Current Status to "Design approved, moving to planning"
- Record key design decisions in the Key Decisions section
- Invoke the superpowers:writing-plans skill

### After plan is written

- Update the progress file: set Current Status to "Plan written, ready to execute"
- Add plan file path to Key Files
- Invoke superpowers:executing-plans (or superpowers:subagent-driven-development if subagents are available)

### During execution (between tasks)

- Update the progress file after each completed task
- Move completed items from Next Steps to Completed
- If loop detection fires (a "LOOP DETECTED" systemMessage appears), immediately invoke the harness:loop-recovery skill before continuing

### After execution completes

- Update progress: "Implementation complete, verifying"
- Invoke superpowers:verification-before-completion
- If the code-simplifier plugin's simplify skill is available, invoke it on the files that were changed during execution
- Invoke superpowers:requesting-code-review

### After code review

- Update progress: "Code review complete, finishing branch"
- Invoke superpowers:finishing-a-development-branch
- Update progress file status to "Done"
- If the task originated from a Jira ticket and the atlassian plugin is available, update the ticket status

## Interacting with Harness Hooks

The hooks fire automatically. The agent's responsibility is:

- **Loop detection (PostToolUse):** If a "LOOP DETECTED" message appears in context, stop current work and follow the harness:loop-recovery skill. Do not ignore it.
- **Constraint enforcement (PreToolUse):** If a write is denied, read the constraint description and find an alternative approach that respects the boundary. Do not attempt to bypass constraints.
- **Progress save (Stop/PreCompact):** The hook saves a fallback automatically, but agent-written progress is more useful. Proactively write progress before long operations.
- **Progress load (SessionStart):** Progress from prior sessions appears in context automatically. Read it and continue from where the prior session left off.

## Graceful Degradation

- If superpowers is not installed: the hooks still work, but the orchestration flow cannot invoke superpowers skills. Inform the user and suggest installing superpowers.
- If atlassian plugin is not installed: skip Jira integration silently. Treat ticket IDs as text labels.
- If code-simplifier is not installed: skip the simplify step after execution.
