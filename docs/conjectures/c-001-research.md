# C-001: Claude Code On-Demand Tool Indexing

## Conjecture

Claude Code uses on-demand tool indexing and does not load all tool
definitions into context at session start.

## Status: Confirmed (refined)

Re-verified 2026-03-18 with protocol-level measurements. The conjecture
is confirmed, but the mechanism is more nuanced than originally stated.
See "Refined Model" below.

## Prior Evidence

Confirmed in original session (2026-02-04): Claude Code connected to
a maximalist manifest (~3169 tools) without crashing. If all tool
definitions were loaded eagerly into context, the token budget would be
saturated immediately.

## Falsification Criteria

The conjecture is falsified if a large manifest produces measurable
token overhead at tool-call time proportional to total manifest size
(i.e., the full tool list is stuffed into every request).

## 2026-03-18 Measurements

### Protocol-Level Analysis

Examined the MCP SDK (v1.26.0, protocol version 2025-11-25):

- `ListToolsRequest` inherits from `PaginatedRequest`, which accepts
  an optional `cursor` parameter.
- `ListToolsResult` has an optional `nextCursor` field for pagination.
- **However**, pagination is server-side optional. The server decides
  whether to paginate.
- This server returns ALL tools in a single `tools/list` response
  with `nextCursor=None` (no pagination).

**Key finding**: The MCP protocol supports pagination for `tools/list`,
but neither this server nor (as far as can be observed) Claude Code's
client uses it. All tools are sent in one response.

### Response Size Measurements

End-to-end MCP client-server measurements (stdio transport):

| Manifest | Tool count | JSON response size | Serialization | Est. tokens |
|----------|------------|-------------------|---------------|-------------|
| Core | 60 | 21,053 bytes (20.6 KB) | 1.7ms | ~5,263 |
| Maximalist | 780 | 269,055 bytes (262.7 KB) | 8.2ms | ~67,264 |
| Synthetic | 3,600 | 1,261,423 bytes (1.2 MB) | 60.1ms | ~315,356 |

All responses had `nextCursor=None`. All tools were returned in a
single `tools/list` response regardless of count.

### Initialization Timing

| Manifest | MCP initialize() | tools/list latency |
|----------|-------------------|-------------------|
| Core (60) | ~158ms | 1.7ms |
| Maximalist (780) | ~158ms | 8.2ms |
| Synthetic (3600) | ~165ms | 60.1ms |

The `initialize()` handshake is constant-time (~158ms). The
`tools/list` response scales linearly with tool count, as expected
for a full dump.

### Self-Observation (meta-measurement)

This investigation is being conducted by Claude Code (Opus 4.6, 1M
context) in a session where both `emacs-mcp-core` (60 tools) and
`emacs-mcp-maximalist` (780 tools) are configured in `.mcp.json`. The
session is functioning normally despite 840 total MCP tools being
available. This is direct evidence that tool definitions are not all
injected into every LLM context window.

Claude Code presents these tools as "deferred tools" -- listed by name
in `<available-deferred-tools>` but without full schema definitions.
The `ToolSearch` tool is used to fetch full schemas on demand. This
confirms a two-tier architecture:

1. **Tier 1 (names only)**: All tool names are listed in the system
   prompt as `<available-deferred-tools>`. This is a compact list.
2. **Tier 2 (full schema)**: When a tool is needed, `ToolSearch` is
   invoked to fetch the complete JSON schema definition.

### MCP Client Code Analysis

From `mcp/client/session.py`:

```python
async def list_tools(self, ...) -> types.ListToolsResult:
    # Sends tools/list request
    result = await self.send_request(
        types.ClientRequest(types.ListToolsRequest(params=request_params)),
        types.ListToolsResult,
    )
    # Caches output schemas for validation
    for tool in result.tools:
        self._tool_output_schemas[tool.name] = tool.outputSchema
    return result
```

The MCP client requests ALL tools and caches them locally. No filtering
or lazy loading at the MCP protocol level.

## Refined Model

The original conjecture ("on-demand tool indexing") is **confirmed** but
the mechanism operates at the Claude Code application layer, not the MCP
protocol layer:

```
MCP Server ---[tools/list: ALL tools]---> MCP Client (Claude Code)
                                               |
                                          Local cache
                                          (all 780 tools)
                                               |
                                    +----------+----------+
                                    |                     |
                              System prompt          ToolSearch
                           (names only, compact)   (full schema on demand)
                                    |                     |
                                    v                     v
                              LLM context            LLM context
                           (deferred names)        (fetched schemas)
```

1. **MCP layer**: Eager. All tools are requested and received at init.
   No pagination. ~263 KB for 780 tools.
2. **Claude Code application layer**: Lazy/indexed. Tool names appear
   in `<available-deferred-tools>`. Full schemas are fetched via
   `ToolSearch` only when needed. This is the "on-demand indexing."
3. **LLM context**: Only tool names (tier 1) plus any specifically
   fetched schemas (tier 2) enter the context window. The full 263 KB
   payload is never injected wholesale.

## Implications for the Maximalist Demonstration

- At 780 tools: 263 KB response is handled without issues. Tool names
  in the deferred list cost minimal tokens.
- At 3,600 tools: 1.2 MB response. MCP transport handles it (60ms
  latency). The deferred tool name list grows but remains manageable
  since it contains only names, not full schemas.
- The bottleneck is NOT the MCP protocol (which handles thousands of
  tools fine) but the LLM context if tools were eagerly injected.
  Claude Code's two-tier architecture prevents this.
- The original thesis ("naive enumerate-all saturates context") is
  correct for a naive client but Claude Code is not naive -- it uses
  deferred tool loading.

## Confounds Resolved

- **"MCP SDK may paginate"**: No. The SDK supports pagination but this
  server does not implement it, and the client does not request it.
- **"Two-tier indexing"**: Confirmed. Claude Code uses exactly this
  pattern: full cache locally, names-only in system prompt, schemas
  on demand via `ToolSearch`.
- **"Network latency masks differences"**: Addressed by measuring
  local stdio transport, eliminating network as a variable.
