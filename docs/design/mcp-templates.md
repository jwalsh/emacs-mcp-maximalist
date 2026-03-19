# MCP Resource Templates and Prompt Templates Design

**Date**: 2026-03-19
**Status**: Design (not implemented)
**Server**: `emacs-mcp-elisp` v0.1.0 (`src/emcp-stdio.el`)
**MCP Protocol Version**: 2024-11-05

## Motivation

The MCP protocol defines three capability types: **tools** (actions a
client can invoke), **resources** (data a client can read), and **prompts**
(templates a client can instantiate). Today `emcp-stdio.el` implements
only tools. Resources and prompts return `-32601 Method not found`.

Tools are imperative ("do this"). Resources are declarative ("give me
this data"). The distinction matters for agentic runtimes: a resource
read is side-effect-free and cacheable, while a tool call may mutate
state. Exposing Emacs's live state as resources lets agents query the
daemon without the overhead of constructing tool calls for pure reads.

Prompt templates give the server a way to offer pre-structured interaction
patterns. An agent connecting to the Emacs MCP server can discover what
kinds of queries the server is designed to answer.

### Design Constraint: The Foundational Axiom

The axiom states: "The MCP server does not know what Emacs can do. Emacs
tells it." For tools, this means the obarray drives the tool list.

Resources are different. They expose *data*, not *functions*. The URI
templates below are a fixed schema that the server advertises -- they
describe what kinds of data the daemon can provide. The Elisp
implementations behind those URIs still run in the daemon and use native
Emacs APIs. No function list is being curated; we are defining a query
interface to the daemon's live state.

Prompt templates are similarly structural -- they describe interaction
patterns, not function selections.

---

## Part 1: Resource Templates

### URI Scheme

All resources use the `emacs://` scheme. Template parameters are enclosed
in `{braces}` per RFC 6570 (URI Template) level 1.

---

### 1.1 Buffer Resources

#### `emacs://buffer/{name}`

Read the full text content of a named buffer.

| Attribute | Value |
|-----------|-------|
| Usefulness | **High** -- fundamental data access |
| Complexity | **Simple** |
| Requires daemon | Yes |
| MIME type | `text/plain` |

```elisp
;; Implementation sketch
(with-current-buffer NAME
  (buffer-substring-no-properties (point-min) (point-max)))
```

**Notes**: Buffer names containing `/` or special characters must be
percent-encoded in the URI. The server should decode before lookup.
Large buffers (>1MB) should be truncated with a note in the response
metadata.

---

#### `emacs://buffer/{name}/mode`

Return the major mode and active minor modes for a buffer.

| Attribute | Value |
|-----------|-------|
| Usefulness | **High** -- agents need mode context to choose actions |
| Complexity | **Simple** |
| Requires daemon | Yes |
| MIME type | `application/json` |

```elisp
(with-current-buffer NAME
  (json-encode
   `((major-mode . ,(symbol-name major-mode))
     (minor-modes . ,(vconcat
                      (mapcar #'symbol-name
                              (seq-filter
                               (lambda (m)
                                 (and (boundp m)
                                      (symbol-value m)))
                               minor-mode-list)))))))
```

---

#### `emacs://buffer/{name}/point`

Return cursor position, line number, column, and narrowing bounds.

| Attribute | Value |
|-----------|-------|
| Usefulness | **Medium** -- useful for context-aware edits |
| Complexity | **Simple** |
| Requires daemon | Yes |
| MIME type | `application/json` |

```elisp
(with-current-buffer NAME
  (json-encode
   `((point . ,(point))
     (line . ,(line-number-at-pos))
     (column . ,(current-column))
     (point-min . ,(point-min))
     (point-max . ,(point-max))
     (narrowed . ,(buffer-narrowed-p)))))
```

---

#### `emacs://buffer/{name}/region`

Return the selected region if the mark is active, or null.

| Attribute | Value |
|-----------|-------|
| Usefulness | **Medium** -- agents can act on user selections |
| Complexity | **Simple** |
| Requires daemon | Yes |
| MIME type | `application/json` |

