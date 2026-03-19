# Integration Test Plan: emcp-stdio.el

## Scope

End-to-end MCP protocol compliance testing for the pure-Elisp MCP server
(`src/emcp-stdio.el`). The server runs as `emacs --batch -Q -l src/emcp-stdio.el
-f emcp-stdio-start` and communicates via newline-delimited JSON-RPC 2.0 on
stdin/stdout.

## Test Matrix

### 1. Protocol Handshake

| Test ID | Method | Input | Expected Outcome |
|---------|--------|-------|------------------|
| H-01 | `initialize` | Standard params `{}` | Response with `protocolVersion`, `capabilities.tools`, `serverInfo` |
| H-02 | `initialize` | Verify `jsonrpc` field = `"2.0"` | Present in response |
| H-03 | `initialize` | Verify `id` field matches request | `id` in response == `id` in request |
| H-04 | `initialize` | Check `protocolVersion` value | `"2024-11-05"` |
| H-05 | `initialize` | Check `serverInfo.name` | `"emacs-mcp-elisp"` |
| H-06 | `initialize` | Check `serverInfo.version` | `"0.1.0"` |
| H-07 | `ping` | Standard params `{}` | Success response with empty result object |

### 2. Notifications

| Test ID | Method | Input | Expected Outcome |
|---------|--------|-------|------------------|
| N-01 | `notifications/initialized` | No `id` field | No response emitted |
| N-02 | arbitrary notification | No `id` field | No response emitted |

### 3. tools/list

| Test ID | Variation | Expected Outcome |
|---------|-----------|------------------|
| TL-01 | Standard request | Response contains `result.tools` as array |
| TL-02 | Tool count (`-Q` mode) | `>= 20` tools (CLAUDE.md acceptance) |
| TL-03 | Tool count (`-Q` mode) | Reasonable upper bound check (< 5000) |
| TL-04 | Each tool has `name` | String, non-empty |
| TL-05 | Each tool has `description` | String (may be empty) |
| TL-06 | Each tool has `inputSchema` | Object with `type: "object"` |
| TL-07 | `inputSchema` has `properties.args` | Array type with items |
| TL-08 | `inputSchema` has `required` | Contains `"args"` |
| TL-09 | Known functions present | `string-trim`, `concat`, `format` in tool list |
| TL-10 | Internal functions excluded | No `emcp-stdio-*` tools |

**Note on TL-09**: `upcase`, `downcase`, `capitalize`, and `string-reverse` have
arglist `(OBJ)` which does NOT match the text-consumer filter heuristic
(`string|text|str[^iua]|buffer|sequence|object`). They are excluded from
`tools/list` but remain callable via `tools/call` (dispatch uses `intern-soft` +
`fboundp`, not the filter). This is a C-002 observation: the heuristic has false
negatives for functions with generic parameter names.

### 4. tools/call -- Success Cases

| Test ID | Function | Args | Expected Output |
|---------|----------|------|-----------------|
| TC-01 | `upcase` | `["hello"]` | `"HELLO"` |
| TC-02 | `downcase` | `["HELLO"]` | `"hello"` |
| TC-03 | `string-trim` | `[" hello "]` | `"hello"` |
| TC-04 | `concat` | `["foo", "bar"]` | `"foobar"` |
| TC-05 | `capitalize` | `["hello world"]` | `"Hello World"` |
| TC-06 | `string-reverse` | `["abc"]` | `"cba"` |
| TC-07 | Response structure | Any | `result.content` is array |
| TC-08 | Content item type | Any | `content[0].type == "text"` |
| TC-09 | Content item text | Any | `content[0].text` is string |

### 5. tools/call -- Error Cases

| Test ID | Variation | Expected Outcome |
|---------|-----------|------------------|
| TE-01 | Unknown tool name | Response with `content[0].text` starting with `"error:"` |
| TE-02 | Tool exists but wrong arity | Response with error text (not crash) |
| TE-03 | Response still has valid JSON-RPC framing | `jsonrpc: "2.0"`, matching `id` |

