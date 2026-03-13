---
name: constraint-setup
description: This skill should be used when the user asks to "set up constraints", "add architectural rules", "enforce module boundaries", "create constraints.json", "configure import restrictions", or wants to define project-specific architectural constraints for the harness plugin. Guides creation and maintenance of the .claude/harness/constraints.json configuration file.
---

# Constraint Setup

The harness plugin enforces architectural constraints via a PreToolUse hook that checks every Write and Edit operation against rules defined in `.claude/harness/constraints.json`. This skill teaches how to define effective constraint rules.

## Constraint File Location

Create the file at: `.claude/harness/constraints.json`

This file should be committed to the repository so all team members share the same constraints.

## Rule Types

### import-boundary

Prevents one module from importing another. Use for enforcing layered architecture.

```json
{
  "name": "descriptive-rule-name",
  "type": "import-boundary",
  "description": "Human-readable explanation shown on violation",
  "deny": {
    "from": "src/api/**",
    "import": "src/data/**"
  },
  "severity": "block"
}
```

- `from`: glob pattern matching source file paths that should NOT contain the import
- `import`: glob pattern matching imported module paths that are forbidden
- Extracts `import ... from '...'` and `require('...')` statements from file content

### file-pattern

Prevents specific patterns from appearing in files matching a glob. Use for banning dangerous APIs or enforcing coding standards.

```json
{
  "name": "no-env-in-source",
  "type": "file-pattern",
  "description": "Source files must not read env vars directly — use config module",
  "deny": {
    "in": "src/**",
    "pattern": "process\\.env\\."
  },
  "severity": "warn"
}
```

- `in`: glob pattern matching file paths to check
- `pattern`: regex (extended grep) matched against file content

### custom

Identical to file-pattern. Use for project-specific rules that don't fit the other categories.

## Severity Levels

- **block** — prevents the write entirely. Use for rules that must never be violated (security boundaries, critical architectural invariants).
- **warn** — allows the write but injects a warning into context. Use for guidelines that have legitimate exceptions.

## Defining Good Constraints

### Start with boundaries that already exist

Analyze the codebase to identify architectural layers and module boundaries that are already respected by convention. Turn these into constraints to prevent drift.

### Keep the rule count low

Start with 3-5 critical rules. Too many constraints create friction and false positives. Add rules only when a real violation occurs or when a boundary is critical enough to enforce.

### Write clear descriptions

The description appears in violation messages. Make it explain both WHAT is wrong and WHY, so the agent can self-correct:
- Good: "API layer must not import from data layer directly — use the service layer for data access"
- Bad: "Import not allowed"

### Use warn before block

Start new rules with `warn` severity. Observe whether they trigger correctly before upgrading to `block`. This prevents false positives from blocking legitimate work.

## Checking Constraint Status

Run `/harness-status --constraints` to see all loaded rules and recent violation history.
