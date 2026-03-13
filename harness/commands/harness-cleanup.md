---
description: Clean up stale harness files (progress, loop state, constraint logs)
argument-hint: [--all | --progress | --loops | --constraints | --dry-run]
allowed-tools: Read, Bash(cat:*,ls:*,find:*,rm:*,wc:*,head:*,stat:*)
---

Clean up all harness state files — progress files, loop state, and constraint logs.

Flag: $ARGUMENTS

## What to clean

### Progress files (default, or `--progress`)

Remove all `.md` files in `.claude/harness/progress/` (including `_index.md`). List each file removed.

### Loop state files (`--loops`)

Find and remove all `/tmp/harness-loop-state-*.jsonl` files.

### Constraint logs (`--constraints`)

Find and remove all `/tmp/harness-constraint-log-*.jsonl` files.

## Scope

If no flags are passed, clean **everything** (progress + loops + constraints). Use `--progress`, `--loops`, or `--constraints` to target specific categories only.

## Dry run

If `$ARGUMENTS` contains `--dry-run`, list what would be removed without deleting anything.

## Output format

```
## Harness Cleanup

### Progress
- Removed: N stale file(s)
- Remaining: N active file(s)

### Loop State
- Removed: N file(s)

### Constraint Logs
- Removed: N file(s)

Total cleaned: N file(s)
```

If nothing was cleaned, report "Nothing to clean up."
