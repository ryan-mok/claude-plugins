---
description: Start a harness-guided development cycle
argument-hint: [task description or JIRA-ID]
---

Start a harness-guided development cycle for the given task.

Input: $ARGUMENTS

## Step 1: Identify task type

Check if the input matches a Jira ticket ID pattern (uppercase letters followed by a hyphen and digits, e.g., PROJ-1234). If the atlassian plugin skills are available, use the atlassian:triage-issue or atlassian:search-company-knowledge skill to pull the ticket's description, acceptance criteria, and comments. If the atlassian plugin is not available, treat the ticket ID as a text label and proceed.

If no input was provided, ask what the user wants to work on before proceeding.

## Step 2: Initialize progress

Create the harness progress file at `.claude/harness/progress/{branch}--{session-prefix}.md` following the format from the harness:progress-tracking skill. Record the task objective.

Ensure `.claude/harness/progress/` is in `.gitignore`.

## Step 3: Check constraints

If `.claude/harness/constraints.json` exists, note how many rules are loaded. If it does not exist, mention that no architectural constraints are configured and the user can set them up with the harness:constraint-setup skill.

## Step 4: Hand off to superpowers

Invoke the superpowers:brainstorming skill with the gathered task context. The superpowers workflow will take over from here: brainstorming → writing-plans → executing-plans → verification → code review → finishing the branch.

Throughout the workflow, maintain harness awareness per the harness:harness-orchestration skill: save progress at phase transitions, follow loop-recovery if loop detection fires, and invoke the simplify skill on changed files after execution completes.
