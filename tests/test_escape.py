"""Tests for src/escape.py — the security surface."""

import sys
from pathlib import Path

import pytest

# Add src to path so we can import escape
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from escape import escape_for_elisp, build_call


class TestEscapeForElisp:
    """escape_for_elisp must produce safe Elisp string literal content."""

    def test_backslash_escaping(self):
        assert escape_for_elisp("a\\b") == "a\\\\b"

    def test_double_backslash(self):
        assert escape_for_elisp("\\\\") == "\\\\\\\\"

    def test_double_quote_escaping(self):
        assert escape_for_elisp('say "hello"') == 'say \\"hello\\"'

    def test_null_byte_rejected(self):
        with pytest.raises(ValueError, match="null byte"):
            escape_for_elisp("before\x00after")

    def test_null_byte_alone(self):
        with pytest.raises(ValueError, match="null byte"):
            escape_for_elisp("\x00")

    def test_newline_escaping(self):
        assert escape_for_elisp("line1\nline2") == "line1\\nline2"

    def test_carriage_return_escaping(self):
        assert escape_for_elisp("a\rb") == "a\\rb"

    def test_crlf_escaping(self):
        assert escape_for_elisp("a\r\nb") == "a\\r\\nb"

    def test_non_ascii_passthrough_cjk(self):
        result = escape_for_elisp("hello")
        assert result == "hello"

    def test_non_ascii_passthrough_emoji(self):
        result = escape_for_elisp("test rocket ship")
        assert result == "test rocket ship"

    def test_non_ascii_passthrough_combining(self):
        combining = "e\u0301"  # e + combining acute accent
        assert escape_for_elisp(combining) == combining

    def test_empty_string(self):
        assert escape_for_elisp("") == ""

    def test_plain_ascii(self):
        assert escape_for_elisp("hello world") == "hello world"

    def test_shell_metacharacters(self):
        """Shell metacharacters pass through — escaper targets Elisp, not shell."""
        dangerous = "$(rm -rf /); `evil`; | & > < ; ' !"
        result = escape_for_elisp(dangerous)
        # Backslash-containing chars not present, so only quotes matter
        assert result == dangerous

    def test_shell_metacharacters_with_quotes(self):
        result = escape_for_elisp('"; (delete-file "/")')
        assert result == '\\"; (delete-file \\"/\\")'

    def test_parentheses_passthrough(self):
        """Parens pass through — they are inside a quoted string in Elisp."""
        assert escape_for_elisp("(+ 1 1)") == "(+ 1 1)"

    def test_mixed_escaping(self):
        result = escape_for_elisp('line1\nwith "quotes"\\ and \\more')
        assert result == 'line1\\nwith \\"quotes\\"\\\\ and \\\\more'


class TestBuildCall:
    """build_call constructs a complete s-expression for emacsclient --eval."""

    def test_single_arg(self):
        result = build_call("string-trim", " hello ")
        assert result == '(string-trim " hello ")'

    def test_multiple_args(self):
        result = build_call("replace-regexp-in-string", "foo", "bar", "foobaz")
        assert result == '(replace-regexp-in-string "foo" "bar" "foobaz")'

    def test_no_args(self):
        result = build_call("buffer-name")
        assert result == "(buffer-name )"

    def test_arg_with_special_chars(self):
        result = build_call("message", 'He said "hi"\nand left')
        assert result == '(message "He said \\"hi\\"\\nand left")'

    def test_empty_string_arg(self):
        result = build_call("string-trim", "")
        assert result == '(string-trim "")'

    def test_non_ascii_arg(self):
        result = build_call("message", "hello")
        assert result == '(message "hello")'
