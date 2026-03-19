# Elisp Manual: Coding System Basics

**Source**: https://www.gnu.org/software/emacs/manual/html_node/elisp/Coding-System-Basics.html
**Section**: 34.10.1 Basic Concepts of Coding Systems
**Fetched**: 2026-03-18

## Full Text

*Character code conversion* involves conversion between the internal
representation of characters used inside Emacs and some other encoding.
Emacs supports many different encodings: Latin 1-5, various ISO 2022
variants, Cyrillic (ISO, Alternativnyj, KOI8), and many more.

### The `undecided` Coding System

Every coding system specifies a particular set of character code
conversions, but the coding system `undecided` is special: it leaves the
choice unspecified, to be chosen heuristically for each file or string,
based on the data. The coding system `prefer-utf-8` is like `undecided`,
but it prefers to choose `utf-8` when possible.

### Round-trip Safety

In general, a coding system doesn't guarantee roundtrip identity:
decoding a byte sequence, then re-encoding with the same coding system,
can produce a different byte sequence. But some coding systems do
guarantee round-trip fidelity:

> iso-8859-1, utf-8, big5, shift_jis, euc-jp

Encoding buffer text and then decoding can also fail if you encode a
character with a coding system that doesn't support it -- the result is
unpredictable. Currently, Emacs can't report errors from encoding
unsupported characters.

### End of Line Conventions

| Convention | Systems | Character(s) |
|------------|---------|-------------|
| Unix | GNU, Unix, macOS | LF (linefeed/newline) |
| DOS | MS-Windows, MS-DOS | CR+LF |
| Mac | Classic Mac OS (legacy) | CR only |

**Base coding systems** (e.g., `latin-1`) leave end-of-line conversion
unspecified. **Variant coding systems** (e.g., `latin-1-unix`,
`latin-1-dos`, `latin-1-mac`) specify it explicitly.

### Special Coding Systems

| Coding System | Behavior |
|--------------|----------|
| `raw-text` | No character code conversion; buffer becomes unibyte. Does convert eight-bit chars to single-byte external form for multibyte text. EOL determined by data. |
| `no-conversion` / `binary` | Equivalent to `raw-text-unix`: no conversion of codes or EOL. |
| `utf-8-emacs` | Internal Emacs encoding. Like `raw-text` but result is multibyte. |
| `emacs-internal` | Alias for `utf-8-emacs-unix` (forces Unix EOL). |

**Recommendation**: Use `utf-8-emacs` when saving text for internal
purposes such as caching.

### Function: `coding-system-get` coding-system property

Returns the specified property. The `:mime-charset` property's value is
the MIME name for the character coding:

```elisp
(coding-system-get 'iso-latin-1 :mime-charset)
     => iso-8859-1
(coding-system-get 'iso-2022-cn :mime-charset)
     => iso-2022-cn
(coding-system-get 'cyrillic-koi8 :mime-charset)
     => koi8-r
```

### Function: `coding-system-aliases` coding-system

Returns the list of aliases of *coding-system*.

---

## Relevance to emacs-mcp-maximalist

### UTF-8 throughout the pipeline

The MCP protocol uses JSON, which is UTF-8. The project must ensure
clean UTF-8 handling at every boundary.

### Key coding system interactions

1. **Batch mode stdout encoding**: In batch mode, output encoding
   defaults to `locale-coding-system`. For reliable JSON-RPC, bind
   `coding-system-for-write` to `'utf-8`:
   ```elisp
   (let ((coding-system-for-write 'utf-8))
     (princ (json-serialize response)))
   ```

2. **`call-process` output decoding**: Output from `emacsclient` is
   decoded using a coding system. Bind `coding-system-for-read` to
   `'utf-8` before `call-process`:
   ```elisp
   (let ((coding-system-for-read 'utf-8))
     (call-process "emacsclient" nil t nil "--eval" expr))
   ```

3. **`json-serialize` returns unibyte**: The result is a unibyte string
   already encoded in UTF-8. Writing it to stdout with
   `coding-system-for-write` set to `'utf-8` should be a no-op (no
   re-encoding), but setting it explicitly prevents the `undecided`
   heuristic from choosing something else.

4. **`undecided` is dangerous**: If `coding-system-for-read` is left as
   `undecided`, Emacs may guess wrong when reading `emacsclient` output
   that contains non-ASCII. Always be explicit.

### Non-ASCII round-trip (C-004)

Conjecture C-004 claims non-ASCII input survives the escape ->
emacsclient -> Emacs -> stdout round trip. The coding system at each
boundary is the main risk:

- **caller -> emacsclient stdin**: UTF-8 by default
- **emacsclient -> daemon socket**: Uses Emacs's internal encoding
- **daemon eval -> result**: Result is a Lisp string in internal encoding
- **emacsclient -> stdout**: Printed representation, encoding depends on
  emacsclient's locale
- **stdout -> batch-mode read**: Decoded by `coding-system-for-read`

Each of these boundaries must use UTF-8 consistently. The `raw-text`
and `no-conversion` coding systems are inappropriate here because they
lose multibyte character information.

### Gotchas

- `prefer-utf-8` is safer than `undecided` as a default but still
  heuristic. Explicit `utf-8` is always better for a protocol boundary.
- The `utf-8-emacs` coding system preserves all Emacs-internal
  characters but is NOT standard UTF-8 -- it can encode characters that
  are not valid Unicode. Do not use it for external protocol boundaries.
- Round-trip failure is silent: Emacs won't report encoding errors for
  unsupported characters. This could cause silent data corruption in
  tool results containing unusual characters.
