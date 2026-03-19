# Daemon Data Layer Contract

**Scope**: `src/emcp-stdio.el`, lines 102-301 -- the daemon data layer.

**Architecture**: The MCP server runs in Emacs batch mode. When a
separate Emacs daemon is reachable via `emacsclient`, the server
registers 9 additional "daemon tools" that expose live daemon state
(buffers, org files, variables). The batch process handles MCP protocol;
the daemon holds the data.

## Internal Functions

### `emcp-stdio--check-daemon`

**Purpose**: Probe whether an Emacs daemon is reachable.

**Inputs**: None.

**Outputs**: Non-nil if `emacsclient --eval "(emacs-pid)"` exits with
status 0; nil otherwise.

**Mechanism**: `(call-process "emacsclient" nil nil nil "--eval" "(emacs-pid)")`.
Output is discarded (destination `nil`). Only the exit code matters.

**Invariants**:
- Called once at startup, result cached in `emcp-stdio--daemon-available`.
- Does not raise errors on failure -- returns nil.
- Uses `call-process`, not `shell-command`, so no shell injection risk.

### `emcp-stdio--daemon-eval`

**Purpose**: Evaluate an s-expression string in the running daemon and
return the result as a string.

**Inputs**: `sexp-string` -- a string containing a valid Elisp
s-expression. Passed directly to `emacsclient --eval`.

**Outputs**: Result string from emacsclient, trimmed of whitespace, with
diagnostic lines (containing `"emacsclient:"`) filtered out.

**Mechanism**: `(call-process "emacsclient" nil t nil "--eval" sexp-string)`.
Output goes to current buffer (destination `t` inside `with-temp-buffer`).

**Error behavior**: If emacsclient exits non-zero, signals an Elisp error
with `(error "daemon-eval failed: %s" ...)`.

**Invariants**:
- Diagnostic line filtering matches the established pattern:
  lines containing `"emacsclient:"` are stripped.
- Result is `string-trim`'d -- leading/trailing whitespace removed.
- The sexp-string is NOT modified or escaped -- caller must provide
  valid Elisp.

### `emcp-stdio--daemon-build-sexp`

**Purpose**: Construct a valid Elisp s-expression string for a named
daemon tool given its arguments.

**Inputs**: `name` (tool name string), `args` (list of string arguments).

**Outputs**: A string containing a valid Elisp s-expression that can be
passed to `emcp-stdio--daemon-eval`.

**Mechanism**: `pcase` dispatch on `name`. Each branch constructs the
sexp using `concat` and `prin1-to-string` for safe quoting of user data.

**Invariants**:
- Every argument interpolated into the sexp goes through `prin1-to-string`
  (equivalent to `%S` in `format`) which handles escaping of quotes,
  backslashes, and special characters.
- The produced string must be parseable by `(read ...)`.
- Signals error for unknown tool names: `"No sexp builder for %s"`.

### `emcp-stdio--daemon-call`

**Purpose**: Dispatch a daemon tool call.

**Inputs**: `name` (tool name string), `args` (list of string arguments).

**Outputs**: Result string from `emcp-stdio--daemon-eval`.

**Mechanism**:
- Looks up tool definition in `emcp-stdio--daemon-tool-defs` via `assoc`.
- If handler type is `:raw`, passes `(car args)` directly to
  `emcp-stdio--daemon-eval` (no quoting applied).
- If handler type is `:build`, calls `emcp-stdio--daemon-build-sexp` to
  construct the sexp, then evaluates it.

**Invariants**:
- Signals error for unknown tool names: `"Unknown daemon tool: %s"`.
- For `:raw` tools, the caller is responsible for providing valid Elisp.

### `emcp-stdio--build-daemon-tools`

**Purpose**: Generate MCP tool definition alists for all daemon tools.

**Inputs**: None (reads from `emcp-stdio--daemon-tool-defs`).

**Outputs**: List of alists, each with `name`, `description`, and
`inputSchema` keys. The schema follows the same pattern as obarray tools:
a single `args` property of type `array` of `string`.

**Invariants**:
- Only called when `emcp-stdio--daemon-available` is non-nil.
- Tool count equals `(length emcp-stdio--daemon-tool-defs)` = 9.
- The `description` field in the schema is the arglist string from the
  tool definition (e.g., `"(sexp-string)"`), NOT the docstring.

## Daemon Tool Definitions

### Tool 1: `emcp-data-eval`

