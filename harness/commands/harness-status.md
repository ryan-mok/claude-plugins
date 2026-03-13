---
description: Show harness status (loop detection, progress, constraints)
argument-hint: [--progress | --constraints | --reset-loops]
allowed-tools: Read, Bash(cat:*,ls:*,wc:*,jq:*,head:*,find:*,rm:*)
---

Assemble and display the current harness status by reading state files. Check if `jq` is available on the system PATH first — if not, warn the user that harness hooks require jq.

Flag: $ARGUMENTS

## Loop Detection

Find the loop detection state file at `/tmp/harness-loop-state-*.jsonl` for the current project. Report:
- How many tool calls are tracked (line count of the JSONL file)
- How many loops were detected this session (count entries where the hook output a systemMessage — these are logged in the transcript, so just count JSONL entries and report the state file path)

If `$ARGUMENTS` contains `--reset-loops`, delete the loop state file and confirm reset.

## Progress

Read `.claude/harness/progress/_index.md` if it exists. Report:
- Last saved timestamp
- Current branch
- Number of active sessions
- List each session with staleness indication

If `$ARGUMENTS` contains `--progress`, also read and display the full contents of the current session's progress file.

## Constraints

If `.claude/harness/constraints.json` exists, report how many rules are loaded. Check `/tmp/harness-constraint-log-*.jsonl` for violation history this session.

If `$ARGUMENTS` contains `--constraints`, display all rules from the constraints file.

## Format

Present the output as a clean markdown summary matching this structure:

```
## Harness Status

### Loop Detection
State: Active/Inactive
Recent tool calls tracked: N
State file: /tmp/harness-loop-state-XXXX.jsonl

### Progress
Last saved: TIMESTAMP
Branch: BRANCH
Active sessions: N

### Constraints
Rules loaded: N
Violations blocked: N
Warnings issued: N
```