```elisp
(with-current-buffer NAME
  (if (and (mark) (use-region-p))
      (json-encode
       `((text . ,(buffer-substring-no-properties (region-beginning) (region-end)))
         (start . ,(region-beginning))
         (end . ,(region-end))
         (lines . ,(count-lines (region-beginning) (region-end)))))
    (json-encode '((text . :null) (start . :null) (end . :null)))))
```

---

### 1.2 File Resources

#### `emacs://file/{path}`

Read file contents via the daemon. The daemon opens the file with
`find-file-noselect` (reusing an existing buffer if open), which means
the agent sees the same content the user sees, including unsaved edits.

| Attribute | Value |
|-----------|-------|
| Usefulness | **High** -- primary data access for file-oriented agents |
| Complexity | **Simple** |
| Requires daemon | Yes |
| MIME type | `text/plain` (or inferred from mode) |

```elisp
(with-current-buffer (find-file-noselect PATH)
  (buffer-substring-no-properties (point-min) (point-max)))
```

**Notes**: `{path}` is an absolute path. Relative paths should be
resolved against `default-directory` of the daemon. The server should
reject paths containing `..` traversal outside the project root if a
security policy is configured.

---

#### `emacs://file/{path}/ast`

Return a parsed representation of the file. For Elisp files, use
`read` on each top-level form. For Org files, use
`org-element-parse-buffer`. For other modes, return an error indicating
no parser is available.

| Attribute | Value |
|-----------|-------|
| Usefulness | **High** -- structured access beats regex for agents |
| Complexity | **Complex** -- multiple parsers, output normalization |
| Requires daemon | Yes |
| MIME type | `application/json` |

```elisp
;; Elisp files
(with-current-buffer (find-file-noselect PATH)
  (goto-char (point-min))
  (let (forms)
    (condition-case nil
        (while t (push (read (current-buffer)) forms))
      (end-of-file nil))
    (json-encode (vconcat (mapcar #'prin1-to-string (nreverse forms))))))

;; Org files
(with-current-buffer (find-file-noselect PATH)
  (require 'org-element)
  (let ((tree (org-element-parse-buffer)))
    (json-encode (org-element-interpret-data tree))))
```

**Notes**: The full org-element AST is very large. A practical
implementation should return a summary (headline tree with properties)
rather than the full parse tree. The Elisp `read` approach returns
string representations of forms -- sufficient for structural queries
like "find all defun names" without implementing a full Elisp AST.

---

#### `emacs://file/{path}/outline`

Return the heading/outline structure of a file. For Org: heading tree.
For Elisp: `defun`/`defvar`/`defcustom` names. For Markdown: ATX
headings. Falls back to `imenu--make-index-alist` for other modes.

| Attribute | Value |
|-----------|-------|
| Usefulness | **High** -- table-of-contents view; agents navigate by structure |
| Complexity | **Moderate** -- imenu fallback covers most modes |
| Requires daemon | Yes |
| MIME type | `application/json` |

```elisp
;; General case via imenu
(with-current-buffer (find-file-noselect PATH)
  (let ((index (ignore-errors (imenu--make-index-alist t))))
    (json-encode
     (mapcar (lambda (entry)
               `((name . ,(car entry))
                 (position . ,(if (number-or-marker-p (cdr entry))
                                  (cdr entry)
                                nil))))
             (seq-filter (lambda (e) (not (string= (car e) "*Rescan*")))
                         index)))))

;; Org-specific (richer output)
(with-current-buffer (find-file-noselect PATH)
  (require 'org-element)
  (org-element-map (org-element-parse-buffer 'headline) 'headline
    (lambda (h)
      `((level . ,(org-element-property :level h))
        (title . ,(org-element-property :raw-value h))
        (todo . ,(org-element-property :todo-keyword h))
        (tags . ,(org-element-property :tags h))
        (begin . ,(org-element-property :begin h))))))
```

---

### 1.3 Org Resources

These templates treat Org files as structured databases, which is how
many Emacs power users already use them.

#### `emacs://org/{file}/headings`

Return the full heading tree with properties, TODO state, tags, and
nesting level.

| Attribute | Value |
|-----------|-------|
| Usefulness | **High** -- Org is Emacs's killer app for structured data |
| Complexity | **Moderate** |
| Requires daemon | Yes |
| MIME type | `application/json` |

```elisp
(with-current-buffer (find-file-noselect FILE)
  (require 'org)
  (json-encode
   (vconcat
    (org-map-entries
     (lambda ()
       (let ((components (org-heading-components)))
         `((level . ,(nth 0 components))
           (todo . ,(nth 2 components))
           (priority . ,(nth 3 components))
           (title . ,(nth 4 components))
           (tags . ,(nth 5 components)))))))))
```

---

#### `emacs://org/{file}/table/{name}`

