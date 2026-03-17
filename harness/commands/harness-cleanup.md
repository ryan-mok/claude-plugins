---
description: Clean up stale harness files (progress, loop state, analytics, constraint logs)
argument-hint: [--all | --progress | --loops | --analytics | --constraints | --dry-run]
allowed-tools: Read, Bash(cat:*,ls:*,find:*,rm:*,wc:*,head:*,stat:*,mv:*,jq:*,date:*,tail:*)
---

Clean up all harness state files — progress files, loop state, analytics, and constraint logs.

Flag: $ARGUMENTS

## What to clean

### Progress files (default, or `--progress`)

Remove all `.md` files in `.claude/harness/progress/` (including `_index.md`). List each file removed.

### Loop state files (`--loops`)

Find and remove all `/tmp/harness-loop-state-*.jsonl` files.

### Analytics (`--analytics`)

Archive analytics events older than 90 days:

1. Read `.claude/harness/analytics/events.jsonl`
2. Compute the cutoff date (90 days ago)
3. Move events with `ts` older than the cutoff into `.claude/harness/analytics/events.archived.jsonl` (append if the archive file already exists)
4. Rewrite `events.jsonl` with only the recent events

```bash
CUTOFF=$(date -u -v-90d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '90 days ago' +%Y-%m-%dT%H:%M:%SZ)

# Archive old events (append to archive file)
jq -c --arg cutoff "$CUTOFF" 'select(.ts < $cutoff)' .claude/harness/analytics/events.jsonl >> .claude/harness/analytics/events.archived.jsonl

# Keep recent events
jq -c --arg cutoff "$CUTOFF" 'select(.ts >= $cutoff)' .claude/harness/analytics/events.jsonl > .claude/harness/analytics/events.jsonl.tmp && mv .claude/harness/analytics/events.jsonl.tmp .claude/harness/analytics/events.jsonl
```

Remove post-mortem files older than 90 days from `.claude/harness/analytics/postmortems/`:

```bash
find .claude/harness/analytics/postmortems/ -name "*.md" -mtime +90 -delete
```

Report how many events were archived and how many post-mortems were removed.

### Constraint logs (`--constraints`) — DEPRECATED

If `$ARGUMENTS` contains `--constraints`, print:

> Constraint logs are now in analytics. Use `--analytics` to manage.

Do not perform any cleanup for this flag.

## Scope

If no flags are passed, clean **everything** (progress + loops + analytics). Use `--progress`, `--loops`, or `--analytics` to target specific categories only.

The `--all` flag also cleans everything (progress + loops + analytics) — equivalent to passing no flags.

## Dry run

If `$ARGUMENTS` contains `--dry-run`, list what would be removed or archived without making any changes.

## Output format

```
## Harness Cleanup

### Progress
- Removed: N stale file(s)
- Remaining: N active file(s)

### Loop State
- Removed: N file(s)

### Analytics
- Archived: N event(s) older than 90 days
- Removed: N post-mortem(s) older than 90 days

Total cleaned: N file(s) / N event(s) archived
```

If nothing was cleaned, report "Nothing to clean up."