### 6. Unknown Method

| Test ID | Method | Expected Outcome |
|---------|--------|------------------|
| UM-01 | `unknown/method` | Error response with code `-32601` |
| UM-02 | `foo` | Error response with `"Method not found"` message |

### 7. Unicode / Non-ASCII (C-004)

| Test ID | Input | Expected Outcome |
|---------|-------|------------------|
| U-01 | CJK: `upcase("cafe\u0301")` | Accent preserved |
| U-02 | CJK: `concat("hello ", "\u4e16\u754c")` | `"hello \u4e16\u754c"` |
| U-03 | Emoji: `concat("\ud83d\ude80", " launch")` | Emoji preserved in output |
| U-04 | Latin extended: `upcase("caf\u00e9")` | `"CAF\u00c9"` |

### 8. Sequential Requests

| Test ID | Variation | Expected Outcome |
|---------|-----------|------------------|
| SQ-01 | 5 sequential requests | 5 responses, ids match, all valid JSON |
| SQ-02 | Mixed methods | initialize + tools/list + tools/call all work in sequence |
| SQ-03 | Non-sequential IDs | IDs like 42, 7, 999 echoed correctly |

### 9. Malformed Input

| Test ID | Input | Expected Outcome |
|---------|-------|------------------|
| MI-01 | Empty line | Ignored, no crash |
| MI-02 | Invalid JSON | Ignored (logged to stderr), process continues |
| MI-03 | Valid JSON, missing `method` | No crash |

### 10. Daemon Tools (conditional)

| Test ID | Variation | Expected Outcome |
|---------|-----------|------------------|
| DT-01 | If daemon available, tools/list includes `emcp-data-*` | Count > 0 |
| DT-02 | If daemon available, `emcp-data-eval` works | `(+ 1 1)` returns `"2"` |
| DT-03 | If no daemon, daemon tools absent | Skip gracefully |

### 11. Performance Baselines (C-003, C-005)

| Test ID | Measurement | Threshold |
|---------|-------------|-----------|
| P-01 | Time from launch to first response | Report (no hard fail) |
| P-02 | tools/list latency | Report (no hard fail) |
| P-03 | tools/call latency (string-trim) | Report, note if > 200ms |
| P-04 | Tool count comparison: -Q vs full init | Report for C-005, C-006 |

## Protocol Compliance Checklist

- [x] JSON-RPC 2.0: every response has `"jsonrpc": "2.0"`
- [x] JSON-RPC 2.0: response `id` matches request `id`
- [x] JSON-RPC 2.0: success has `result`, error has `error`
- [x] JSON-RPC 2.0: error has `code` (integer) and `message` (string)
- [x] MCP initialize: returns `protocolVersion`, `capabilities`, `serverInfo`
- [x] MCP tools/list: returns `{ tools: [...] }`
- [x] MCP tools/call: returns `{ content: [{ type: "text", text: "..." }] }`
- [x] MCP notifications: no response for messages without `id`
- [x] Unknown method: error code `-32601`

## Conjectures Under Test

- **C-003**: Measured via P-01, P-02, P-03. Emacsclient is not in play for
  the pure-Elisp server, but batch Emacs eval latency is the analogous
  measurement.
- **C-004**: Measured via U-01 through U-04. Non-ASCII must survive the
  JSON parse -> Elisp eval -> JSON serialize round trip.
- **C-005**: Measured via P-04. Compare tool counts and startup time between
  `-Q` (vanilla) and full-init modes.
- **C-008** (functional parity): Confirmed. The pure Elisp server
  replaced the Python stack entirely. See `docs/conjectures/c-008-research.md`.

## Test Runner

- `tests/test_emcp_stdio_integration.sh`
- Exit 0 if all required tests pass
- Exit 1 if any required test fails
- Print summary: PASS/FAIL/SKIP counts
- `--verbose` flag for detailed output
- Uses `jq` for JSON parsing where available, falls back to shell-native parsing
- No external test framework dependency
