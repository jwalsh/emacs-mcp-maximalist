"""server.py — MCP server over stdio.

Loads a compact JSONL manifest (one {"n","s","d"} per line) and registers
each function as an MCP tool. Two entry points: core (filtered) and
maximalist (full manifest).
"""

import asyncio
import json
import sys
from pathlib import Path

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent

from escape import build_call
from dispatch import eval_in_emacs, EmacsClientError


# -- Manifest loading (JSONL, compact keys) ----------------------------------

def load_manifest_jsonl(path: Path) -> list[dict]:
    """Load compact JSONL manifest. Each line: {"n": name, "s": sig, "d": doc}.

    Returns list of dicts with full key names: name, arglist, docstring.
    """
    functions = []
    with path.open() as fh:
        for line_number, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            functions.append({
                "name": record["n"],
                "arglist": record.get("s", ""),
                "docstring": record.get("d", ""),
            })
    return functions


# -- Tool registration -------------------------------------------------------

def build_tools(functions: list[dict]) -> list[Tool]:
    """Convert manifest entries to MCP Tool objects."""
    tools = []
    for fn in functions:
        tool = Tool(
            name=fn["name"],
            description=fn["docstring"],
            inputSchema={
                "type": "object",
                "properties": {
                    "args": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": fn["arglist"],
                    }
                },
                "required": ["args"],
            },
        )
        tools.append(tool)
    return tools


# -- Server construction -----------------------------------------------------

def create_server(manifest_path: Path) -> tuple[Server, int]:
    """Create and configure an MCP server from a JSONL manifest.

    Returns (server, tool_count).
    """
    functions = load_manifest_jsonl(manifest_path)
    tools = build_tools(functions)
    tool_count = len(tools)

    app = Server("emacs-mcp-maximalist")

    @app.list_tools()
    async def list_tools():
        return tools

    @app.call_tool()
    async def call_tool(name: str, arguments: dict) -> list[TextContent]:
        args = arguments.get("args", [])
        sexp = build_call(name, *args)
        try:
            result = eval_in_emacs(sexp)
            return [TextContent(type="text", text=result)]
        except EmacsClientError as exc:
            return [TextContent(type="text", text=f"error: {exc}")]

    return app, tool_count


# -- Entry points ------------------------------------------------------------

async def run_server(manifest_path: str) -> None:
    """Start the MCP server over stdio."""
    path = Path(manifest_path)
    app, count = create_server(path)
    print(f"emacs-mcp-maximalist: {count} tools loaded", file=sys.stderr)

    async with stdio_server() as (read_stream, write_stream):
        init_options = app.create_initialization_options()
        await app.run(read_stream, write_stream, init_options)


def main_core() -> None:
    """Entry point: core mode (~50 tools, filtered manifest)."""
    manifest = "functions-core.jsonl"
    asyncio.run(run_server(manifest))


def main_maximalist() -> None:
    """Entry point: maximalist mode (full manifest, ~3600+ tools)."""
    manifest = "functions-compact.jsonl"
    asyncio.run(run_server(manifest))


if __name__ == "__main__":
    manifest = sys.argv[1] if len(sys.argv) > 1 else "functions-compact.jsonl"
    asyncio.run(run_server(manifest))
