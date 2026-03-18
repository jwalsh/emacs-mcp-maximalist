## Your Role

You are a coding agent working on emacs-mcp-maximalist. You write code,
run tests, and fix failures. You do not plan without implementing.

## Foundational Axiom

**The MCP server does not know what Emacs can do. Emacs tells it.**

All tool definitions are derived at runtime from a live Emacs daemon via
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
  `obarray` as an MCP tool, introspected at runtime from a live daemon.
  The primary user is agentic runtimes (Claude Code, MCP clients) —
  not human Emacs users.
- Two runtime modes from one codebase: `core` (~50 tools) and
  `maximalist` (~3600+ tools), selected by manifest, not code
- A deliberate reductio ad absurdum: the system must work to prove that
  naive "enumerate all tools" MCP design saturates agent context windows

## Explicit Anti-Goals

- **Curated function subset** (c.f. emacs-mcp-curated): curation is the
  thesis being argued against. A hand-picked list makes the artifact a
  utility, not a demonstration. The critique only works if every function
  is exposed.
- **General Emacs IDE integration** (c.f. emacs-lsp, eglot, copilot.el):
  those optimize for editor↔language-server protocol. This project uses
  MCP as the protocol boundary — different axis entirely.
- **AI assistant inside Emacs** (c.f. gptel, ellama): those embed the
  agent in the editor. This project exposes the editor to the agent.
  Inverted control flow.
- **Config-dependent wrapper**: the introspector must work against a
  vanilla `emacs --daemon`. Requiring the user's init.el breaks
  reproducibility and makes the manifest non-portable.
- **Python-first architecture**: Emacs Lisp owns introspection and
  dispatch. Python is the MCP protocol shim only. If logic migrates
  from Elisp to Python, the axiom is being violated.

## Key Design Decisions

- Manifest is a build artifact (`functions-compact.jsonl`), not committed
- JSONL with compact keys (`n`/`s`/`d`) to minimize token cost
- `emacsclient --eval` as the IPC boundary — no custom protocols
- Security surface is the escaper (`src/escape.py`) — independently tested
- Category classification by symbol naming convention, not manual tagging

## Introspection Locality Constraint

The Emacs daemon is the sole authority on what functions exist. No
component outside the Emacs process may define, filter, or augment the
function list.

Per-component implications:
- **introspect.el**: walks `obarray`, emits manifest. Only code that
  touches the function list.
- **escape.py**: receives function names from the manifest. Never
  generates them.
- **dispatch.py**: calls `emacsclient --eval` with pre-built s-expressions.
  No function awareness.
- **server.py**: loads manifest, registers tools 1:1. No filtering,
  no augmentation.
- **health-check.sh**: checks that the manifest exists and daemon is
  running. Does not read function names.

## Manifest Format Invariant

The introspector (L1) and the server (L5) must agree on format. Two
formats exist; each step must name which it produces or consumes:

| Format | File | Structure | Producer | Consumer |
|--------|------|-----------|----------|----------|
| Full JSON | `emacs-functions.json` | `{"functions": [...], "statistics": {...}}` | `emcp-write-manifest` | tests, debugging |
| Compact JSONL | `functions-compact.jsonl` | one `{"n","s","d"}` per line | `emcp-write-manifest-compact` | server.py |

The server loads JSONL (line count = tool count). The introspector's
full-JSON mode is for development; compact JSONL is the build artifact.
If you add a new format, update this table and both producer/consumer.

## Build Order

1. **escape.py** — `pytest tests/test_escape.py` passes all cases
2. **introspect.el** — `(emcp-write-manifest "/tmp/test.json")` returns
   integer > 0 (full JSON mode); then
   `(emcp-write-manifest-compact "functions-compact.jsonl")` produces
   JSONL with `wc -l` > 0
3. **dispatch.py** — `eval_in_emacs('(+ 1 1)')` returns `"2"`
4. **server.py (core)** — loads JSONL manifest; `tools/list` returns
   >= 20 tools over stdio
5. **server.py (maximalist)** — loads full JSONL manifest; `tools/list`
   returns > 1000 tools; Claude Code indexes lazily
6. **health-check.sh** — exits 0 on a correctly configured machine

