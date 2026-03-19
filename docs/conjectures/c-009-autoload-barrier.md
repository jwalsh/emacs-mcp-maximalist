# C-009: Autoload Barrier in Batch Mode

## Problem Statement

In `src/emcp-stdio.el`, the text-consumer heuristic
(`emcp-stdio--text-consumer-p`) calls `(help-function-arglist sym t)` to
decide whether a function consumes text. For autoloaded functions that
have not yet been loaded, `help-function-arglist` returns the string
`"[Arg list not available until function definition is loaded.]"` instead
of a proper argument list. The heuristic's regexp never matches this
string, so autoloaded text-consumers are silently dropped.

Measurement (2026-03-18): 222 text-consumer functions are hidden in
batch mode. Resolving this would yield a 28.8% increase in exposed tool
count.

The problem is structural: `emacs --batch -Q` loads only the bare
runtime. Most of Emacs's shipped libraries register autoload stubs via
`loaddefs.el`, but the actual function definitions (and therefore their
arglists) remain on disk in `.el` or `.elc` files until something
triggers the autoload.

## Conjecture A: Selective autoload-do-load on matching symbols

**Claim**: Calling `(autoload-do-load (symbol-function sym))` for each
autoloaded symbol whose name matches the text-consumer naming pattern
(e.g., names containing "string", "buffer", "text") will force-load
exactly the definitions needed, making their arglists available to
`help-function-arglist`, without loading the entire Emacs library tree.

**Mechanism**: The function `autoload-do-load` is a built-in that loads
the file named in the autoload object and replaces the autoload stub
with the real definition. By pre-filtering on symbol name (a cheap
string match on `(symbol-name sym)` before calling `autoload-do-load`),
the introspector can selectively load only libraries that are likely to
contain text-consuming functions. After loading, `help-function-arglist`
returns a proper list.

**Test**:
```
emacs --batch -Q -eval '
  (progn
    (require (quote help-fns))
    (let ((before 0) (after 0) (loaded 0))
      (mapatoms
       (lambda (sym)
         (when (and (fboundp sym)
                    (autoloadp (symbol-function sym))
                    (string-match-p "string\\|buffer\\|text"
                                    (symbol-name sym)))
           (cl-incf before)
           (condition-case nil
               (progn
                 (autoload-do-load (symbol-function sym))
                 (cl-incf loaded)
                 (let ((al (help-function-arglist sym t)))
                   (when (listp al) (cl-incf after))))
             (error nil)))))
      (message "Candidates: %d, loaded: %d, got arglist: %d"
               before loaded after)))'
```

**Risk**: Loading autoloaded files has side effects. Some files execute
top-level forms (`defvar`, `define-minor-mode`, mode hooks) that alter
global state. In batch mode this may trigger errors for files that expect
a display, active frame, or running event loop. The loading cost may also
be non-trivial: each `autoload-do-load` is a file read + byte-compile
(or `.elc` load), and if the target file itself `require`s other
libraries, transitive loading could snowball. Worst case: loading one
autoload pulls in a chain that loads hundreds of files and tens of
thousands of additional symbols, changing the obarray population and
invalidating the tool count.

## Conjecture B: Parse autoload objects for embedded arglist data

**Claim**: Emacs autoload objects (the 5-element vectors stored as
`symbol-function` for autoloaded symbols) contain an optional arglist in
position 3 (the "docstring or arglist" slot), and this arglist can be
extracted without loading the defining file.

**Mechanism**: An autoload object has the form
`(autoload FILE DOCSTRING INTERACTIVE TYPE)`. In practice, Emacs 28+
stores the arglist in the function's symbol plist under the
`advertised-calling-convention` property, or embeds it in the autoload
cookie metadata. If the arglist is present in the autoload object or
plist, `emcp-stdio--text-consumer-p` can extract it directly, bypassing
`help-function-arglist` entirely. The key question is how many autoload
objects actually carry this data in vanilla Emacs.

**Test**:
```
emacs --batch -Q -eval '
  (progn
    (let ((total 0) (has-arglist 0))
      (mapatoms
       (lambda (sym)
         (when (and (fboundp sym) (autoloadp (symbol-function sym)))
           (cl-incf total)
           (let* ((obj (symbol-function sym))
                  ;; autoload objects: (autoload FILE DOC INTERACTIVE TYPE)
                  ;; Check plist for advertised-calling-convention
                  (adv (get sym (quote advertised-calling-convention)))
                  ;; Check if nth 3 of autoload has useful data
                  (slot3 (and (listp obj) (nth 3 obj))))
             (when (or adv (and slot3 (listp slot3)))
               (cl-incf has-arglist))))))
      (message "Total autoloads: %d, with embedded arglist: %d"
               total has-arglist)))'
```

