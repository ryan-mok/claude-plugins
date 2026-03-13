---
description: Start a fully autonomous harness-guided development cycle (no human intervention)
argument-hint: [task description or JIRA-ID]
---

Start a fully autonomous harness-guided development cycle for the given task. This version requires NO human intervention — at every decision point where the regular `/harness` command would ask the user, you instead double-check your results, form a professional expert recommendation, and proceed with that recommendation.

Input: $ARGUMENTS

## CRITICAL: Autonomous Behavior Overrides

These overrides apply throughout the ENTIRE workflow, including all invoked superpowers skills. When a skill instructs you to "ask the user", "wait for feedback", "get approval", or "present options", apply the corresponding override below instead.

### Override 1: Brainstorming — No Clarifying Questions

Instead of asking the user clarifying questions one at a time:
1. Research the codebase thoroughly (grep for relevant code, read related files, check recent commits)
2. Identify all ambiguities or open questions
3. For each ambiguity, document your professional expert recommendation and the reasoning behind it
4. Log these decisions in the progress file's Key Decisions section
5. Proceed with your recommendations

### Override 2: Brainstorming — No User Selection of Approach

Instead of proposing 2-3 approaches and waiting for the user to pick:
1. Propose the approaches as normal with trade-offs
2. Evaluate each against: complexity, risk, consistency with existing codebase patterns, and scope
3. Select the approach that best balances these factors
4. Document the trade-offs and your selection rationale in the progress file's Key Decisions section
5. Proceed with the selected approach

### Override 3: Brainstorming — No User Approval on Design

Instead of presenting design sections and waiting for user approval:
1. Write the complete design
2. Self-review it against the original task requirements — does it solve the problem? Is it minimal? Does it follow existing patterns?
3. If you find gaps, fix them
4. Proceed to writing the design doc

### Override 4: Brainstorming — No Visual Companion Offer

Skip the visual companion offer entirely (no human to view it).

### Override 5: Brainstorming — No User Review of Spec

Instead of asking the user to review the written spec:
1. Run the spec reviewer subagent as normal
2. Fix any issues found
3. Re-run until approved (max 5 iterations)
4. Proceed to writing-plans — do not wait for human review

### Override 6: Writing Plans — No Execution Choice

Instead of offering execution choice (subagent-driven vs parallel session):
- Default to **subagent-driven development** in the current session
- Invoke superpowers:subagent-driven-development immediately after the plan is written

### Override 7: Executing Plans — No Stopping to Ask for Help

Instead of stopping and asking for help when blocked:
1. Document the blocker
2. Try up to 3 fundamentally different alternative approaches
3. If all 3 fail, document the blocker in the progress file, skip the blocked task, and continue with remaining tasks
4. Only truly halt if the blocker prevents ALL remaining work

### Override 8: Executing Plans — No Batch Feedback Wait

Instead of reporting batch results and waiting for feedback:
1. After each batch, self-review what was implemented
2. Run all relevant tests and verification commands
3. Check that implementation matches the plan
4. If issues found, fix them
5. Proceed to the next batch immediately

### Override 9: Executing Plans — Self-Assess Plan Concerns

Instead of raising plan concerns with the human:
1. Document each concern and its severity (critical vs minor)
2. For minor concerns: note them and proceed
3. For critical concerns: propose a plan amendment, apply it, document the change in Key Decisions, and proceed

### Override 10: Finishing Branch — Default to PR

Instead of presenting 4 options for what to do with the branch:
- Default to **Option 2: Push and create a Pull Request**
- Create the PR automatically with a well-structured title and description
- Include a note in the PR description: "This PR was generated autonomously by `/harness-auto`."
- Do not offer other options

### Override 11: Code Review — Self-Address Feedback

Instead of waiting for human response to code review findings:
1. Fix all Critical and Important issues immediately
2. Note Minor issues but do not block on them
3. Re-run code review after fixes to confirm resolution
4. Proceed once no Critical or Important issues remain

---

## Step 1: Identify task type

Check if the input matches a Jira ticket ID pattern (uppercase letters followed by a hyphen and digits, e.g., PROJ-1234). If the atlassian plugin skills are available, use the atlassian:triage-issue or atlassian:search-company-knowledge skill to pull the ticket's description, acceptance criteria, and comments. If the atlassian plugin is not available, treat the ticket ID as a text label and proceed.

If no input was provided, DO NOT ask the user — instead, report an error: "No task provided. Usage: /harness-auto [task description or JIRA-ID]" and stop.

## Step 2: Pull latest and create feature branch

Pull the latest base branch. Use `development` if it exists, otherwise `main`. Then create a new feature branch off of it. If the task has a ticket ID, use a branch name like `{ticket-id}/{short-description}`. If no ticket ID, use a descriptive name like `feat/{short-description}` or `fix/{short-description}`.

If already on a feature branch for this task (e.g., resuming a prior session), skip this step.

## Step 3: Initialize progress

Create the harness progress file at `.claude/harness/progress/{branch}--{session-prefix}.md` following the format from the harness:progress-tracking skill. Record the task objective. Add a note: `**Mode:** Autonomous (no human intervention)`.

Ensure `.claude/harness/progress/` is in `.gitignore`.

## Step 4: Check constraints

If `.claude/harness/constraints.json` exists, note how many rules are loaded. If it does not exist, note that no constraints are configured and continue (do not suggest setup — this is autonomous mode).

## Step 5: Verify assumptions against code

Before brainstorming, verify any code claims from the ticket against the actual codebase. If the ticket references specific methods, classes, or APIs, grep for them and confirm they exist with the expected signatures. Record any discrepancies in the progress file's Key Decisions section.

## Step 6: Hand off to superpowers (autonomous mode)

Determine the brainstorming depth based on the task type:

- **Bug fix with clear product direction**: Use a lightweight brainstorming flow — confirm understanding of the bug and the desired fix, propose an approach, and move directly to planning. No clarifying questions needed.
- **Greenfield feature or ambiguous task**: Use the full superpowers:brainstorming skill BUT apply ALL autonomous overrides above. Research the codebase instead of asking questions. Make expert decisions instead of waiting for approval.

Invoke the superpowers:brainstorming skill with the gathered task context. Remind yourself: **apply all autonomous behavior overrides from this command**. The superpowers workflow will proceed: brainstorming → writing-plans → executing-plans → verification → code review → finishing the branch — all without human intervention.

Throughout the workflow, maintain harness awareness per the harness:harness-orchestration-auto skill: save progress at phase transitions, follow loop-recovery if loop detection fires, invoke the simplify skill on changed files after execution completes, and never wait for human input.