If an acceptance test fails, stop. Document what failed, what you tried,
and what the blocker is. Do not proceed to the next step. Surface the
failure as a CPRR refutation candidate.

## Component Architecture

| Layer | File | Responsibility |
|-------|------|---------------|
| L0 | `emacs --daemon` | Running Emacs (prerequisite, not built) |
| L1 | `src/introspect.el` | Walk obarray, emit manifest |
| L2 | `functions-compact.jsonl` | Build artifact — JSONL, not committed (see Manifest Format Invariant) |
| L3 | `src/escape.py` | Safe Elisp string literal builder |
| L4 | `src/dispatch.py` | emacsclient subprocess boundary |
| L5 | `src/server.py` | MCP server: loads manifest, registers tools, dispatches |
| L6 | `bin/health-check.sh` | Structured health check (JSON, exit codes) |

## Runtime Modes

| Mode | Transport | Tool count | Use case |
|------|-----------|------------|----------|
| `core` | stdio | ~50 | Practical daily use |
| `maximalist` | stdio | ~3600+ | The demonstration |

Mode is selected by which manifest is loaded, not by separate server code.

## Open Conjectures

Each conjecture requires a corresponding measurement hook in the
implementation.

- **C-001**: Claude Code uses on-demand tool indexing and does not load
  all tool definitions into context at session start. *Falsification*:
  large manifest produces measurable token overhead at tool-call time.
  *Prior evidence*: confirmed in original session (2026-02-04); treat
  as re-verification.
- **C-002**: The arglist heuristic (string/buffer/object parameter names)
  yields > 80% precision on "actually useful for text transformation."
  *Falsification*: manual audit of 50 random functions from manifest.
- **C-003**: `emacsclient` round-trip latency is < 50ms for pure string
  functions. *Falsification*: tool call latency is user-visible.
- **C-004**: Non-ASCII input survives the escape → emacsclient → Emacs →
  stdout round trip without corruption. *Falsification*: test with CJK,
  emoji, combining characters.
- **C-005**: The maximalist manifest (all functions) causes a measurable
  latency difference vs. core manifest at MCP session init.

## Instrumentation Requirement

Each conjecture listed above must have a corresponding measurement hook
in the implementation. Conjectures are not background reading — they are
testable claims that drive instrumentation. If you cannot point to a
measurement for a conjecture, the implementation is incomplete.

## Security Boundary

The escaper (`src/escape.py`) is the security surface. It must handle:
- Unbalanced parentheses
- Embedded quotes
- Null bytes (reject with `ValueError`)
- Shell metacharacters
- Newlines

The escaper is tested independently of the server. Every edge case
gets a test.

## Research Context

- Original session: [chat/9b7cf6a1](https://claude.ai/chat/9b7cf6a1-cd64-4eae-bb33-28e370783c20) (2026-02-04)
- Original artifact: [gist:cc7f50fe](https://gist.github.com/aygp-dr/cc7f50fece2107f8c5b566d1f9cf38ad) — `functions-compact.jsonl`, 3169 functions

## Stack Preferences

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Introspection | Emacs Lisp | Only thing with live access to obarray |
| Serialization | `json-encode` | Built-in; no external deps in Emacs |
| Protocol shim | Python + `mcp` | Anthropic SDK; stdio transport |
| Package manager | `uv` | Fast; lockfile reproducibility |
| IPC | `emacsclient` | Standard Emacs daemon interface |
| Tests | `pytest` | Escape and dispatch are pure; easy to unit test |
| Build | `gmake` | Consistent with homelab conventions |
| Spec format | `org-mode` | Canonical; tangleable; Mermaid-embeddable |

## Acceptance: End-to-End Test

Given a running Emacs daemon with default configuration:

1. `gmake manifest` produces `functions-compact.jsonl` with > 3000 entries
2. `gmake server-core` starts an MCP server that responds to `tools/list`
   with >= 20 tools and correctly executes `(string-trim " hello ")` → `"hello"`
3. `gmake server-max` starts an MCP server and Claude Code connects
   without crashing (re-verifies C-001)
4. `bin/health-check.sh` exits 0 and produces valid JSON
5. All five conjectures have measurement notes in `CONJECTURES.md`
   (confirmed, refuted, or indeterminate with data)

This is the system's definition of done.
