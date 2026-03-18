---
name: aq
description: Coordinate multi-agent file access via aq (ambient queue). Use before modifying shared files in parallel agent sessions to announce claims and check for conflicts. Gossip, not locks.
user-invocable: true
allowed-tools: Bash, Read, Grep
---

# aq — Ambient Agent Queue

Wraps the `aq` CLI tool for gossip-based multi-agent coordination.
Broadcasts are ephemeral (they expire). Silence is normal. This is
advisory, not mandatory — no operation blocks.

## When to use

- **Before editing shared files** in a multi-agent session: check
  for conflicts, then announce your claim
- **After completing work** on claimed files: let the broadcast expire
  naturally (TTL-based) or announce completion
- **When spawning parallel agents**: each agent should announce its
  file set to reduce merge conflicts

## Core workflow

### 1. Check before editing

```bash
aq check -f "file1.py,file2.py" --json
```

If another agent has announced these files, report the conflict to
the user and ask whether to proceed.

### 2. Announce your claim

For substantive work (high priority, 5-minute TTL):
```bash
aq announce -c "<conjecture-or-task-id>" -f "file1.py,file2.py"
```

For lightweight/read-only work (low priority, 1-minute TTL):
```bash
aq whisper -c "<task-id>" -f "file1.py"
```

### 3. Check current broadcasts

```bash
aq status --json
```

### Agent bootstrap context

```bash
aq prime
```

## Decision rules

- If `aq check` returns conflicts: warn the user, do NOT silently
  proceed. Let the user decide.
- If `aq` is not installed or `~/.aq` doesn't exist: skip silently.
  This tool is advisory. Never fail a task because aq is unavailable.
- Broadcasts expire. Do not treat stale silence as "all clear" — it
  just means no one announced recently.
- Use `announce` for file writes, `whisper` for file reads or docs.

## Initialization

```bash
aq init
```

Creates `~/.aq` directory structure. Run once per machine.
