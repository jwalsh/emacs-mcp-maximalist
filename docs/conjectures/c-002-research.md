# C-002: Arglist Heuristic Precision

## Conjecture

The arglist heuristic (string/buffer/object parameter names) yields
> 80% precision on "actually useful for text transformation."

## Background

`emcp--text-arg-p` in `introspect.el` filters `obarray` by checking
whether a function's arglist contains parameter names matching:
`string`, `str`, `text`, `buffer`, `object`, `obj`, `seq`, `sequence`.

This is a recall-oriented heuristic: it casts a wide net. The
conjecture asks about precision -- of the functions it includes, what
fraction are actually useful for text transformation?

## Falsification Criteria

The conjecture is falsified if a random audit of 50 functions from
the manifest shows fewer than 40 (80%) are genuinely useful for text
transformation tasks.

## Measurement Approach

1. **Random sample audit**: select 50 functions uniformly at random
   from `functions-compact.jsonl`. For each, classify as:
   - **Useful**: takes text input and produces meaningful text output
     or side-effect (e.g., `string-trim`, `replace-regexp-in-string`)
   - **Marginal**: takes text input but the function is primarily
     about something else (e.g., `buffer-file-name` takes a buffer
     object but returns metadata)
   - **Not useful**: false positive from the heuristic (e.g.,
     `object-write` where "object" means an Emacs object, not text)

2. **Category breakdown**: compare precision across the categories
   assigned by `emcp--classify` (string, buffer, file, org, regexp,
   format, misc). Hypothesis: "string" and "regexp" categories have
   higher precision than "misc".

3. **False positive analysis**: for each "not useful" result, identify
   which heuristic pattern triggered inclusion and whether a negative
   pattern could filter it.

## Confounds

- "Useful for text transformation" is subjective. Need a rubric:
  function must accept at least one string argument AND return a string
  or modify buffer text.
- The heuristic pattern `object` and `obj` likely produce the most
  false positives (many Emacs functions use "object" generically).
- A vanilla Emacs has fewer loaded packages than a configured one,
  potentially skewing the function population.

## Experiment Design

```bash
# Generate random sample
shuf -n 50 functions-compact.jsonl > /tmp/c002-sample.jsonl

# For each entry, look up full docs
while IFS= read -r line; do
  name=$(echo "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['n'])")
  echo "=== $name ==="
  emacsclient --eval "(describe-function '$name)" 2>/dev/null | head -5
  echo
done < /tmp/c002-sample.jsonl > /tmp/c002-audit.txt
```

Manual classification of the 50 entries then yields precision.

## Status

**Not yet measured.** Requires manifest generation first. Design is
ready; execution blocked on L2 (manifest build artifact).