**Handler type**: `:raw`

**Arguments**: `(sexp-string)` -- 1 arg, a raw Elisp s-expression string.

**Behavior**: Passes `sexp-string` directly to `emcp-stdio--daemon-eval`.
No escaping, no quoting, no sexp construction. The caller provides
complete Elisp.

**Output**: The string result of evaluating the sexp in the daemon.

**Security note**: This is the raw query interface. It can evaluate
arbitrary Elisp in the daemon, including destructive operations. Same
trust level as `emacsclient --eval`.

**Error cases**:
- Invalid Elisp: emacsclient returns non-zero, `daemon-eval` signals error.
- Daemon not running: caught at dispatch level ("No daemon available").

### Tool 2: `emcp-data-buffer-list`

**Handler type**: `:build`

**Arguments**: `()` -- 0 args.

**Behavior**: Evaluates a sexp that maps over `(buffer-list)` and
produces one line per buffer: `name<TAB>filename`.

**Output format**: Newline-separated lines. Each line is
`buffer-name\tfilename` where filename is empty string if the buffer
has no file association.

**Sexp produced**:
```elisp
(mapconcat (lambda (b) (format "%s\t%s" (buffer-name b)
  (or (buffer-file-name b) ""))) (buffer-list) "\n")
```

**Error cases**:
- None specific -- buffer-list always succeeds in a running daemon.

### Tool 3: `emcp-data-buffer-read`

**Handler type**: `:build`

**Arguments**: `(buffer-name)` -- 1 arg.

**Behavior**: Returns the full text content of the named buffer.

**Output format**: Raw buffer text (no properties).

**Sexp produced**:
```elisp
(with-current-buffer BUFFER-NAME
  (buffer-substring-no-properties (point-min) (point-max)))
```

**Quoting**: `buffer-name` is interpolated via `%S` (format), so it is
safely quoted as an Elisp string literal.

**Error cases**:
- Buffer does not exist: Elisp error `"No buffer named ..."`, propagated
  through daemon-eval as an error string.

### Tool 4: `emcp-data-buffer-insert`

**Handler type**: `:build`

**Arguments**: `(buffer-name text)` -- 2 args.

**Behavior**: Inserts `text` at end of the named buffer. Does NOT call
`save-buffer`.

**Output format**: `"inserted N chars"` where N is `(length text)`.

**Sexp produced**:
```elisp
(with-current-buffer BUFFER-NAME
  (goto-char (point-max))
  (insert TEXT)
  (format "inserted %d chars" (length TEXT)))
```

**Quoting**: Both `buffer-name` and `text` go through `prin1-to-string`.

**Note on save**: Despite the invariant that "buffer tools that modify
state call save-buffer", the current implementation of `buffer-insert`
does NOT call `save-buffer`. This is a potential divergence from the
stated contract. The tool inserts text but leaves the buffer modified
(unsaved).

**Error cases**:
- Buffer does not exist: Elisp error propagated.
- Insufficient args: `(nth 1 args)` returns nil, `prin1-to-string` of
  nil produces `"nil"`, which inserts the literal string `"nil"`.

### Tool 5: `emcp-data-find-file`

**Handler type**: `:build`

**Arguments**: `(filename)` -- 1 arg.

**Behavior**: Opens the file in the daemon (via `find-file-noselect`)
and returns the buffer name.

**Output format**: Buffer name as a string.

**Sexp produced**:
```elisp
(buffer-name (find-file-noselect FILENAME))
```

**Quoting**: `filename` via `%S`.

**Error cases**:
- File does not exist: `find-file-noselect` creates a new buffer for it
  (Emacs behavior). Not an error.
- Permission denied: Elisp error propagated.

### Tool 6: `emcp-data-org-headings`

**Handler type**: `:build`

**Arguments**: `(filename)` -- 1 arg.

**Behavior**: Opens `filename`, loads org-mode, and extracts all headings
with level, TODO state, title, and tags.

**Output format**: Newline-separated lines. Each line is
`stars\tstate\ttitle\ttags` where:
- `stars` = asterisks matching heading level (e.g., `**`)
- `state` = TODO keyword or `"-"` if none
- `title` = heading text
- `tags` = tag string or empty

**Prerequisites**: `(require 'org)` is called in the sexp. If org is not
available in the daemon, the require fails and an error propagates.

**Quoting**: `filename` via `prin1-to-string`.

