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

### semantic

Enforces higher-level code quality rules that require understanding context beyond simple pattern matching. Semantic rules are evaluated by an agent hook that reasons about whether the write violates the rule's intent.

```json
{
  "name": "no-business-logic-in-controllers",
  "type": "semantic",
  "description": "Controller files should only handle HTTP request/response. Business logic belongs in the service layer.",
  "check": {
    "in": "src/controllers/**",
    "prompt": "Does this code contain business logic (data transformation, validation rules, complex conditionals, database queries) rather than just HTTP request handling and delegation to services?"
  },
  "severity": "block"
}
```

- `check.in`: glob pattern matching file paths to check
- `check.prompt`: question the agent hook evaluates against the file content
- The agent hook evaluates the file content against the rule description and prompt using LLM reasoning
- Semantic rules only support `block` severity (see Severity Levels below)

### cross-file

Enforces invariants that span multiple files — for example, ensuring that every API route has a corresponding test file or that every database model has a migration.

```json
{
  "name": "api-endpoints-must-have-tests",
  "type": "cross-file",
  "description": "Every exported function in src/api/ must have a corresponding test in tests/api/",
  "check": {
    "in": "src/api/**",
    "verify": "Check if the function being added or modified has a corresponding test file in tests/api/ with at least one test case for this function.",
    "context_files": ["tests/api/**"]
  },
  "severity": "block"
}
```

- `check.in`: glob pattern matching the source files being checked
- `check.verify`: instruction the agent hook follows to verify the cross-file invariant
- `check.context_files`: glob patterns the agent hook reads to verify the constraint
- Cross-file rules only support `block` severity (see Severity Levels below)

## Severity Levels

- **block** — prevents the write entirely. Use for rules that must never be violated (security boundaries, critical architectural invariants).
- **warn** — allows the write but injects a warning into context. Use for guidelines that have legitimate exceptions. Only valid for `import-boundary`, `file-pattern`, and `custom` rule types.

**Severity validation:** Semantic and cross-file rules only support `block` severity. If a `semantic` or `cross-file` rule specifies `"severity": "warn"`, reject it with the error: "Semantic and cross-file rules only support 'block' severity."

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

## Agent Hook Lifecycle Management

Semantic and cross-file rules require an agent hook to evaluate writes. The agent must manage this hook entry in `.claude/settings.json` as rules are added and removed.

### When adding the first semantic or cross-file rule

1. Read `.claude/settings.json`
2. Merge the following agent hook entry into the `hooks.PreToolUse` array:

```json
{
  "type": "agent",
  "prompt": "PRIORITY: Exit early if possible.\n\nStep 1: Extract the file_path from the tool input below.\nStep 2: Read .claude/harness/constraints.json. If it does not exist, immediately return {\"ok\": true}.\nStep 3: Find rules with type 'semantic' or 'cross-file' AND severity 'block'. If none exist, immediately return {\"ok\": true}.\nStep 4: Check if file_path matches any matching rule's 'check.in' glob. If no glob matches, immediately return {\"ok\": true}.\nStep 5: For matching 'semantic' rules — if this is an Edit operation, Read the full target file for context. Evaluate whether the PROPOSED CHANGE introduces a violation per the rule's 'description' and 'check.prompt' fields. Do not flag pre-existing violations in unchanged code.\nStep 6: For matching 'cross-file' rules — use Glob to find files matching 'context_files' patterns, Read relevant matches, and verify the constraint described in the 'verify' field.\nStep 7: If any block-severity rule is violated, return {\"ok\": false, \"reason\": \"Rule [name]: [description]\"}. Otherwise return {\"ok\": true}.\n\nTool input: $ARGUMENTS",
  "timeout": 60
}
```

3. Write the updated settings back to `.claude/settings.json`

### When removing the last semantic or cross-file rule

1. Read `.claude/settings.json`
2. Remove the harness agent hook entry from the `hooks.PreToolUse` array
3. Write the updated settings back to `.claude/settings.json`

This ensures the agent hook is only active when there are rules that need it, avoiding unnecessary overhead for projects that only use pattern-based rules.

## Performance Considerations

Semantic and cross-file rules add ~3-5s to every file write. Use narrow globs to limit which files trigger evaluation. For example, prefer `src/controllers/**` over `src/**` if the rule only applies to controllers.
