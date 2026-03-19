---
name: verify-bootstrap
description: Verify the bootstrap by checking that CLAUDE.md, spec.org, and memory files correctly answer the five verification questions. Use after full bootstrap.
user-invocable: true
allowed-tools: Read, Bash, Grep, Glob
---

# Verify Bootstrap

This skill is inherently idempotent -- it reads files and reports findings.
Running it multiple times is expected and safe.

## Prerequisite Check

Before verifying, confirm the minimum scaffold exists:

- `CLAUDE.md` must exist. If not: stop with "run `/generate-claude-md` first."
- `spec.org` must exist. If not: stop with "no spec.org found."

If both exist, proceed with verification.

## Verification Questions

Read CLAUDE.md, spec.org, and memory files, then answer:

1. **What is this project?**
   Expected: MCP server exposing Emacs obarray functions as tools
   via runtime introspection.

2. **Who is the primary user?**
   Expected: Agentic runtimes (Claude Code / MCP clients).

3. **What is the primary output artifact?**
   Expected: A running MCP server over stdio (pure Elisp, `emcp-stdio.el`).

4. **What is the first build step?**
   Expected: emcp-stdio.el -- `emacs --batch -Q -l src/emcp-stdio.el -f emcp-stdio-start`
   starts and responds to `tools/list`.

5. **How many open conjectures?**
   Expected: 6 (C-001 through C-006, plus C-008).

## Process

1. Read CLAUDE.md and extract answers
2. Cross-reference with spec.org
3. Report each answer with pass/fail
4. If any fail, identify the gap in CLAUDE.md or memory and report
   what needs to be fixed

## Success Criteria

All 5 answers must be derivable from CLAUDE.md alone (without reading
spec.org). If any require spec.org to answer, CLAUDE.md is incomplete.
