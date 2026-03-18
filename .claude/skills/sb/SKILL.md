---
name: sb
description: Manage git worktrees via sb (sandbox auditor). Use when isolating work in worktrees, spawning agents in isolated copies, or auditing worktree placement. Ensures worktrees live under worktrees/ not as siblings.
user-invocable: true
allowed-tools: Bash, Read, Grep
---

# sb — Sandbox & Worktree Auditor

Wraps the `sb` CLI tool for structured worktree management. All
worktrees must live under `worktrees/` (not as repo siblings).

## When to use

- Before spawning an agent with `isolation: "worktree"` — ensure
  `worktrees/` exists via `sb init`
- After any worktree operation — run `sb audit` to verify placement
- When the user says "isolate", "worktree", "sandbox", or "parallel work"

## Commands

### Initialize (first time per repo)

```bash
sb init
```

Creates `worktrees/` directory and adds it to `.gitignore`.

### Create a worktree for isolated work

```bash
sb add <name> [branch]
```

Always use `sb add`, never raw `git worktree add`. This ensures
placement under `worktrees/`.

### Audit placement

```bash
sb audit --json
```

Run after any worktree operation. If any worktree is misplaced
(not under `worktrees/`), report the violation and suggest
`sb add` to fix it.

### List active worktrees

```bash
sb list --json
```

### Clean up

```bash
sb prune    # remove stale references
sb remove <name>  # remove a specific worktree
```

### Health check

```bash
sb doctor --json
```

Run when worktree operations fail or state seems inconsistent.

## Agent bootstrap context

When an agent needs to understand the worktree setup quickly:

```bash
sb prime
```

This outputs agent-optimized context about the current worktree state.

## Post-action checklist

After any worktree mutation (add, remove, prune):
1. Run `sb audit --json` to verify all worktrees are correctly placed
2. Report any violations to the user
