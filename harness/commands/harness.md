---
description: Start a harness-guided development cycle
argument-hint: [task description or JIRA-ID]
---

Start a harness-guided development cycle for the given task.

Input: $ARGUMENTS

## Step 1: Identify task type

Check if the input matches a Jira ticket ID pattern (uppercase letters followed by a hyphen and digits, e.g., PROJ-1234). If the atlassian plugin skills are available, use the atlassian:triage-issue or atlassian:search-company-knowledge skill to pull the ticket's description, acceptance criteria, and comments. If the atlassian plugin is not available, treat the ticket ID as a text label and proceed.

If no input was provided, ask what the user wants to work on before proceeding.

## Step 2: Pull latest and create feature branch

Pull the latest base branch. Use `development` if it exists, otherwise `main`. Then create a new feature branch off of it. If the task has a ticket ID, use a branch name like `{ticket-id}/{short-description}`. If no ticket ID, use a descriptive name like `feat/{short-description}` or `fix/{short-description}`.

If already on a feature branch for this task (e.g., resuming a prior session), skip this step.

## Step 3: Initialize progress

Create the harness progress file at `.claude/harness/progress/{branch}--{session-prefix}.md` following the format from the harness:progress-tracking skill. Record the task objective.

Ensure `.claude/harness/progress/` is in `.gitignore`.

## Step 4: Check constraints

If `.claude/harness/constraints.json` exists, note how many rules are loaded. If it does not exist, mention that no architectural constraints are configured and the user can set them up with the harness:constraint-setup skill.

## Step 5: Verify assumptions against code

Before brainstorming, verify any code claims from the ticket against the actual codebase. If the ticket references specific methods, classes, or APIs, grep for them and confirm they exist with the expected signatures. This prevents designing a solution around code that doesn't exist or works differently than described. Record any discrepancies in the progress file's Key Decisions section.

## Step 6: Hand off to superpowers

Determine the brainstorming depth based on the task type:

- **Bug fix with clear product direction** (e.g., a Jira comment already specifies the desired behavior): Use a lightweight brainstorming flow — confirm understanding of the bug and the desired fix, propose an approach, and move to planning. Skip extended clarifying questions.
- **Greenfield feature or ambiguous task**: Use the full superpowers:brainstorming skill to explore requirements and design.

Invoke the superpowers:brainstorming skill with the gathered task context and the recommended depth. The superpowers workflow will take over from here: brainstorming → writing-plans → executing-plans → verification → code review → finishing the branch.

Throughout the workflow, maintain harness awareness per the harness:harness-orchestration skill: save progress at phase transitions, follow loop-recovery if loop detection fires, and invoke the simplify skill on changed files after execution completes.
