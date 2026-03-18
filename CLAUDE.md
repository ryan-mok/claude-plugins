# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A multi-plugin Claude Code plugin registry owned by Ryan Mok. Plugins are registered in `.claude-plugin/marketplace.json` and each lives in its own top-level directory.

**Current plugins:**
- `harness/` — Runtime guardrails for autonomous development (loop detection, progress tracking, constraint enforcement)

## Repository Structure

```
├── .claude-plugin/
│   └── marketplace.json   # Plugin registry — lists all plugins with source paths
├── harness/               # Harness plugin (has its own CLAUDE.md)
└── docs/                  # Documentation
```

## Adding a New Plugin

1. Create a directory with a `.claude-plugin/plugin.json` manifest
2. Add an entry to the root `.claude-plugin/marketplace.json` `plugins` array
3. Each plugin should contain its own `hooks/`, `commands/`, `skills/`, and `tests/` as needed

## Installing Plugins Locally

```bash
claude plugins add ./<plugin-name>
```

## Required Tools

`bash`, `jq`, `git` — all plugins use bash scripts with jq for JSON processing.
