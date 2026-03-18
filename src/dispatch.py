"""dispatch.py — emacsclient subprocess boundary."""

import os
import subprocess
import sys
import time


# Conjecture instrumentation: C-003 (latency), C-004 (non-ASCII round trip)
EMCP_TRACE = os.environ.get("EMCP_TRACE", "0") == "1"


class EmacsClientError(RuntimeError):
    pass


def eval_in_emacs(sexp: str, timeout: int = 10) -> str:
    """Evaluate SEXP via emacsclient and return result as string.

    Raises EmacsClientError on non-zero exit or timeout.

    When EMCP_TRACE=1, logs round-trip latency to stderr (C-003).
    """
    start_ns = time.monotonic_ns() if EMCP_TRACE else 0
    try:
        result = subprocess.run(
            ["emacsclient", "--eval", sexp],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError:
        raise EmacsClientError("emacsclient not found on PATH")
    except subprocess.TimeoutExpired:
        raise EmacsClientError(f"emacsclient timed out after {timeout}s")

    if result.returncode != 0:
        raise EmacsClientError(
            f"emacsclient exit {result.returncode}: {result.stderr.strip()}"
        )

    # emacsclient may prefix stdout with diagnostic messages when using
    # TCP connections (e.g., "emacsclient: connected to remote socket at ...").
    # Strip any lines starting with "emacsclient:" from the output.
    raw_output = result.stdout.strip()
    lines = raw_output.split("\n")
    lines = [l for l in lines if not l.startswith("emacsclient:")]
    output = "\n".join(lines)
    if EMCP_TRACE:
        elapsed_ms = (time.monotonic_ns() - start_ns) / 1_000_000
        sexp_preview = sexp[:60] + ("..." if len(sexp) > 60 else "")
        print(f"TRACE dispatch {elapsed_ms:.1f}ms: {sexp_preview}",
              file=sys.stderr)
    return output
