---
name: bd
description: Manage issues via bd (beads). Use for creating, querying, and tracking issues with first-class dependency support. Prefer bd over gh for issue tracking when .beads/ exists in the repo.
user-invocable: true
allowed-tools: Bash, Read, Grep
---

# bd — Beads Issue Tracker

Wraps the `bd` CLI tool for local-first issue tracking with
dependency chains. Issues are "beads" that can be chained together.

## When to use

- **Creating issues**: `bd create` instead of `gh issue create`
  when `.beads/` exists in the repo
- **Checking what's ready**: `bd ready` shows unblocked work
- **Dependency management**: `bd dep add`, `bd graph`
- **Quick capture**: `bd q "title"` for fast issue creation
- **Triage**: `bd stale`, `bd blocked`, `bd orphans`

## Initialization

```bash
bd init
```

Creates `.beads/` database. Run once per repo.

## Core workflow

### Quick capture (returns only the ID)

```bash
bd q "fix escape.py null byte handling"
```

### Create with details

```bash
bd create --title "Step 1: escape.py" --type feature --body "acceptance: pytest passes"
```

### Wire dependencies

```bash
bd dep add <child-id> <parent-id>
```

### See what's ready to work on

```bash
bd ready --json
```

### See what's blocked

```bash
bd blocked --json
```

### Dependency graph

```bash
bd graph
```

### Search and query

```bash
bd search "escape"
bd query "state:open type:feature"
bd list --json
```

### Close when done

```bash
bd close <id>
```

## Agent-specific commands

### Bootstrap context for agents

```bash
bd prime
```

Outputs agent-optimized context about current issue state.

### Agent slot management

```bash
bd slot claim <id>     # claim an issue for this agent
bd slot release <id>   # release a claimed issue
bd slot list --json    # see what's claimed
```

### Audit trail

```bash
bd audit log --json    # append-only JSONL of agent interactions
```

## Decision rules

- If `.beads/` exists, prefer `bd` over `gh issue` for local tracking
- Use `bd ready` to pick next work item, not arbitrary selection
- After completing a task, `bd close <id>` and check if downstream
  issues are now unblocked via `bd ready`
- Use `bd q` for fast capture during conversation; flesh out later
  with `bd edit`

## Health check

```bash
bd doctor --json
```

Run when bd operations fail or database seems inconsistent.

## Sync with GitHub

bd can sync with GitHub issues. If the project uses both:
- `bd` for local dependency tracking and agent coordination
- `gh` for public-facing issues and PRs
- Use `bd export --json` to bridge the two when needed
