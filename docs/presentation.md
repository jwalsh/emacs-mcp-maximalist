# Reductio ad Absurdum: What Happens When You Expose 3,600 Emacs Functions as MCP Tools

## The Question

MCP (Model Context Protocol) lets you give AI agents access to tools.
The standard advice is: curate a small, useful set.

**What if you don't?**

What if you connect every text-consuming function in a running Emacs
to Claude Code and see what happens? Not as a useful tool — as an
experiment in protocol design limits.

---

## The Setup

```
                                    ┌──────────────────┐
                                    │   Claude Code     │
                                    │  (MCP client)     │
                                    └────────┬─────────┘
                                             │ stdin/stdout
                                      tools/list, tools/call
                                             │
                                    ┌────────┴─────────┐
                                    │  emacs --batch    │
                                    │  emcp-stdio.el    │
                                    │  (pure Elisp MCP  │
                                    │   server, ~250 LoC)│
                                    └────────┬─────────┘
                                             │
                                      mapatoms (obarray)
                                      780-3600 tools
                                             │
                                    ┌────────┴─────────┐
                                    │ Emacs daemon      │
                                    │ (optional, for    │
                                    │  9 data tools)    │
                                    └──────────────────┘
```

**One axiom**: the MCP server does not know what Emacs can do. Emacs
tells it. All function definitions come from `obarray` introspection
at runtime. Nothing is hardcoded.

**Two modes from one codebase**: `core` (~779 tools with `-Q`) and
`maximalist` (~3600+ tools with user init), selected by Emacs startup
flags.

---

## What We Actually Learned

This project is a vehicle for six testable conjectures about MCP
protocol behavior, agent architectures, and Emacs internals. The
server is scaffolding. The measurements are the point.

### Conjecture Scorecard

| # | Claim | Verdict | Surprise? |
|---|-------|---------|-----------|
| C-001 | Claude Code loads tools lazily, not all at once | **Confirmed** | No, but the mechanism was unexpected |
| C-002 | Arglist name heuristic is 80%+ precise for text functions | **Refuted (40%)** | Yes — `object`/`buffer` args dominate false positives |
| C-003 | emacsclient round-trip < 50ms | **Confirmed (2.3ms median)** | The margin was surprising — 20x under threshold |
| C-004 | Non-ASCII survives the full round trip | **Confirmed** | 14 character classes, all byte-identical |
| C-005 | More tools = measurably slower init | **Confirmed** | Wall-clock is negligible; token cost is the real tax |
| C-006 | Vanilla Emacs has far fewer functions than configured | **Confirmed (18.7% delta)** | Smaller delta than expected |

---

## The Interesting Findings

### 1. Claude Code has a two-tier tool architecture

The MCP protocol is **eager** — `tools/list` dumps everything in one
response. No pagination used in practice.

But Claude Code doesn't inject all tool schemas into the LLM context.
Instead:

- **Tier 1**: Tool *names only* appear as `<available-deferred-tools>`
  in the system prompt (compact, low token cost)
- **Tier 2**: Full JSON schemas are fetched **on demand** via
  `ToolSearch` when the model decides it needs a specific tool

This means 780 tools cost roughly the same context as 60 tools at
session start. The protocol boundary (MCP) doesn't paginate, but the
application boundary (Claude Code) does lazy-load.

**Implication**: A naive MCP client that stuffs all schemas into the
prompt would choke on 3,600 tools (~341k tokens of schema alone).
Claude Code doesn't, but the protocol doesn't prevent it.

### 2. The arglist heuristic is broken

We conjectured that matching argument names like `string`, `buffer`,
`object` against Emacs function signatures would identify text-useful
functions with >80% precision. A 50-function audit showed **40%**.

The culprits:
- `object`/`obj` matches every type predicate (`bignump`,
  `compiled-function-p`) and EIEIO method — 12 false positives
- `buffer` matches window management functions (`display-buffer-*`)
  — 10 false positives
- `string` in compound names catches completion internals — 5 false
  positives

Meanwhile, useful functions like `buffer-string` (no args),
`char-to-string` (arg: `char`), and `insert` (arg: `args`) are missed
entirely.

**This is the intended finding.** The project is arguing *against*
curation. Even a reasonable-sounding heuristic fails. The alternative
— just expose everything — is what we're testing.