Return a named Org table as structured data (array of arrays).

| Attribute | Value |
|-----------|-------|
| Usefulness | **High** -- Org tables are lightweight databases |
| Complexity | **Moderate** -- table name lookup, hline handling |
| Requires daemon | Yes |
| MIME type | `application/json` |

```elisp
(with-current-buffer (find-file-noselect FILE)
  (require 'org)
  (goto-char (point-min))
  (search-forward NAME)
  (forward-line 1)
  (let ((table (org-table-to-lisp)))
    (json-encode
     (vconcat
      (seq-remove (lambda (row) (eq row 'hline))
                  (mapcar (lambda (row) (vconcat row)) table))))))
```

**Notes**: The `{name}` parameter matches a `#+NAME:` line preceding
the table, or the first cell content, or a `#+TBLNAME:` property.

---

#### `emacs://org/{file}/agenda/{span}`

Return agenda items from the file for the next `{span}` days.

| Attribute | Value |
|-----------|-------|
| Usefulness | **High** -- agents can reason about deadlines and schedules |
| Complexity | **Complex** -- agenda machinery is heavy |
| Requires daemon | Yes |
| MIME type | `application/json` |

```elisp
(let ((org-agenda-files (list FILE))
      (org-agenda-span (string-to-number SPAN)))
  (require 'org-agenda)
  (org-agenda-list nil nil org-agenda-span)
  (with-current-buffer org-agenda-buffer-name
    (let (entries)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((item (org-get-at-bol 'org-marker)))
          (when item
            (push `((date . ,(buffer-substring (line-beginning-position)
                                               (min (+ (line-beginning-position) 10)
                                                    (line-end-position))))
                    (text . ,(buffer-substring-no-properties
                              (line-beginning-position)
                              (line-end-position))))
                  entries)))
        (forward-line 1))
      (json-encode (vconcat (nreverse entries))))))
```

**Notes**: This is the most complex resource. The agenda machinery
modifies global state (`org-agenda-files`, the agenda buffer). The
implementation must save and restore state carefully, or run in a
dedicated `let`-binding scope. `{span}` is an integer (days).

---

#### `emacs://org/{file}/properties/{heading}`

Return the property drawer contents for a specific heading.

| Attribute | Value |
|-----------|-------|
| Usefulness | **Medium** -- useful for metadata-driven workflows |
| Complexity | **Moderate** |
| Requires daemon | Yes |
| MIME type | `application/json` |

```elisp
(with-current-buffer (find-file-noselect FILE)
  (require 'org)
  (goto-char (point-min))
  (re-search-forward
   (concat "^\\*+ .*" (regexp-quote HEADING)))
  (json-encode
   (mapcar (lambda (pair) `((key . ,(car pair)) (value . ,(cdr pair))))
           (org-entry-properties nil 'all))))
```

---

#### `emacs://org/{file}/links`

Return all links in the file with type, target, and description.

| Attribute | Value |
|-----------|-------|
| Usefulness | **Medium** -- useful for knowledge graph extraction |
| Complexity | **Moderate** |
| Requires daemon | Yes |
| MIME type | `application/json` |

```elisp
(with-current-buffer (find-file-noselect FILE)
  (require 'org-element)
  (json-encode
   (vconcat
    (org-element-map (org-element-parse-buffer) 'link
      (lambda (link)
        `((type . ,(org-element-property :type link))
          (path . ,(org-element-property :path link))
          (description . ,(when (org-element-contents link)
                            (org-element-interpret-data
                             (org-element-contents link))))))))))
```

---

#### `emacs://org/{file}/src-blocks`

Return all source blocks with language, name, and content.

| Attribute | Value |
|-----------|-------|
| Usefulness | **High** -- literate programming, code extraction |
| Complexity | **Simple** |
| Requires daemon | Yes |
| MIME type | `application/json` |

```elisp
(with-current-buffer (find-file-noselect FILE)
  (require 'org-element)
  (json-encode
   (vconcat
    (org-element-map (org-element-parse-buffer) 'src-block
      (lambda (block)
        `((language . ,(org-element-property :language block))
          (name . ,(org-element-property :name block))
          (value . ,(org-element-property :value block))
          (begin . ,(org-element-property :begin block))))))))
```

---

### 1.4 System Resources

#### `emacs://system/buffers`

List all open buffers with metadata.

| Attribute | Value |
|-----------|-------|
| Usefulness | **High** -- index of what the daemon has open |
| Complexity | **Simple** |
| Requires daemon | Yes |
| MIME type | `application/json` |

