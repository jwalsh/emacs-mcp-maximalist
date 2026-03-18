"""Tests for src/server.py — manifest loading and tool registration.

Tests the JSONL loader and tool builder. Does not start the actual
MCP server (that requires an event loop and stdio transport).
"""

import json
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from server import load_manifest_jsonl, build_tools, create_server


class TestLoadManifestJsonl:
    """load_manifest_jsonl reads compact JSONL and expands keys."""

    def _write_jsonl(self, records: list[dict]) -> Path:
        """Write records to a temporary JSONL file and return its path."""
        tmp = tempfile.NamedTemporaryFile(
            mode="w", suffix=".jsonl", delete=False
        )
        for record in records:
            tmp.write(json.dumps(record) + "\n")
        tmp.close()
        return Path(tmp.name)

    def test_single_record(self):
        path = self._write_jsonl([
            {"n": "string-trim", "s": "(STRING &optional TRIM-LEFT TRIM-RIGHT)", "d": "Trim STRING of leading string."}
        ])
        result = load_manifest_jsonl(path)
        assert len(result) == 1
        assert result[0]["name"] == "string-trim"
        assert result[0]["arglist"] == "(STRING &optional TRIM-LEFT TRIM-RIGHT)"
        assert result[0]["docstring"] == "Trim STRING of leading string."

    def test_multiple_records(self):
        path = self._write_jsonl([
            {"n": "string-trim", "s": "(STRING)", "d": "Trim."},
            {"n": "buffer-name", "s": "(BUFFER)", "d": "Return name."},
            {"n": "format", "s": "(STRING &rest OBJECTS)", "d": "Format string."},
        ])
        result = load_manifest_jsonl(path)
        assert len(result) == 3
        names = [r["name"] for r in result]
        assert names == ["string-trim", "buffer-name", "format"]

    def test_empty_file(self):
        path = self._write_jsonl([])
        result = load_manifest_jsonl(path)
        assert result == []

    def test_blank_lines_skipped(self):
        tmp = tempfile.NamedTemporaryFile(
            mode="w", suffix=".jsonl", delete=False
        )
        tmp.write('{"n": "a", "s": "", "d": "A."}\n')
        tmp.write("\n")
        tmp.write('{"n": "b", "s": "", "d": "B."}\n')
        tmp.write("   \n")
        tmp.close()
        result = load_manifest_jsonl(Path(tmp.name))
        assert len(result) == 2

    def test_missing_optional_keys_default(self):
        """s and d should default to empty string if absent."""
        path = self._write_jsonl([{"n": "some-func"}])
        result = load_manifest_jsonl(path)
        assert result[0]["arglist"] == ""
        assert result[0]["docstring"] == ""

    def test_invalid_json_raises(self):
        tmp = tempfile.NamedTemporaryFile(
            mode="w", suffix=".jsonl", delete=False
        )
        tmp.write("not valid json\n")
        tmp.close()
        with pytest.raises(json.JSONDecodeError):
            load_manifest_jsonl(Path(tmp.name))


class TestBuildTools:
    """build_tools converts expanded manifest dicts to MCP Tool objects."""

    def test_single_tool(self):
        functions = [
            {"name": "string-trim", "arglist": "(STRING)", "docstring": "Trim."}
        ]
        tools = build_tools(functions)
        assert len(tools) == 1
        assert tools[0].name == "string-trim"
        assert tools[0].description == "Trim."
        assert tools[0].inputSchema["properties"]["args"]["description"] == "(STRING)"

    def test_empty_list(self):
        tools = build_tools([])
        assert tools == []

    def test_tool_schema_structure(self):
        functions = [
            {"name": "buffer-string", "arglist": "()", "docstring": "Get buffer."}
        ]
        tools = build_tools(functions)
        schema = tools[0].inputSchema
        assert schema["type"] == "object"
        assert "args" in schema["properties"]
        assert schema["properties"]["args"]["type"] == "array"
        assert schema["required"] == ["args"]

    def test_many_tools(self):
        functions = [
            {"name": f"fn-{i}", "arglist": "(X)", "docstring": f"Doc {i}."}
            for i in range(100)
        ]
        tools = build_tools(functions)
        assert len(tools) == 100


class TestCreateServer:
    """create_server wires up manifest loading and tool registration."""

    def _write_jsonl(self, records: list[dict]) -> Path:
        tmp = tempfile.NamedTemporaryFile(
            mode="w", suffix=".jsonl", delete=False
        )
        for record in records:
            tmp.write(json.dumps(record) + "\n")
        tmp.close()
        return Path(tmp.name)

    def test_returns_server_and_count(self):
        path = self._write_jsonl([
            {"n": "string-trim", "s": "(STRING)", "d": "Trim."},
            {"n": "buffer-name", "s": "(BUFFER)", "d": "Name."},
        ])
        app, count = create_server(path)
        assert count == 2
        # app should be an mcp Server instance
        assert app.name == "emacs-mcp-maximalist"

    def test_empty_manifest(self):
        path = self._write_jsonl([])
        app, count = create_server(path)
        assert count == 0
