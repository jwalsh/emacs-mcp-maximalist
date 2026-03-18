---
name: cprr
description: Track falsifiable conjectures through the CPRR lifecycle (Conjecture-Prediction-Result-Refutation). Use when registering hypotheses, recording measurements, or surfacing refutation candidates from test failures.
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep
---

# cprr — Conjecture-Prediction-Result-Refutation

Wraps the `cprr` CLI tool for structured hypothesis tracking.
Every conjecture in CLAUDE.md and CONJECTURES.md should have a
corresponding cprr entry.

## When to use

- **Registering a new hypothesis**: when a testable claim is
  identified during development or discussion
- **Recording a measurement**: when data is collected that bears
  on a conjecture
- **Surfacing a refutation**: when a test failure or measurement
  contradicts a conjecture
- **Reviewing status**: when the user asks about conjecture progress

## CPRR lifecycle

```
Conjecture → Prediction → Result → Refutation (or Confirmation)
```

Each conjecture must have:
1. A falsifiable claim
2. A specific prediction (what would confirm/refute it)
3. A measurement result (data)
4. A disposition (confirmed, refuted, or indeterminate + why)

## Commands

### Initialize (first time per repo)

```bash
cprr init
```

### Register a new conjecture

```bash
cprr register --id "C-NNN" --claim "description" --prediction "what would falsify this"
```

### Record a measurement

```bash
cprr measure --id "C-NNN" --result "data summary" --status "confirmed|refuted|indeterminate"
```

### List conjectures

```bash
cprr list --json
```

### Show details

```bash
cprr show "C-NNN" --json
```

## Integration with CONJECTURES.md

After any cprr mutation, check whether `CONJECTURES.md` needs
updating to stay in sync:

1. Read current `CONJECTURES.md`
2. Compare with `cprr list --json`
3. If out of sync, update `CONJECTURES.md` with the new status

## When a test fails

Per CLAUDE.md: "If an acceptance test fails, stop. Document what
failed, what you tried, and what the blocker is. Surface the failure
as a CPRR refutation candidate."

This means:
1. Run `cprr register` or `cprr measure` with the failure data
2. Update `CONJECTURES.md` if relevant
3. Report the refutation candidate to the user before proceeding