**Risk**: The autoload object format is not part of Emacs's public API.
The internal layout has changed across major versions (it was a vector
before Emacs 28, became a record/list in later versions). If the arglist
data is rarely present in autoload stubs -- which is likely, since the
autoload cookie `;;;###autoload` does not typically include argument
metadata -- this approach recovers zero or near-zero additional
functions, making it a dead end. The conjecture is falsified if fewer
than 10% of autoloaded symbols carry extractable arglist data.

## Conjecture C: Parse .elc bytecode headers for arglists without full loading

**Claim**: Compiled Emacs Lisp files (`.elc`) store function arglists in
their bytecode headers (the `byte-code` object's arglist slot), and
these can be read by partially parsing the `.elc` file without executing
it -- specifically, by reading just enough of the file to extract
`(defun NAME ARGLIST ...)` forms.

**Mechanism**: Use `symbol-file` to locate the source file for each
autoloaded symbol, derive the `.elc` path, then use
`(with-temp-buffer (insert-file-contents elc-path) ...)` to read the
file as data. A `read` call on the buffer will return the top-level
forms. Scan for `(defun SYM ...)` or `(byte-code ...)` objects whose
first element is the arglist. This avoids `load` (which evaluates
top-level forms) and instead treats the file as structured data.

**Test**:
```
emacs --batch -Q -eval '
  (progn
    (let ((sym (quote string-trim)))
      ;; Find the source file
      (let* ((file (symbol-file sym (quote defun)))
             (elc  (concat (file-name-sans-extension file) ".elc")))
        (message "Source: %s" file)
        (message ".elc exists: %s" (file-exists-p elc))
        (when (file-exists-p elc)
          (with-temp-buffer
            (insert-file-contents elc)
            ;; Try to read forms until we find defun for sym
            (goto-char (point-min))
            ;; Skip the bytecode header (first line is ;ELC...)
            (forward-line 1)
            (let ((found nil))
              (condition-case nil
                  (while (not found)
                    (let ((form (read (current-buffer))))
                      (when (and (listp form)
                                 (memq (car form) (quote (defun defalias)))
                                 (eq (cadr form) sym))
                        (setq found form)
                        (message "Arglist: %S" (nth 2 form)))))
                (end-of-file nil))
              (unless found
                (message "Not found via read")))))))'
```

**Risk**: `.elc` files are not designed for partial parsing. The byte
compiler may emit forms in an order that differs from the source. Some
`.elc` files use `eval-when-compile` wrappers or `defalias` with
byte-code objects rather than `defun`, making the arglist extraction
heuristic fragile. Additionally, `read`-ing a `.elc` file still
evaluates reader macros and could fail on malformed bytecode. Most
critically, `symbol-file` may return nil for autoloaded symbols that have
not been loaded (since `symbol-file` consults `load-history`, which is
only populated after loading). This creates a circular dependency: you
need to load the file to find the file.

## Conjecture D: Bulk-load loaddefs.el to populate arglists in one shot

**Claim**: Loading the generated `loaddefs.el` file (or its compiled
form `loaddefs.elc`) in batch mode will resolve all standard autoload
stubs at once, making their arglists available, with a bounded and
predictable cost -- essentially replaying what a normal Emacs startup
does.

**Mechanism**: During normal (non-`-Q`) startup, Emacs loads
`loaddefs.el` to register autoload stubs. But the stubs themselves do
not contain arglists. The real question is whether a second-stage bulk
load is feasible: iterate `load-history` to find every file registered
by `loaddefs.el`, then `load` each one. Alternatively, instead of
loading `loaddefs.el`, load specific feature groups known to define
text-consumer functions: `(require 'subr-x)`, `(require 'seq)`,
`(require 'cl-lib)`, `(require 'url)`, etc. This is a controlled
middle ground between `-Q` (nothing loaded) and full init (everything
loaded).

**Test**:
```
emacs --batch -Q -eval '
  (progn
    (require (quote help-fns))
    ;; Count text consumers before
    (let ((before 0))
      (mapatoms
       (lambda (sym)
         (when (and (fboundp sym)
                    (let ((al (format "%s" (help-function-arglist sym t))))
                      (string-match-p "string\\|buffer\\|text\\|object\\|sequence" al)))
           (cl-incf before))))
      (message "Before: %d" before))
    ;; Load a curated set of libraries
    (dolist (lib (quote (subr-x seq cl-lib url json pcase rx map)))
      (condition-case err (require lib) (error (message "Failed: %s: %s" lib err))))
    ;; Count again
    (let ((after 0))
      (mapatoms
       (lambda (sym)
         (when (and (fboundp sym)
                    (let ((al (format "%s" (help-function-arglist sym t))))
                      (string-match-p "string\\|buffer\\|text\\|object\\|sequence" al)))
           (cl-incf after))))
      (message "After: %d" after)))'
```

**Risk**: This approach partially violates the project's anti-goal of
config independence. If the set of `require`d libraries is hardcoded,
the tool list becomes a function of that curated set rather than a pure
introspection of the running Emacs. However, the libraries listed above
are all shipped with Emacs and available in `-Q` mode, so this is
arguably still "vanilla Emacs" -- just with more of its standard library
loaded. The deeper risk is that `require`-ing libraries changes the
obarray population (new symbols, new functions), so the tool count
increase may come from genuinely new functions rather than from resolving
autoload arglists. Measurement must distinguish between "functions whose
arglists were previously unavailable and are now available" vs.
"functions that did not exist in the obarray at all before loading."

## Conjecture E: Build a static arglist map from Emacs source at manifest time

**Claim**: The arglists of all autoloaded functions can be extracted
statically from the Emacs Lisp source tree (the `.el` files in
`load-path`) by grepping for `defun` forms, without loading any file
into a running Emacs. This map can be cached as a build artifact and
consulted by the introspector when `help-function-arglist` returns the
unavailable-arglist sentinel.

**Mechanism**: At manifest-build time (not server-start time), run a
batch process that:
1. Uses `mapatoms` to collect all symbols where `(autoloadp
   (symbol-function sym))` is true.
2. For each, extracts the filename from the autoload object via
   `(nth 1 (symbol-function sym))` -- the autoload object stores the
   source file name.
3. Reads that `.el` file with `insert-file-contents` (no `load`), then
   uses `read` to parse s-expressions until it finds
   `(defun SYM ARGLIST ...)`.
4. Writes a JSONL file mapping symbol names to arglists:
   `{"n":"string-trim","s":"(STRING &optional TRIM-LEFT TRIM-RIGHT)"}`.

The introspector or `emcp-stdio--text-consumer-p` then consults this
map as a fallback when `help-function-arglist` fails.

**Test**:
```
emacs --batch -Q -eval '
  (progn
    (let ((recovered 0) (failed 0))
      (mapatoms
       (lambda (sym)
         (when (and (fboundp sym) (autoloadp (symbol-function sym)))
           (let* ((obj (symbol-function sym))
                  (file (nth 1 obj))
                  (full (locate-library file)))
             (if (and full (file-exists-p full))
                 (condition-case nil
                     (with-temp-buffer
                       (insert-file-contents full)
                       (goto-char (point-min))
                       (let ((found nil))
                         (condition-case nil
                             (while (not found)
                               (let ((form (read (current-buffer))))
                                 (when (and (listp form)
                                            (eq (car form) (quote defun))
                                            (eq (cadr form) sym))
                                   (setq found (nth 2 form)))))
                           (end-of-file nil))
                         (if found (cl-incf recovered) (cl-incf failed))))
                   (error (cl-incf failed)))
               (cl-incf failed))))))
      (message "Recovered: %d, Failed: %d" recovered failed)))'
```

**Risk**: This approach introduces a two-phase build: first generate the
arglist map, then generate the manifest. The arglist map is a new build
artifact that must be kept in sync with the Emacs version. Using `read`
on arbitrary `.el` files can fail: some files use reader macros (#'),
conditional compilation (`eval-when-compile`), or `cl-defun` / `defsubst`
/ `define-derived-mode` forms that define functions without a plain
`defun`. The static parser would need to handle all these variants.
Furthermore, this approach shifts work from runtime to build time, which
is architecturally sound, but the static map could become stale if the
Emacs installation is updated without rebuilding the manifest. The
conjecture is falsified if fewer than 70% of autoloaded symbols have
their source file locatable via `(nth 1 (symbol-function sym))` combined
with `locate-library`.