### 3. The token tax, not latency, is the real constraint

| Mode | Tools | Init time | Schema size | Est. tokens |
|------|-------|-----------|-------------|-------------|
| Core | 60 | 0.1ms | 21 KB | ~5,700 |
| Maximalist | 780 | 1.7ms | 263 KB | ~67,000 |
| Full (projected) | 3,600 | ~10ms | 1.3 MB | ~341,000 |

Init latency scales linearly but stays under 100ms even at 3,600
tools. Nobody would notice.

The **token budget** is what breaks. 341k tokens of tool definitions
would consume a third of a million-token context window before a
single user message. This validates the project's thesis: naive
"enumerate everything" MCP design fails not because of speed, but
because of context saturation.

### 4. Emacs is absurdly fast as an IPC target

emacsclient round-trip: **2.3ms median**. That's TCP, not even Unix
socket. String transformation, regex, case conversion -- all under 3ms
at P95. The 50ms threshold was conservative by 20x.

With the pure Elisp server (`emcp-stdio.el`), local tool dispatch is
in-process via `funcall` -- effectively zero IPC overhead. Emacs is
not the bottleneck in any realistic MCP tool-call chain.

### 5. Unicode just works

14 character classes including ZWJ emoji families, Arabic, Thai,
Korean, CJK, combining characters, supplementary plane, flag emoji.
Every one survived the full JSON -> Elisp -> JSON round trip
byte-identical.

The reason is simple: `json-parse-string` handles UTF-8 natively,
and `json-serialize` + `decode-coding-string` preserves it on output.
Emacs handles Unicode natively. No transformation, no corruption.

---

## The Meta-Point

### What this project is NOT
- A useful Emacs MCP integration (use emacs-mcp-curated for that)
- An AI assistant inside Emacs (use gptel or ellama)
- A language server bridge (use eglot)

### What this project IS
- A **constructive proof** that the MCP tool enumeration model has a
  token-budget ceiling
- A **test rig** for measuring how real MCP clients handle tool
  overload
- A **reductio ad absurdum**: if your MCP design works with 60 tools
  but breaks at 3,600, the design has an implicit scaling assumption
  that should be made explicit

### The thesis in one sentence

> The MCP protocol has no built-in answer to "how many tools is too
> many?" — and the answer matters because the constraint isn't
> latency or bandwidth, it's the LLM's context window.

---

## Method: Conjecture-Driven Development

This project uses a development method we're calling
**conjecture-driven development**:

1. **State a falsifiable claim** before writing code (e.g., "latency
   will be under 50ms")
2. **Build the minimum artifact** needed to test it (the MCP server,
   the manifest, the escape layer)
3. **Instrument the implementation** so every conjecture has a
   corresponding measurement hook
4. **Run the measurements** and record confirmed / refuted /
   indeterminate with data
5. **The refutations are the interesting results** — C-002's failure
   at 40% precision tells us more than C-003's comfortable 2.3ms
   confirmation

The CLAUDE.md file acts as a **fixed-point kernel**: it contains the
axiom, the conjectures, the build order, and the acceptance criteria.
An agent (human or AI) can pick up the project from CLAUDE.md alone
and know exactly what to build and how to verify it.

---

## Reproduction

```bash
# Prerequisites: Emacs 28+ installed
# Start core server (~779 tools, vanilla Emacs)
gmake run-core

# Start maximalist server (~3600+ tools, with user init)
gmake run-max

# Run ERT tests
gmake test

# Health check (optional, requires daemon)
emacs --daemon
bin/health-check.sh
```

All conjectures are independently re-measurable via the integration
test suite (`tests/test_emcp_stdio_integration.sh`).

---

## Status

| Item | State |
|------|-------|
| Conjectures measured | 6/6 |
| Confirmed | 5 (C-001, C-003, C-004, C-005, C-006) |
| Refuted | 1 (C-002: arglist precision is 40%, not 80%) |
| CI | Green (Emacs 28.2/29.4/30.1) |
| Open issues | 6 remaining (build step tracking) |
| Lines of Elisp | ~250 (emcp-stdio.el) |

---

*Built with Claude Code against a live Emacs 30.2 daemon.
Measured 2026-03-18.*
