# C-005: Maximalist vs Core Init Latency

**Note**: This research doc references the historical Python stack
(server.py, create_server, JSONL manifest loading) which has been
removed. The conjecture result (Confirmed) remains valid. The pure
Elisp server measures init latency via `mapatoms` introspection
time rather than manifest loading time.

## Conjecture

The maximalist manifest (all functions) causes a measurable latency
difference vs. core manifest at MCP session init.

## Background

The MCP server loads the JSONL manifest at startup and registers each
entry as a Tool. With ~3600 entries (maximalist) vs. ~50 entries
(core), the question is whether this loading difference produces a
user-perceptible delay at session initialization.

## Falsification Criteria

The conjecture is falsified if there is NO measurable latency
difference (< 10ms delta) between core and maximalist modes at init,
suggesting that manifest size is irrelevant to startup performance.

Note: the conjecture predicts a difference EXISTS. Falsification means
the difference does NOT exist.

## Measurement Approach

1. **Server construction time**: time `create_server()` for both
   manifests.

```python
import time
from pathlib import Path
from server import create_server

for manifest in ["functions-core.jsonl", "functions-compact.jsonl"]:
    times = []
    for _ in range(20):
        t0 = time.monotonic_ns()
        app, count = create_server(Path(manifest))
        elapsed_ms = (time.monotonic_ns() - t0) / 1_000_000
        times.append(elapsed_ms)
    median = sorted(times)[10]
    print(f"{manifest}: {count} tools, median init {median:.1f}ms")
```

2. **tools/list response time**: measure time from JSON-RPC request
   to response over stdio.

3. **Memory footprint**: compare RSS after init for both modes.

4. **Claude Code session start**: if possible, measure wall-clock time
   from Claude Code launch to first tool availability for both modes.

## Confounds

- **Python startup overhead**: dominates small-manifest loading time.
  The delta between core and maximalist is what matters, not absolute
  times.
- **File I/O caching**: second run may be faster due to OS page cache.
  Use alternating runs or clear cache between measurements.
- **MCP SDK overhead**: the `Server` object may have per-tool
  registration cost that scales linearly. Need to measure SDK
  internals separately from manifest parsing.
- **JSONL parsing cost**: `json.loads` per line is O(n) in line count.
  For 3600 lines of ~100 bytes each, this is ~360KB of JSON parsing.
  Expected to be < 50ms on modern hardware.

## Expected Results

Rough estimates:
- JSONL parsing: ~5ms for 50 lines, ~50ms for 3600 lines
- Tool object creation: ~1ms for 50, ~30ms for 3600
- Total delta: ~50-100ms (measurable but not user-visible at < 200ms)

If the delta is > 500ms, the server architecture may need pagination
or lazy registration. If < 10ms, manifest size is irrelevant to user
experience.

## Instrumentation Hook

Add timing to `create_server`:

```python
import time
import os

def create_server(manifest_path):
    t0 = time.monotonic_ns()
    functions = load_manifest_jsonl(manifest_path)
    t1 = time.monotonic_ns()
    tools = build_tools(functions)
    t2 = time.monotonic_ns()
    # ... rest of function ...
    if os.environ.get("EMCP_TRACE") == "1":
        parse_ms = (t1 - t0) / 1_000_000
        build_ms = (t2 - t1) / 1_000_000
        print(f"TRACE init: parse={parse_ms:.1f}ms build={build_ms:.1f}ms "
              f"total={parse_ms+build_ms:.1f}ms tools={len(tools)}",
              file=sys.stderr)
    return app, tool_count
```

## Status

**Not yet measured.** Requires both manifests to exist
(`functions-core.jsonl` and `functions-compact.jsonl`). Experiment
design is ready.
