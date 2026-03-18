# C-001: Claude Code On-Demand Tool Indexing

## Conjecture

Claude Code uses on-demand tool indexing and does not load all tool
definitions into context at session start.

## Prior Evidence

Confirmed in original session (2026-02-04): Claude Code connected to
a maximalist manifest (~3169 tools) without crashing. If all tool
definitions were loaded eagerly into context, the token budget would be
saturated immediately.

## Falsification Criteria

The conjecture is falsified if a large manifest produces measurable
token overhead at tool-call time proportional to total manifest size
(i.e., the full tool list is stuffed into every request).

## Measurement Approach

1. **Session init latency**: time from `tools/list` request to response
   with core (~50 tools) vs. maximalist (~3600+ tools). If indexing is
   lazy, init latency should scale sub-linearly.

2. **Per-call token overhead**: instrument `server.py` to log request
   size on each `tools/call` invocation. If lazy, the request payload
   should not contain the full tool list.

3. **Memory footprint delta**: compare Claude Code process memory
   between core and maximalist sessions using `ps -o rss`.

4. **MCP protocol trace**: enable stdio logging to capture the full
   JSON-RPC exchange. Check whether `tools/list` response is requested
   once at init or repeatedly.

## Confounds

- Claude Code may cache the full tool list in memory but only inject
  relevant tools into the LLM context window (two-tier indexing). This
  would show low token overhead but high memory.
- Network latency to the Claude API dominates, masking init differences.
- The MCP SDK may batch or paginate `tools/list` responses, hiding the
  true loading behavior.

## Experiment Design

```bash
# A/B comparison
# Terminal 1: core mode
time echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | \
  python src/server.py functions-core.jsonl

# Terminal 2: maximalist mode
time echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | \
  python src/server.py functions-compact.jsonl

# Memory measurement
python src/server.py functions-compact.jsonl &
PID=$!
sleep 2
ps -o rss= -p $PID
```

## Status

**Re-verification pending.** Prior evidence supports the conjecture.
Needs fresh measurement with current Claude Code version and the
project's own manifest.
