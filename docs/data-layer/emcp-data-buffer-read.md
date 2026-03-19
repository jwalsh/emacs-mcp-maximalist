# emcp-data-buffer-read

Test results for the `emcp-data-buffer-read` daemon tool.

Date: 2026-03-18
Emacs: 30.2 (emacsclient 30.2, macOS/darwin)
Server: emcp-stdio.el (pure Elisp MCP, batch mode + daemon dispatch)

## Tool Definition

From `src/emcp-stdio.el` line 157-159:

```
("emcp-data-buffer-read"
 "(buffer-name)"
 "Read the full contents of BUFFER-NAME from the running Emacs daemon."
 :build)
```

## Sexp Builder

Line 223-225:

```elisp
(format "(with-current-buffer %S (buffer-substring-no-properties (point-min) (point-max)))"
        (nth 0 args))
```

For `*scratch*` this produces:

```elisp
(with-current-buffer "*scratch*" (buffer-substring-no-properties (point-min) (point-max)))
```

The `%S` format specifier handles quoting of the buffer name argument.

## Test Protocol

Each test sends JSON-RPC messages to `emacs --batch -Q -l src/emcp-stdio.el
-f emcp-stdio-start` via stdin. The batch process dispatches `emcp-data-*`
tools to the running daemon via `emacsclient --eval`.

**Note:** The `emcp-stdio--check-daemon` function uses `--timeout 3` which
can hang on emacsclient 30.2 when the daemon is under load. Tests were run
with a patched check that omits `--timeout`. See "Known Issue" below.

## Results

### Test 1: `*scratch*` -- standard buffer contents

**Input:**
```json
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"emcp-data-buffer-read","arguments":{"args":["*scratch*"]}}}
```

**Output:**
```json
{"jsonrpc":"2.0","id":10,"result":{"content":[{"type":"text","text":"\";; This buffer is for text that is not saved, and for Lisp evaluation.\\n;; To create a file, visit it with 'C-x C-f' and enter text in its buffer.\\n\\n\""}]}}
```

**Verdict:** PASS. Returns default scratch buffer content.

### Test 2: `*Messages*` -- log messages

**Output:**
```json
{"jsonrpc":"2.0","id":11,"result":{"content":[{"type":"text","text":"\" stop  Warning (initialization): ...Starting Emacs daemon.\\nNo buffer named nonexistent-buffer-xyz\\n\""}]}}
```

**Verdict:** PASS. Returns daemon log messages.

### Test 3: Nonexistent buffer -- error handling

**Input:**
```json
{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"emcp-data-buffer-read","arguments":{"args":["nonexistent-buffer-xyz"]}}}
```

**Output:**
```json
{"jsonrpc":"2.0","id":12,"result":{"content":[{"type":"text","text":"error: daemon-eval failed: *ERROR*: No buffer named nonexistent-buffer-xyz"}],"isError":true}}
```

**Verdict:** PASS. Returns `isError: true` with descriptive message. The error
originates from Emacs's `with-current-buffer` macro which signals when the
buffer does not exist.

### Test 4: Special characters -- JSON escaping

Buffer contents: `He said "hello" and then\nnewline\there\ttab\nspecial: \\ backslash`

**Output text field (decoded from JSON):**
```
"He said \"hello\" and then\nnewline	here	tab\nspecial: \\\\ backslash"
```

**Analysis:**
- Embedded double-quotes: escaped as `\"` (by Elisp printer), then `\\"` in JSON.
- Newlines: represented as `\n` (Elisp escape), then `\\n` in JSON.
- Tabs: literal tab characters pass through (not escaped by Elisp printer).
- Backslashes: double-escaped (`\\\\` in JSON -> `\\` after JSON parse -> `\` in original).

**Verdict:** PASS. All special characters survive the round trip.

### Test 5: Unicode -- CJK, emoji, combining characters

Buffer contents: `日本語 emoji: (party popper emoji) combining: e + combining acute`

**Output text field:**
```
"日本語 emoji: 🎉 combining: é"
```

**Verdict:** PASS. CJK characters, emoji (U+1F389), and combining characters
(e + U+0301) all survive the daemon -> emacsclient -> batch -> JSON round trip.

### Test 6: Large buffer -- 1000 lines (28KB)

**Output:** 29,002 chars in text field. All 1000 newlines present.

**Verdict:** PASS. No truncation at 28KB.

### Test 7: Very large buffer -- 5000 lines (145KB)

**Output:** 150,002 chars in text field. All 5000 newlines present. JSON
response size: 155KB.

**Verdict:** PASS. No truncation at 145KB.

### Test 8: 10,000 lines (110KB)

**Output:** 120,002 chars in text field. All 10,000 newlines present. JSON
response size: 130KB.

**Verdict:** PASS. No truncation at 110KB.

### Test 9: Empty buffer

**Output:**
```json
{"jsonrpc":"2.0","id":17,"result":{"content":[{"type":"text","text":"\"\""}]}}
```

**Verdict:** PASS. Returns empty Elisp string representation `""`.

## Quoting Layers

The returned `text` field contains the **Elisp print representation** of the
string, not the raw string itself. This means:

1. The value is wrapped in Elisp double-quotes (`"..."`)
2. Newlines appear as `\n` (two chars) not actual newline
3. Embedded quotes are escaped as `\"`
4. Backslashes are escaped as `\\`

After JSON parsing, a consumer gets the Elisp-printed form. To recover the
raw content, the consumer would need to strip the outer quotes and unescape
Elisp string escapes. This is a consequence of how `emacsclient --eval`
prints return values.

## Output Truncation

**No truncation observed** up to 150KB of JSON response text. The tool uses
`buffer-substring-no-properties` which returns the complete buffer. Neither
the emacsclient IPC layer nor the MCP JSON serialization truncates the output.

For very large buffers (570KB+), the emacsclient call itself may time out or
the daemon may become unresponsive under concurrent load. This is a
transport-level concern, not a truncation policy.

## Known Issue: `--timeout` flag in daemon check

`emcp-stdio--check-daemon` (line 120-124) passes `--timeout 3` to
`emacsclient`. On emacsclient 30.2 (macOS), this flag can cause the
`call-process` to hang when:

- The daemon socket exists but the daemon is busy/blocked
- A remote socket is configured and unreachable

The `--timeout` flag is documented as "Seconds to wait before timing out"
but it applies to TCP connections, not local Unix sockets. When the daemon is
processing a large eval, the socket connection succeeds (no timeout) but the
response blocks indefinitely.

**Workaround used in testing:** Override the check to omit `--timeout`:

```elisp
(defun emcp-stdio--check-daemon ()
  (condition-case nil
      (zerop (call-process "emacsclient" nil nil nil
                           "--eval" "(emacs-pid)"))
    (error nil)))
```

## Summary

| Test | Buffer | Size | Result |
|------|--------|------|--------|
| 1 | `*scratch*` | 119B | PASS |
| 2 | `*Messages*` | ~250B | PASS |
| 3 | nonexistent | N/A | PASS (isError) |
| 4 | special chars | 63B | PASS |
| 5 | unicode/CJK/emoji | 26B | PASS |
| 6 | 1000 lines | 28KB | PASS |
| 7 | 5000 lines | 145KB | PASS |
| 8 | 10000 lines | 110KB | PASS |
| 9 | empty | 0B | PASS |

All nine tests pass. The tool correctly reads buffer contents from the
daemon, handles errors for nonexistent buffers, preserves special characters
and Unicode, and does not truncate large outputs.