**Error cases**:
- File not found: `find-file-noselect` creates buffer (not an error
  per se, but no headings).
- Org not loaded and not loadable: require error propagated.

### Tool 7: `emcp-data-org-set-todo`

**Handler type**: `:build`

**Arguments**: `(filename heading new-state)` -- 3 args.

**Behavior**: Opens `filename`, searches for a heading matching
`heading` (via `re-search-forward` with `regexp-quote`), sets its TODO
state to `new-state`, and calls `save-buffer`.

**Output format**: `"set HEADING to NEW-STATE"`.

**Note**: The output format uses the literal argument values (not the
actual heading text found), because `heading` and `new-state` are
interpolated as `prin1-to-string` constants in the format string.

**Prerequisites**: `(require 'org)`.

**Saves**: Yes, calls `save-buffer`.

**Quoting**: All three args via `prin1-to-string`.

**Error cases**:
- Heading not found: `re-search-forward` signals `"Search failed"` error.
- Invalid TODO state: `org-todo` may silently accept it or error
  depending on `org-todo-keywords`.

### Tool 8: `emcp-data-org-table`

**Handler type**: `:build`

**Arguments**: `(filename table-name)` -- 2 args.

**Behavior**: Opens `filename`, searches for `table-name` (via
`search-forward`), advances one line, and extracts the org table at
point using `org-table-to-lisp`.

**Output format**: Newline-separated rows. Each row is tab-separated
cell values. Horizontal rules are rendered as `"---"`.

**Prerequisites**: `(require 'org)`.

**Quoting**: Both args via `prin1-to-string`.

**Error cases**:
- Table name not found: `search-forward` signals error.
- No table at point after name: `org-table-to-lisp` returns nil or
  unexpected data.

### Tool 9: `emcp-data-org-capture`

**Handler type**: `:build`

**Arguments**: `(file heading body)` -- 3 args.

**Behavior**: Opens `file`, searches for `heading`. If found, appends
a new `** body` entry at the end of that subtree. If not found, appends
a new `* heading` with `body` at end of file.

**Output format**: `"captured"` if inserted under existing heading,
`"captured at top level"` if heading was created.

**Prerequisites**: `(require 'org)`.

**Saves**: Yes, calls `save-buffer` in both branches.

**Quoting**: All three args via `prin1-to-string`.

**Error cases**:
- File permission denied: Elisp error propagated.

## Cross-Cutting Invariants

### 1. Daemon tools only registered when daemon is reachable

At startup, `emcp-stdio-start` calls `emcp-stdio--check-daemon`. If it
returns nil, `emcp-stdio--daemon-available` is nil, and
`emcp-stdio--build-daemon-tools` is not called. The `emcp-data-*` tools
do not appear in `tools/list`.

If a daemon tool is somehow called when no daemon is available, the
dispatch handler in `emcp-stdio--handle-tools-call` returns:
`"No daemon available for <name>"`.

### 2. Diagnostic line filtering

`emcp-stdio--daemon-eval` strips lines containing `"emacsclient:"` from
the output. This handles TCP socket warnings and other emacsclient
diagnostics that are not part of the eval result.

Pattern: `(string-match-p "emacsclient:" line)`.

This pattern filters emacsclient diagnostic output from eval results.

### 3. emcp-data-eval takes raw sexp -- no quoting applied

The `:raw` handler type means the first argument is passed verbatim to
`emacsclient --eval`. The caller is responsible for providing syntactically
valid Elisp. No escaping or wrapping occurs.

### 4. Other tools construct sexp via prin1-to-string -- args are auto-quoted

All `:build` tools use `prin1-to-string` (or `format %S`, which calls
the same printer) to interpolate user-supplied arguments into the sexp
string. This safely handles:
- Double quotes in argument values
- Backslashes
- Newlines (printed as `\n` inside the string literal)
- Non-ASCII characters (preserved as-is)

### 5. Org tools require 'org

Tools `emcp-data-org-headings`, `emcp-data-org-set-todo`,
`emcp-data-org-table`, and `emcp-data-org-capture` all include
`(require 'org)` in their generated sexp. If org-mode is not available
in the daemon (unlikely for a standard Emacs installation), the require
will signal an error.

### 6. Buffer tools that modify state and save

- `emcp-data-org-set-todo`: calls `save-buffer` after `org-todo`.
- `emcp-data-org-capture`: calls `save-buffer` after insert (both branches).
- `emcp-data-buffer-insert`: does NOT call `save-buffer`. The buffer is
  left in a modified state.