```elisp
(json-encode
 (vconcat
  (mapcar (lambda (b)
            `((name . ,(buffer-name b))
              (file . ,(buffer-file-name b))
              (size . ,(buffer-size b))
              (modified . ,(buffer-modified-p b))
              (mode . ,(with-current-buffer b
                         (symbol-name major-mode)))))
          (buffer-list))))
```

---

#### `emacs://system/processes`

List running subprocesses managed by Emacs.

| Attribute | Value |
|-----------|-------|
| Usefulness | **Medium** -- debugging, process management |
| Complexity | **Simple** |
| Requires daemon | Yes |
| MIME type | `application/json` |

```elisp
(json-encode
 (vconcat
  (mapcar (lambda (p)
            `((name . ,(process-name p))
              (command . ,(process-command p))
              (status . ,(symbol-name (process-status p)))
              (buffer . ,(when (process-buffer p)
                           (buffer-name (process-buffer p))))))
          (process-list))))
```

---

#### `emacs://system/packages`

List installed packages (requires `package.el`).

| Attribute | Value |
|-----------|-------|
| Usefulness | **Medium** -- environment introspection |
| Complexity | **Simple** |
| Requires daemon | Yes (with user init) |
| MIME type | `application/json` |

```elisp
(require 'package)
(json-encode
 (vconcat
  (mapcar (lambda (pkg)
            (let ((desc (cdr pkg)))
              `((name . ,(symbol-name (package-desc-name desc)))
                (version . ,(package-version-join
                             (package-desc-version desc)))
                (status . ,(package-desc-status desc))
                (summary . ,(package-desc-summary desc)))))
          package-alist)))
```

**Notes**: Returns nothing useful in `-Q` mode (no packages loaded).
This resource is only meaningful when the daemon runs with user init.

---

#### `emacs://system/keybindings/{prefix}`

Return keybindings under a prefix key (e.g., `C-x`, `C-c`).

| Attribute | Value |
|-----------|-------|
| Usefulness | **Low** -- niche; useful for Emacs documentation agents |
| Complexity | **Complex** -- keymap traversal is hairy |
| Requires daemon | Yes |
| MIME type | `application/json` |

```elisp
(let ((map (key-binding (kbd PREFIX))))
  (when (keymapp map)
    (json-encode
     (vconcat
      (let (bindings)
        (map-keymap
         (lambda (event def)
           (push `((key . ,(key-description (vector event)))
                   (command . ,(if (symbolp def)
                                   (symbol-name def)
                                 (format "%s" def))))
                 bindings))
         map)
        (nreverse bindings))))))
```

---

#### `emacs://system/variables/{pattern}`

Return variable names and values matching a glob/regexp pattern.

| Attribute | Value |
|-----------|-------|
| Usefulness | **Medium** -- configuration introspection |
| Complexity | **Moderate** -- obarray walk with filtering |
| Requires daemon | Yes |
| MIME type | `application/json` |

```elisp
(let (results)
  (mapatoms
   (lambda (sym)
     (when (and (boundp sym)
                (string-match-p PATTERN (symbol-name sym)))
       (push `((name . ,(symbol-name sym))
               (value . ,(let ((v (symbol-value sym)))
                           (if (or (stringp v) (numberp v) (booleanp v))
                               v
                             (prin1-to-string v))))
               (docstring . ,(or (documentation-property
                                  sym 'variable-documentation)
                                 "")))
             results))))
  (json-encode (vconcat (nreverse results))))
```

**Notes**: `{pattern}` is an Emacs regexp. Only returns values that
are serializable (strings, numbers, booleans). Complex values (lists,
vectors, hash-tables) are returned as their `prin1` representation.
Limit to 100 results to avoid overwhelming output.

---

#### `emacs://system/hooks/{name}`

Return the functions on a named hook.

| Attribute | Value |
|-----------|-------|
| Usefulness | **Medium** -- debugging, understanding Emacs behavior |
| Complexity | **Simple** |
| Requires daemon | Yes |
| MIME type | `application/json` |

```elisp
(let ((hook-sym (intern-soft NAME)))
  (when (and hook-sym (boundp hook-sym))
    (json-encode
     (vconcat
      (mapcar (lambda (fn)
                `((function . ,(if (symbolp fn)
                                   (symbol-name fn)
                                 (prin1-to-string fn)))
                  (docstring . ,(when (symbolp fn)
                                  (or (documentation fn t) "")))))
              (symbol-value hook-sym))))))
