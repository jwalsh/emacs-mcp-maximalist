## Your Role

You are a coding agent working on emacs-mcp-maximalist. You write code,
run tests, and fix failures. You do not plan without implementing.

## Foundational Axiom

**The MCP server does not know what Emacs can do. Emacs tells it.**

All tool definitions are derived at runtime from a live Emacs process via
`obarray` introspection. No function list is hardcoded. If you are
hardcoding function names anywhere except tests, you have violated the
axiom. Do not optimize for curation or hand-picked tool selection at any
layer of the stack.

## Confirmation Gate

Before writing any code, output a one-paragraph summary of what you
understand emacs-mcp-maximalist to be, who its primary user is, and
what its primary output artifact is.

## What You Are Building

- An MCP server that exposes every text-consuming function in Emacs's
  `obarray` as an MCP tool, introspected at runtime from a live Emacs
  process. The primary user is agentic runtimes (Claude Code, MCP
  clients) — not human Emacs users.
- The server is `src/emcp-stdio.el` — a pure Elisp implementation that
  walks the obarray, builds tool definitions, and speaks MCP over stdio,
  all in a single Emacs process.
- A deliberate reductio ad absurdum: the system must work to prove that
  naive "enumerate all tools" MCP design saturates agent context windows

## Explicit Anti-Goals

- **Curated function subset** (c.f. emacs-mcp-curated): curation is the
  thesis being argued against. A hand-picked list makes the artifact a
  utility, not a demonstration. The critique only works if every function
  is exposed.
- **General Emacs IDE integration** (c.f. emacs-lsp, eglot, copilot.el):
  those optimize for editor<->language-server protocol. This project uses
  MCP as the protocol boundary — different axis entirely.
- **AI assistant inside Emacs** (c.f. gptel, ellama): those embed the
  agent in the editor. This project exposes the editor to the agent.
  Inverted control flow.
- **Config-dependent wrapper**: the introspector must work against a
  vanilla `emacs -Q`. Requiring the user's init.el breaks
  reproducibility.
- **External language dependency**: this is a pure Elisp project. Emacs
  Lisp owns introspection, dispatch, and protocol. There is no external
  language runtime in the stack.

## Key Design Decisions

- `emcp-stdio.el` is the main artifact — a single-file Elisp MCP server
- The obarray is the tool registry; `funcall` is the dispatch
- No manifest files — the obarray walk happens at startup in-process
- Security surface is `prin1-to-string` / `format "%S"` — Emacs's own
  serialization handles argument escaping natively
- `emacsclient --eval` as the IPC boundary for daemon data-layer tools
- Category classification by symbol naming convention, not manual tagging

## Introspection Locality Constraint

The Emacs process is the sole authority on what functions exist. No
component outside the Emacs process may define, filter, or augment the
function list.

Per-component implications:
- **emcp-stdio.el**: walks `obarray`, builds tool definitions, serves
  MCP protocol, dispatches via `funcall`. The only code that touches
  the function list, and also the only server component.
- **health-check.sh**: checks that the server starts and daemon is
  running. Does not read function names.

## Build Order

1. **emcp-stdio.el** — `emacs --batch -Q -l src/emcp-stdio.el -f emcp-stdio-start`
   starts, responds to `tools/list` over stdio, and returns tool definitions
2. **ert tests** — `emacs --batch -Q -l tests/test-emcp-stdio.el -f ert-run-tests-batch`
   passes all cases (argument escaping, tool registration, JSON-RPC framing)
3. **daemon integration** — with `emacs --daemon` running, the server
   detects it and registers 9 additional data-layer tools
4. **end-to-end** — `tools/call` with `string-trim` and input `" hello "`
   returns `"hello"`
5. **health-check.sh** — exits 0 on a correctly configured machine

If an acceptance test fails, stop. Document what failed, what you tried,
and what the blocker is. Do not proceed to the next step. Surface the
failure as a CPRR refutation candidate.

## Decomposition Protocol

Any non-trivial decomposition (spec → tasks, conjecture → measurements,
feature → implementation plan) requires two agents:

1. **Builder**: Decomposes the work into beads, conjectures, and
   implementation tasks with priority tiers and dependency graphs.

2. **Reviewer (guard)**: Runs in parallel. Evaluates completeness of
   the decomposition by:
   - **Gap analysis**: failure modes, unstated assumptions, unmeasurable
     conjectures not covered by the builder's output
   - **Competing systems**: prior art, related concepts, cautionary
     tales (e.g., vm2 sandbox escapes)
   - **Historical context**: lineage, academic references, ecosystem
     position
   - **Missing conjectures**: propose a C-H (hardening) series for
     anything the builder missed

