# C-004: Non-ASCII Round-Trip Integrity

**Note**: This research doc references the historical Python stack
(escape_for_elisp, test_escape.py, dispatch.eval_in_emacs) which has
been removed. The conjecture result (Confirmed) remains valid. The pure
Elisp server uses `json-parse-string` / `json-serialize` for the round
trip, with `decode-coding-string` ensuring correct UTF-8 output.

## Conjecture

Non-ASCII input survives the escape -> emacsclient -> Emacs -> stdout
round trip without corruption.

## Background

The pipeline is: Python string -> `escape_for_elisp()` -> shell
argument to `emacsclient --eval` -> Emacs Lisp evaluation -> stdout
capture -> Python string. Each boundary is a potential corruption
point for non-ASCII data (CJK, emoji, combining characters, RTL).

## Falsification Criteria

The conjecture is falsified if any of the following test strings
emerge from the round trip altered:

- CJK: `"\u4f60\u597d\u4e16\u754c"` (Chinese: hello world)
- Emoji: `"\U0001f600\U0001f4a9"` (grinning face, pile of poo)
- Combining: `"e\u0301"` (e + combining acute accent)
- RTL: `"\u0645\u0631\u062d\u0628\u0627"` (Arabic: marhaba)
- Mixed: `"caf\u00e9 \U0001f37a \u00fc\u00f1\u00ee\u00e7\u00f6\u00f0\u00e9"`

## Measurement Approach

1. **Unit test (escape layer only)**: already covered in
   `test_escape.py` -- CJK, emoji, and combining characters pass
   through `escape_for_elisp` unchanged. These tests PASS.

2. **Integration test (full round trip)**: requires live Emacs daemon.

```bash
# Test: identity function on non-ASCII string
INPUT='你好世界'
RESULT=$(emacsclient --eval "(identity \"$INPUT\")")
echo "input:  $INPUT"
echo "result: $RESULT"
[[ "$RESULT" == "\"$INPUT\"" ]] && echo "PASS" || echo "FAIL"
```

3. **Python-to-Python round trip**: use `dispatch.eval_in_emacs` with
   `build_call` to exercise the full Python -> Emacs -> Python path.

```python
from escape import build_call
from dispatch import eval_in_emacs

test_cases = [
    ("CJK",       "你好世界"),
    ("emoji",     "\U0001f600\U0001f4a9"),
    ("combining", "e\u0301"),
    ("RTL",       "مرحبا"),
    ("mixed",     "cafe\u0301 \U0001f37a"),
]

for label, text in test_cases:
    sexp = build_call("identity", text)
    result = eval_in_emacs(sexp)
    # Emacs returns quoted string: strip outer quotes
    result = result.strip('"')
    status = "PASS" if result == text else "FAIL"
    print(f"{label}: {status} (got {result!r})")
```

## Confounds

- **Locale settings**: `emacsclient` inherits the shell's locale.
  If `LANG` is not set to a UTF-8 locale, encoding may be wrong at
  the process boundary, not in Emacs itself.
- **Terminal encoding**: if testing from a terminal, the terminal's
  encoding affects copy-paste but not programmatic tests.
- **Emacs `coding-system`**: Emacs may re-encode output. The default
  `utf-8` should be correct, but non-default configs could break this.
  The project's anti-goal of requiring vanilla Emacs mitigates this.
- **Combining characters**: Emacs may normalize `e\u0301` to `\u00e9`
  (NFC normalization). This is a semantic preservation but a byte-level
  change. Need to define whether normalization counts as "corruption."
- **Shell escaping**: the `build_call` -> `subprocess.run` boundary
  passes the sexp as a single argument (not through shell expansion),
  so shell metacharacters in the input should not cause issues.

## Existing Test Coverage

`test_escape.py` covers:
- `test_non_ascii_passthrough_cjk`: PASS
- `test_non_ascii_passthrough_emoji`: PASS
- `test_non_ascii_passthrough_combining`: PASS

These test the escape layer only. The integration layer (through
emacsclient) is untested.

## Status

**Partially verified.** Escape layer passes. Full round-trip test
requires live Emacs daemon. Combining character normalization behavior
is the primary open question.