```

---

### 1.5 Project Resources

#### `emacs://project/files`

List files in the current project (via `project.el`).

| Attribute | Value |
|-----------|-------|
| Usefulness | **High** -- project-scoped file discovery |
| Complexity | **Moderate** -- requires `project.el`, project detection |
| Requires daemon | Yes |
| MIME type | `application/json` |

```elisp
(require 'project)
(let ((proj (project-current)))
  (when proj
    (json-encode
     `((root . ,(project-root proj))
       (files . ,(vconcat (project-files proj)))))))
```

---

#### `emacs://project/todos`

Return all TODO items across project Org files.

| Attribute | Value |
|-----------|-------|
| Usefulness | **High** -- task-oriented agents |
| Complexity | **Complex** -- file discovery + org parsing |
| Requires daemon | Yes |
| MIME type | `application/json` |

```elisp
(require 'project)
(require 'org)
(let* ((proj (project-current))
       (org-files (seq-filter
                   (lambda (f) (string-suffix-p ".org" f))
                   (project-files proj)))
       todos)
  (dolist (f org-files)
    (with-current-buffer (find-file-noselect f)
      (org-map-entries
       (lambda ()
         (let ((components (org-heading-components)))
           (when (nth 2 components) ; has TODO state
             (push `((file . ,f)
                     (state . ,(nth 2 components))
                     (title . ,(nth 4 components))
                     (tags . ,(nth 5 components)))
                   todos)))))))
  (json-encode (vconcat (nreverse todos))))
```

---

#### `emacs://project/tags/{tag}`

Return all Org entries with a specific tag across project files.

| Attribute | Value |
|-----------|-------|
| Usefulness | **Medium** -- tag-based knowledge queries |
| Complexity | **Complex** -- same as project/todos but tag-filtered |
| Requires daemon | Yes |
| MIME type | `application/json` |

```elisp
(require 'project)
(require 'org)
(let* ((proj (project-current))
       (org-files (seq-filter
                   (lambda (f) (string-suffix-p ".org" f))
                   (project-files proj)))
       results)
  (dolist (f org-files)
    (with-current-buffer (find-file-noselect f)
      (org-map-entries
       (lambda ()
         (let ((components (org-heading-components)))
           (push `((file . ,f)
                   (level . ,(nth 0 components))
                   (title . ,(nth 4 components))
                   (todo . ,(nth 2 components))
                   (tags . ,(nth 5 components)))
                 results)))
       TAG)))
  (json-encode (vconcat (nreverse results))))
```

---

## Part 2: Prompt Templates

Prompt templates let the server advertise structured interaction patterns
to clients. Each template has a name, a description, required arguments,
and produces a message sequence that the client can send to an LLM.

### Design Rationale

These prompts encode "things an agent would usefully ask Emacs about."
They combine resource reads with task-specific framing. The server
returns the prompt text; the client sends it to its LLM backbone.

---

### 2.1 `refactor-function`

Refactor an Elisp function toward a specific goal.

| Attribute | Value |
|-----------|-------|
| Usefulness | **High** |
| Arguments | `name` (string, required), `goal` (string, required) |

```json
{
  "name": "refactor-function",
  "description": "Refactor an Elisp function toward a specific goal. Reads the function definition from the daemon and frames the refactoring request.",
  "arguments": [
    {"name": "name", "description": "Elisp function symbol name", "required": true},
    {"name": "goal", "description": "Refactoring objective (e.g., 'reduce nesting', 'extract helper')", "required": true}
  ]
}
```

**Generated prompt**:

```
You are refactoring the Emacs Lisp function `{name}`.

Current definition:
```elisp
{source from (symbol-function (intern name)) or find-function-noselect}
```

Goal: {goal}