The reviewer does not implement — they surface what the builder assumed
but did not state. Both outputs are committed; conflicts between them
are resolved by the coordinator (human or orchestrating agent).

Agents that modify code must use `isolation: "worktree"`. Research-only
agents (docs, reviews, gap analysis) do not need worktrees. All work
items get beads before agent launch. Merge requires review of the
worktree diff against contracts before commit.

## Component Architecture

| Layer | File | Responsibility |
|-------|------|---------------|
| L0 | `emacs` | Running Emacs (batch or daemon, prerequisite) |
| L1 | `src/emcp-stdio.el` | Pure Elisp MCP server: obarray walk, tool registration, JSON-RPC, dispatch |
| L2 | `bin/health-check.sh` | Structured health check (JSON, exit codes) |

## Runtime Modes

| Mode | Transport | Tool count | Use case |
|------|-----------|------------|----------|
| `elisp-core` | stdio | ~779 + 9 daemon | The server |

The obarray walk at startup determines the tool count. No manifest,
no mode selection by file.

## Open Conjectures

Each conjecture requires a corresponding measurement hook in the
implementation.

- **C-001**: Claude Code uses on-demand tool indexing and does not load
  all tool definitions into context at session start. *Falsification*:
  large tool count produces measurable token overhead at tool-call time.
  *Prior evidence*: confirmed in original session (2026-02-04); treat
  as re-verification.
- **C-002**: The arglist heuristic (string/buffer/object parameter names)
  yields > 80% precision on "actually useful for text transformation."
  *Falsification*: manual audit of 50 random functions from the tool list.
- **C-003**: `emacsclient` round-trip latency is < 50ms for pure string
  functions. *Falsification*: tool call latency is user-visible.
- **C-004**: Non-ASCII input survives the `prin1-to-string` -> `funcall`
  -> stdout round trip without corruption. *Falsification*: test with CJK,
  emoji, combining characters.
- **C-005**: A large tool count (~779) causes a measurable latency
  difference vs. a smaller subset at MCP session init.
- **C-006**: A vanilla Emacs (`-Q`) exposes substantially fewer functions
  than one with user init loaded. *Falsification*: the counts are
  identical or nearly so. *Implication*: validates that the introspector
  should run against vanilla Emacs for reproducibility.

## Instrumentation Requirement

Each conjecture listed above must have a corresponding measurement hook
in the implementation. Conjectures are not background reading — they are
testable claims that drive instrumentation. If you cannot point to a
measurement for a conjecture, the implementation is incomplete.

## Security Boundary

The security surface is Emacs's own serialization: `prin1-to-string` for
argument escaping and `format "%S"` for sexp construction. Edge cases
handled:

- Unbalanced parentheses
- Embedded quotes
- Null bytes
- Shell metacharacters
- Newlines

These are tested via `ert` in the test suite.

## Research Context

- Original session: [chat/9b7cf6a1](https://claude.ai/chat/9b7cf6a1-cd64-4eae-bb33-28e370783c20) (2026-02-04)
- Original artifact: [gist:cc7f50fe](https://gist.github.com/aygp-dr/cc7f50fece2107f8c5b566d1f9cf38ad) — `functions-compact.jsonl`, 3169 functions

## Stack Preferences

| Component | Choice | Rationale |
|-----------|--------|-----------|
| MCP server | Emacs Lisp (`emcp-stdio.el`) | Emacs IS the server; no process boundary |
| Introspection | Emacs Lisp | Only thing with live access to obarray |
| Argument escaping | `prin1-to-string` | Native serialization; no custom escaper needed |
| Protocol | JSON-RPC over stdio | MCP spec; `json-serialize` / `json-parse-string` built-in |
| Daemon IPC | `emacsclient` | Standard Emacs daemon interface |
| Tests | `ert` | Native Emacs Lisp test framework |
| Build | `gmake` | Consistent with homelab conventions |
| Spec format | `org-mode` | Canonical; tangleable; Mermaid-embeddable |

## Acceptance: End-to-End Test

Given Emacs 28+ installed:

1. `emacs --batch -Q -l src/emcp-stdio.el -f emcp-stdio-start` starts
   and responds to `tools/list` with >= 700 tools
2. `tools/call` with `string-trim` and `" hello "` returns `"hello"`
3. With `emacs --daemon` running, the server detects it and registers
   9 additional daemon data-layer tools
4. `bin/health-check.sh` exits 0 and produces valid JSON
5. All conjectures have measurement notes in `CONJECTURES.md`
   (confirmed, refuted, or indeterminate with data)

This is the system's definition of done.
