# Harness

Harness engineering for Claude Code. Wraps existing tools and the superpowers workflow with autonomous runtime guardrails.

## What it does

- **Loop Detection** — Detects when the agent is stuck retrying the same failing approach and forces a different strategy
- **Cross-Session Progress** — Saves and restores task progress across context compaction and session boundaries
- **Constraint Enforcement** — Blocks writes that violate architectural boundaries defined in your project
- **Orchestration** — `/harness` command runs the full development cycle with harness awareness

## Installation

```bash
/plugin install harness
```

## Quick Start

```
/harness Fix the login timeout bug
```

This kicks off the full harness-guided workflow: brainstorming → planning → execution → verification → review.

## Commands

- `/harness [task]` — Start a harness-guided development cycle
- `/harness-status` — Show harness status (loop detection, progress, constraints)

## Setting Up Constraints

Create `.claude/harness/constraints.json` in your project:

```json
{
  "rules": [
    {
      "name": "no-cross-layer-imports",
      "type": "import-boundary",
      "description": "API layer must not import from data layer",
      "deny": { "from": "src/api/**", "import": "src/data/**" },
      "severity": "block"
    }
  ]
}
```

## Requirements

- `jq` (for hook scripts)
- superpowers plugin (for `/harness` orchestration)

## Optional Integrations

- atlassian plugin — pull Jira ticket context
- code-simplifier plugin — auto-simplify after execution
- pr-review-toolkit plugin — enhanced code review