## Sexp Construction Audit

For each tool in `emcp-stdio--daemon-build-sexp`:

### emcp-data-buffer-list
- **Args expected**: 0
- **Args used**: none
- **Sexp validity**: Static string, always valid. Uses `prin1-to-string`
  for format specifiers and newline literal, avoiding embedded escape
  ambiguity.
- **Special char safety**: N/A (no user input interpolated).

### emcp-data-buffer-read
- **Args expected**: 1 (`buffer-name`)
- **Args used**: `(nth 0 args)` via `%S`
- **Sexp validity**: Valid. `%S` produces a quoted string literal.
- **Special char safety**: `%S` handles quotes, backslashes, newlines.
- **Edge case**: If args is empty, `(nth 0 args)` is nil, and
  `(format "... %S" nil)` produces `"... nil"` -- which is a valid sexp
  but will fail at runtime ("No buffer named nil").

### emcp-data-buffer-insert
- **Args expected**: 2 (`buffer-name`, `text`)
- **Args used**: `(nth 0 args)` and `(nth 1 args)` via `prin1-to-string`
- **Sexp validity**: Valid. Both args safely quoted.
- **Special char safety**: `prin1-to-string` handles all special chars.
- **Edge case**: Missing second arg produces `nil` insertion.
- **Note**: The sexp calls `(length TEXT)` with the `prin1-to-string`
  version of text, not the original. Since `prin1-to-string` wraps the
  string in quotes, the `length` call inside the sexp operates on the
  original string value (after Elisp reads the quoted literal), so the
  count is correct.

### emcp-data-find-file
- **Args expected**: 1 (`filename`)
- **Args used**: `(nth 0 args)` via `%S`
- **Sexp validity**: Valid.
- **Special char safety**: `%S` handles paths with spaces, quotes, etc.

### emcp-data-org-headings
- **Args expected**: 1 (`filename`)
- **Args used**: `(nth 0 args)` via `prin1-to-string`
- **Sexp validity**: Valid. Complex nested sexp but all string
  interpolation uses `prin1-to-string`.
- **Special char safety**: File path safely quoted.

### emcp-data-org-set-todo
- **Args expected**: 3 (`filename`, `heading`, `new-state`)
- **Args used**: All three via `prin1-to-string`
- **Sexp validity**: Valid.
- **Special char safety**: The `heading` arg is used inside
  `(regexp-quote ...)` in the sexp, so regex metacharacters in the
  heading are properly escaped at runtime. The `prin1-to-string` handles
  the Elisp string quoting layer.
- **Note**: The output format string uses the literal arg values (via
  `prin1-to-string` at sexp construction time), not dynamic values.
  This means the output says "set X to Y" with the original arguments,
  which is correct.

### emcp-data-org-table
- **Args expected**: 2 (`filename`, `table-name`)
- **Args used**: Both via `prin1-to-string`
- **Sexp validity**: Valid.
- **Special char safety**: Both args safely quoted.

### emcp-data-org-capture
- **Args expected**: 3 (`file`, `heading`, `body`)
- **Args used**: All three via `prin1-to-string`
- **Sexp validity**: Valid.
- **Special char safety**: All args safely quoted.
- **Note**: The heading search uses `(regexp-quote ...)` for safety.
  The body is inserted as-is (after Elisp string unquoting).

## Error Propagation Path

1. User calls `tools/call` with a daemon tool name.
2. `emcp-stdio--handle-tools-call` checks `emcp-stdio--daemon-available`.
   If nil, returns `"error: No daemon available for <name>"`.
3. `emcp-stdio--daemon-call` looks up the tool. If not found, signals
   `"Unknown daemon tool: <name>"`.
4. For `:raw`, passes arg to `emcp-stdio--daemon-eval`. For `:build`,
   calls `emcp-stdio--daemon-build-sexp` first.
5. `emcp-stdio--daemon-build-sexp` signals error for unknown names.
6. `emcp-stdio--daemon-eval` calls `emacsclient`. If exit code non-zero,
   signals `"daemon-eval failed: ..."`.
7. All errors are caught by the `condition-case` in
   `emcp-stdio--handle-tools-call` and returned as MCP content with
   `"error: ..."` prefix (NOT as JSON-RPC error responses -- they are
   returned as successful responses with error text in the content).
