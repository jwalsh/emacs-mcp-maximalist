---
name: health-check
description: Generate or run bin/health-check.sh that validates project prerequisites (emacs daemon, emcp-stdio.el) with JSON output and exit codes. Use to verify environment.
user-invocable: true
allowed-tools: Read, Write, Bash, Edit
---

# Health Check

This skill is inherently idempotent -- it checks current state and reports.
Running it multiple times is expected and safe.

## If bin/health-check.sh does not exist

Generate it from the current project architecture. The script must:

- Check hard requirements (exit 2 if any fail):
  - `emacsclient --eval '(emacs-pid)'` succeeds (daemon running)
  - `emacs --batch -Q -l src/emcp-stdio.el` loads without error

- Check soft requirements (exit 1 if any fail):
  - `.mcp.json` exists (MCP client config present)
  - `CLAUDE.md` exists
  - `src/emcp-stdio.el` exists

- Output structured JSON with boolean values for each check
- Exit codes: 0 (ok), 1 (degraded), 2 (broken)

## If bin/health-check.sh exists

Run it and report results:

```bash
chmod +x bin/health-check.sh
bin/health-check.sh
echo "Exit code: $?"
```

Interpret the JSON output and summarize what's working and what needs
attention.
