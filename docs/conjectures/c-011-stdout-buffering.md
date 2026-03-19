# C-011: Emacs Batch Mode Stdout Buffering

## Status: Confirmed and Fixed

Fixed in commit `08252a1` using `send-string-to-terminal`. Four
independent agents validated the diagnosis and tested six approaches.

## Conjecture

`princ` + `terpri` in Emacs batch mode does not flush stdout to a
pipe until process exit or buffer-full. This means interactive MCP
clients cannot receive responses until the server exits, violating
the stdio transport requirement for line-by-line response delivery.

## Approach Testing (4 agents, 6 approaches)

| Approach | Works? | Notes |
|----------|--------|-------|
| `princ` + `terpri` | NO | libc stdio fully buffered on pipes |
| `princ` + `sit-for 0` | NO | sit-for does not trigger fflush |
| `send-string-to-terminal` | YES | Direct fd 1 write, cross-platform (chosen) |
| `write-region /dev/stdout` | YES | Bypasses libc via write(2), Unix only |
| `write-region /dev/fd/1` | YES | Same mechanism, macOS/Linux |
| `call-process-region` + `cat` | NO | Output goes to standard-output variable |

Secondary finding: `emcp-stdio--check-daemon` hanging on unreachable
remote sockets was the primary startup blocker in many cases. Fixed
with `--timeout 3` and `condition-case`.

## Evidence

### Works (non-interactive)

Piping a heredoc (stdin closes after all messages sent):
```bash
cat <<'EOF' | emacs --batch -Q -l src/emcp-stdio.el -f emcp-stdio-start 2>/dev/null
{"jsonrpc":"2.0","id":1,"method":"initialize",...}
{"jsonrpc":"2.0","id":2,"method":"tools/call",...}
EOF
```
All responses appear after EOF. The server processes everything,
then Emacs flushes stdout on exit.

### Fails (interactive)

Sending messages one at a time with stdin still open:
```python
p = subprocess.Popen(['emacs','--batch','-Q','-l','src/emcp-stdio.el',...],
                     stdin=PIPE, stdout=PIPE, bufsize=0)
p.stdin.write(b'{"jsonrpc":"2.0","id":1,"method":"initialize",...}\n')
p.stdin.flush()
time.sleep(2)
# stdout has ZERO bytes available
```

### Paradox

Claude Code works with this server. Claude Code launches the server
as a subprocess over stdio. If stdout is truly buffered, how does
Claude Code receive responses?

Possible explanations:
1. Claude Code's MCP client may send all messages, then close stdin,
   triggering flush-on-exit (batch mode)
2. The OS pipe buffer (~64KB) may be large enough for the initialize
   response, and the MCP client reads after sending
3. Emacs may flush when `read-from-minibuffer` blocks waiting for
   the next line (yielding to the event loop)
4. The MCP SDK may use a different transport mechanism

## Potential Fixes

### A: Explicit flush via `send-string-to-terminal`
```elisp
(defun emcp-stdio--send (alist)
  (let ((json (decode-coding-string (json-serialize alist) 'utf-8)))
    (send-string-to-terminal (concat json "\n"))))
```
Risk: `send-string-to-terminal` may not work in batch mode.

### B: Set binary mode on stdout
```elisp
(set-binary-mode 'stdout t)
```
Already attempted in `emcp-stdio-start` but may not affect buffering.

### C: Use `external-debugging-output` function
```elisp
(princ json #'external-debugging-output)
```
This writes to stderr (fd 2), not stdout. Wrong fd but proves
the concept.

### D: Write directly to fd 1 via `call-process-region`
Use a subprocess to write to stdout:
```elisp
(call-process-region json nil "cat" nil nil)
```
Heavyweight but guaranteed unbuffered.

## Test Command

```bash
emacs --batch -Q --eval '
(progn
  (princ "line1\n")
  (sit-for 2)
  (princ "line2\n"))' | while IFS= read -r line; do
  echo "$(date +%s): $line"
done
```
If both timestamps are identical, output was buffered until exit.
If timestamps differ by ~2s, `sit-for` triggered a flush.

## Implications

If confirmed, this is a protocol compliance issue for interactive
MCP clients (MCP Inspector, Claude Desktop, mcp.el). The pipe-based
test (heredoc) masks the problem because EOF triggers flush.