Constraints:
- Preserve the existing API (arglist and return value semantics)
- Keep the result idiomatic Emacs Lisp
- If the function has an autoload cookie, preserve it
```

**Elisp to fetch source**:

```elisp
(require 'find-func)
(let* ((loc (find-function-noselect (intern NAME)))
       (buf (car loc))
       (pos (cdr loc)))
  (with-current-buffer buf
    (goto-char pos)
    (buffer-substring-no-properties
     pos (scan-sexps pos 1))))
```

---

### 2.2 `explain-buffer`

Explain the contents and purpose of a buffer.

| Attribute | Value |
|-----------|-------|
| Usefulness | **High** |
| Arguments | `name` (string, required) |

```json
{
  "name": "explain-buffer",
  "description": "Explain what a buffer contains, its major mode, and likely purpose.",
  "arguments": [
    {"name": "name", "description": "Buffer name", "required": true}
  ]
}
```

**Generated prompt**:

```
Explain the following Emacs buffer.

Buffer name: {name}
Major mode: {mode}
File: {file or "no file"}
Size: {size} bytes
Modified: {yes/no}

Contents (first 200 lines):
```
{buffer text, truncated}
```

What is this buffer? What is it used for? If it is code, what does it do?
```

---

### 2.3 `org-summarize`

Summarize an Org file with focus on a specific aspect.

| Attribute | Value |
|-----------|-------|
| Usefulness | **High** |
| Arguments | `file` (string, required), `aspect` (string, optional) |

```json
{
  "name": "org-summarize",
  "description": "Summarize an Org file, optionally focusing on a specific aspect (TODOs, structure, decisions, etc.).",
  "arguments": [
    {"name": "file", "description": "Path to Org file", "required": true},
    {"name": "aspect", "description": "Focus area: 'todos', 'structure', 'decisions', 'timeline', or free-form", "required": false}
  ]
}
```

**Generated prompt**:

```
Summarize the following Org file{if aspect: ", focusing on {aspect}"}.

File: {file}
Headings: {count}

Heading tree:
{heading tree from emacs://org/{file}/headings}

{if aspect == "todos": "TODO items:\n" + todo list}
{if aspect == "timeline": "Scheduled/deadline items:\n" + timestamps}

Full text (first 500 lines):
{org file content, truncated}

Provide a concise summary.
```

---

### 2.4 `debug-error`

Diagnose an error returned by the Emacs daemon.

| Attribute | Value |
|-----------|-------|
| Usefulness | **High** |
| Arguments | `error` (string, required) |

```json
{
  "name": "debug-error",
  "description": "Diagnose an error returned by the Emacs daemon. Provides context from the error message, relevant Emacs documentation, and common causes.",
  "arguments": [
    {"name": "error", "description": "The error message or signal from Emacs", "required": true}
  ]
}
```

**Generated prompt**:

```
The Emacs daemon returned the following error:

  {error}

Diagnose this error. Consider:
1. What Elisp condition/signal does this correspond to?
2. What are the most common causes?
3. How can it be reproduced?
4. What is the fix?

{if error contains a function name: "Function documentation:\n" + (documentation 'fn)}
{if error contains "void-variable": "The variable may need to be defined or required."}
{if error contains "void-function": "The function may need to be loaded via require or autoload."}
```

---

### 2.5 `review-diff`

Review unsaved changes in a buffer.

| Attribute | Value |
|-----------|-------|
| Usefulness | **Medium** |
| Arguments | `name` (string, required) |

```json
{
  "name": "review-diff",
  "description": "Review the unsaved changes in a buffer by diffing against the file on disk.",
  "arguments": [
    {"name": "name", "description": "Buffer name (must be visiting a file)", "required": true}
  ]
}
```

**Generated prompt**:

```
Review the following unsaved changes in buffer `{name}`.

File on disk: {file}
Buffer modified: yes

Diff:
```diff
{output of diff-no-select or diff between file and buffer}
```

Assess these changes:
- Are they correct?
- Do they introduce any bugs?
- Are there any style issues?
```

**Elisp to produce diff**:

```elisp
(with-current-buffer NAME
  (diff-buffer-with-file (current-buffer))
  (with-current-buffer "*Diff*"
    (buffer-substring-no-properties (point-min) (point-max))))
```

---

### 2.6 `generate-test`

Generate ERT tests for an Elisp function.

| Attribute | Value |
|-----------|-------|
| Usefulness | **High** |
| Arguments | `name` (string, required), `file` (string, optional) |

```json
{
  "name": "generate-test",
  "description": "Generate ERT test cases for an Emacs Lisp function.",
  "arguments": [
    {"name": "name", "description": "Function symbol name", "required": true},
    {"name": "file", "description": "Source file (for context)", "required": false}
  ]
}
```

**Generated prompt**:

```
Generate ERT (Emacs Lisp Regression Testing) tests for the function `{name}`.

Function definition:
```elisp
{source}
```

Arglist: {arglist}
Docstring: {docstring}

{if file: "Source file context (surrounding definitions):\n" + nearby forms}

Generate comprehensive `ert-deftest` forms covering:
- Normal cases from the docstring
- Edge cases (empty string, nil, wrong type)
- Error conditions (should-error forms)

Use the naming convention `test-{name}--{case-description}`.
```

---

### 2.7 `org-query`

Query Org entries matching criteria across a scope.

| Attribute | Value |
|-----------|-------|
| Usefulness | **Medium** |
| Arguments | `criteria` (string, required), `scope` (string, optional) |

```json
{
  "name": "org-query",
  "description": "Find Org entries matching criteria across files. Criteria can be tags, TODO states, properties, or free-form descriptions.",
  "arguments": [
    {"name": "criteria", "description": "What to find: tag match (+work-personal), TODO state, property query, or natural language", "required": true},
    {"name": "scope", "description": "Search scope: 'buffer', 'file', 'project', or 'agenda-files'. Default: 'project'", "required": false}
  ]
}
```

**Generated prompt**:

```
Find all Org entries matching the following criteria:

Criteria: {criteria}
Scope: {scope or "project"}

Matching entries:
{results from org-map-entries with appropriate MATCH string}

For each entry, show the heading, file, TODO state, tags, and first
paragraph of body text.
```

---

### 2.8 `describe-symbol`

Provide comprehensive documentation for an Emacs Lisp symbol.

| Attribute | Value |
|-----------|-------|
| Usefulness | **High** |
| Arguments | `symbol` (string, required) |

```json
{
  "name": "describe-symbol",
  "description": "Provide comprehensive documentation for an Emacs Lisp symbol, including its definition, type, source location, and usage examples.",
  "arguments": [
    {"name": "symbol", "description": "Elisp symbol name", "required": true}
  ]
}
```

**Generated prompt**:

```
Document the Emacs Lisp symbol `{symbol}`.

Type: {function/variable/face/keymap}
{if function: "Arglist: {arglist}"}
{if function: "Interactive: {yes/no}"}
{if variable: "Value: {current value, truncated}"}
{if variable: "Custom type: {custom-type if defcustom}"}

Documentation:
{full docstring}

Source location: {file}:{line}

Explain this symbol:
- What does it do?
- When would you use it?
- What are common pitfalls?
- Show 2-3 usage examples.
```

**Elisp to gather context**:

```elisp
(let ((sym (intern SYMBOL)))
  (json-encode
   `((type . ,(cond ((fboundp sym) "function")
                    ((boundp sym) "variable")
                    ((facep sym) "face")
                    (t "unknown")))
     (docstring . ,(or (documentation sym t)
                       (documentation-property sym 'variable-documentation)
                       ""))
     (arglist . ,(when (fboundp sym)
                   (format "%s" (help-function-arglist sym t))))
     (source . ,(ignore-errors
                  (let ((loc (find-function-noselect sym)))
                    (format "%s:%d"
                            (buffer-file-name (car loc))
                            (with-current-buffer (car loc)
                              (goto-char (cdr loc))
                              (line-number-at-pos)))))))))
```

---

## Part 3: Priority Matrix

### Resource Templates

| # | Template | Agent Usefulness | Complexity | Daemon Required | Priority |
|---|----------|-----------------|------------|-----------------|----------|
| 1 | `buffer/{name}` | High | Simple | Yes | **P0** |
| 2 | `system/buffers` | High | Simple | Yes | **P0** |
| 3 | `file/{path}` | High | Simple | Yes | **P0** |
| 4 | `file/{path}/outline` | High | Moderate | Yes | **P0** |
| 5 | `org/{file}/headings` | High | Moderate | Yes | **P1** |
| 6 | `org/{file}/src-blocks` | High | Simple | Yes | **P1** |
| 7 | `buffer/{name}/mode` | High | Simple | Yes | **P1** |
| 8 | `file/{path}/ast` | High | Complex | Yes | **P1** |
| 9 | `org/{file}/table/{name}` | High | Moderate | Yes | **P1** |
| 10 | `system/variables/{pattern}` | Medium | Moderate | Yes | **P2** |
| 11 | `buffer/{name}/point` | Medium | Simple | Yes | **P2** |
| 12 | `buffer/{name}/region` | Medium | Simple | Yes | **P2** |
| 13 | `org/{file}/agenda/{span}` | High | Complex | Yes | **P2** |
| 14 | `org/{file}/properties/{heading}` | Medium | Moderate | Yes | **P2** |
| 15 | `org/{file}/links` | Medium | Moderate | Yes | **P2** |
| 16 | `system/processes` | Medium | Simple | Yes | **P2** |
| 17 | `system/hooks/{name}` | Medium | Simple | Yes | **P2** |
| 18 | `project/files` | High | Moderate | Yes | **P2** |
| 19 | `project/todos` | High | Complex | Yes | **P2** |
| 20 | `project/tags/{tag}` | Medium | Complex | Yes | **P3** |
| 21 | `system/packages` | Medium | Simple | Yes (with init) | **P3** |
| 22 | `system/keybindings/{prefix}` | Low | Complex | Yes | **P3** |

### Prompt Templates

| # | Template | Agent Usefulness | Complexity | Priority |
|---|----------|-----------------|------------|----------|
| 1 | `describe-symbol` | High | Simple | **P0** |
| 2 | `debug-error` | High | Simple | **P0** |
| 3 | `generate-test` | High | Moderate | **P1** |
| 4 | `refactor-function` | High | Moderate | **P1** |
| 5 | `explain-buffer` | High | Simple | **P1** |
| 6 | `org-summarize` | High | Moderate | **P1** |
| 7 | `org-query` | Medium | Complex | **P2** |
| 8 | `review-diff` | Medium | Moderate | **P2** |

---

## Part 4: Implementation Notes

### Protocol Integration

Adding resources and prompts to `emcp-stdio.el` requires:

1. **Advertise capabilities in `initialize`**: Add `resources` and
   `prompts` keys alongside the existing `tools` capability.

2. **New method handlers** in `emcp-stdio--dispatch`:
   - `resources/list` -- return static resources (non-parameterized)
   - `resources/read` -- resolve a URI, evaluate the Elisp, return content
   - `resources/templates/list` -- return the URI templates above
   - `prompts/list` -- return prompt template metadata
   - `prompts/get` -- fill in a prompt template with arguments

3. **URI router**: Parse `emacs://` URIs, extract template parameters,
   dispatch to the appropriate Elisp evaluator. The router is a `pcase`
   on the URI path segments.

4. **Response format** (per MCP spec):
   - `resources/read` returns `{contents: [{uri, mimeType, text}]}`
   - `prompts/get` returns `{description, messages: [{role, content}]}`

### Daemon Dependency

All resource templates require a running daemon. In batch-only mode
(no daemon), `resources/list` and `resources/templates/list` should
return empty lists rather than errors. This follows the existing pattern
where daemon tools are conditionally registered based on
`emcp-stdio--daemon-available`.

### Size Limits

Resource reads should enforce size limits to avoid overwhelming MCP
clients:
- Buffer/file content: max 100KB, with truncation note
- List resources (buffers, processes, packages): max 1000 entries
- Variable pattern matches: max 100 results

### Caching

Resources are reads, not mutations. The server could cache resource
responses for short durations (e.g., 5 seconds) to avoid repeated
`emacsclient` round-trips. However, the MCP protocol has no built-in
cache-control headers, so this would be transparent to the client.
For now, no caching -- keep it simple.

### Axiom Compliance

These resource templates do NOT violate the foundational axiom. The axiom
concerns the tool list (derived from obarray). Resources are a separate
capability that exposes daemon state as queryable data. The URI schema is
fixed by design -- it describes the *kinds* of queries, not the *functions*
available. The actual data returned is always computed by the daemon at
runtime.

---

## Part 5: Recommended Implementation Order

**Phase 1 (P0)**: Core data access (4 resources, 2 prompts)
- `buffer/{name}`, `system/buffers`, `file/{path}`, `file/{path}/outline`
- `describe-symbol`, `debug-error`
- Wire up `resources/list`, `resources/read`, `resources/templates/list`
- Wire up `prompts/list`, `prompts/get`
- This alone makes the server substantially more useful as a data layer.

**Phase 2 (P1)**: Org and structure (5 resources, 4 prompts)
- `org/{file}/headings`, `org/{file}/src-blocks`, `org/{file}/table/{name}`
- `buffer/{name}/mode`, `file/{path}/ast`
- `generate-test`, `refactor-function`, `explain-buffer`, `org-summarize`

**Phase 3 (P2)**: System introspection and project scope (10 resources, 2 prompts)
- All remaining system and project resources
- `org-query`, `review-diff`

**Phase 4 (P3)**: Niche resources (3 resources)
- `project/tags/{tag}`, `system/packages`, `system/keybindings/{prefix}`
