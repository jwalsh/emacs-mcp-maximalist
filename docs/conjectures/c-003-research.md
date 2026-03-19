# C-003: emacsclient Round-Trip Latency

**Note**: This research doc references the historical Python stack
(dispatch.py, subprocess.run) which has been removed. Measurements
were taken using that stack; the conjecture result (Confirmed, 2.3ms
median) remains valid. The pure Elisp server eliminates the emacsclient
round-trip for local tools entirely.

## Conjecture

`emacsclient` round-trip latency is < 50ms for pure string functions.

## Background

The MCP server dispatches every tool call through `emacsclient --eval`.
If this IPC boundary adds user-visible latency (> ~200ms), the system
becomes impractical for interactive use. The conjecture sets a tighter
bar: < 50ms for pure string functions (no I/O, no buffer mutation).

## Falsification Criteria

The conjecture is falsified if the median round-trip time for pure
string function calls exceeds 50ms, measured over 100 invocations.

## Measurement Approach

1. **Microbenchmark**: time a simple string operation repeatedly.

```bash
# Warm-up (first call may include socket setup)
emacsclient --eval '(+ 1 1)' > /dev/null

# 100 iterations of string-trim
for i in $(seq 1 100); do
  start=$(python3 -c 'import time; print(time.monotonic_ns())')
  emacsclient --eval '(string-trim "  hello  ")' > /dev/null
  end=$(python3 -c 'import time; print(time.monotonic_ns())')
  echo $(( (end - start) / 1000000 ))
done > /tmp/c003-latency.txt

# Statistics
python3 -c "
import statistics
data = [int(x) for x in open('/tmp/c003-latency.txt')]
print(f'median: {statistics.median(data)}ms')
print(f'p95:    {sorted(data)[94]}ms')
print(f'p99:    {sorted(data)[98]}ms')
print(f'mean:   {statistics.mean(data):.1f}ms')
"
```

2. **Comparison operations**: benchmark across complexity levels:
   - Trivial: `(+ 1 1)` (no string, baseline IPC cost)
   - String: `(string-trim " hello ")`
   - Regexp: `(replace-regexp-in-string "o" "0" "hello world")`
   - Buffer: `(with-temp-buffer (insert "test") (buffer-string))`

3. **Python subprocess overhead**: measure dispatch.py's own overhead
   (subprocess.run setup, stdout parsing) separately from emacsclient.

## Confounds

- macOS socket IPC may be faster/slower than Linux (Darwin's Unix
  domain socket implementation differs).
- System load affects measurements. Run on idle machine.
- The first emacsclient invocation per session may be slower due to
  socket connection establishment (amortized in subsequent calls).
- Python's subprocess.run adds ~5-15ms of its own overhead for process
  creation, which is part of the real-world latency but not
  emacsclient's fault.

## Experiment Design

Two-level measurement:
1. **Shell-level**: `time emacsclient --eval` (includes process start)
2. **Python-level**: `dispatch.eval_in_emacs()` timing (includes
   subprocess overhead)
3. **Pure IPC**: emacsclient with `--no-wait` isn't useful here since
   we need the return value. Instead, measure the delta between (1)
   and a no-op process creation to isolate IPC cost.

## Instrumentation Hook

Add optional timing to `dispatch.py`:

```python
import time
import os

EMCP_TRACE = os.environ.get("EMCP_TRACE", "0") == "1"

def eval_in_emacs(sexp, timeout=10):
    t0 = time.monotonic_ns() if EMCP_TRACE else 0
    # ... existing code ...
    if EMCP_TRACE:
        elapsed_ms = (time.monotonic_ns() - t0) / 1_000_000
        print(f"TRACE dispatch {elapsed_ms:.1f}ms: {sexp[:60]}", file=sys.stderr)
    return result.stdout.strip()
```

## Status

**Not yet measured.** Requires running Emacs daemon. Experiment design
is ready for execution.
