"""escape.py — safe Elisp string literal builder.

This module has no dependencies and no side effects.
"""


def escape_for_elisp(value: str) -> str:
    """Return VALUE escaped for embedding in an Elisp string literal.

    The output is suitable for: (function-name \\"<output>\\")
    where the outer double-quotes are supplied by the caller.

    Raises ValueError on null bytes (unrepresentable in Elisp strings).
    """
    if "\x00" in value:
        raise ValueError("null byte in string: not representable in Elisp")
    return (
        value
        .replace("\\", "\\\\")
        .replace('"',  '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
    )


def build_call(fn_name: str, *args: str) -> str:
    """Build an Elisp function call string for emacsclient --eval.

    Each arg is escaped and wrapped in double quotes.
    fn_name is not escaped — callers must supply known-safe names
    derived from the manifest (symbol names are alphanumeric + hyphen).
    """
    escaped = " ".join(f'"{escape_for_elisp(a)}"' for a in args)
    return f"({fn_name} {escaped})"
