;;; emcp-stdio.el --- Pure Elisp MCP server over stdio -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Emacs IS the MCP server.  No external runtime.  No manifest file.
;; The obarray is the tool registry.  funcall is the dispatch.
;;
;; Usage:
;;   emacs --batch -Q -l src/emcp-stdio.el -f emcp-stdio-start   # core (~vanilla)
;;   emacs --batch    -l src/emcp-stdio.el -f emcp-stdio-start   # maximalist (init.el)
;;
;; Reads newline-delimited JSON-RPC from stdin, writes to stdout.
;; Stderr gets diagnostics (tool count at startup, errors).

;;; Code:

(require 'json)
(require 'help-fns)

(defconst emcp-stdio--protocol-version "2024-11-05"
  "MCP protocol version we speak.")

(defconst emcp-stdio--server-name "emacs-mcp-elisp"
  "Server name reported in MCP initialize.")

(defconst emcp-stdio--server-version "0.1.0"
  "Server version.")

(defvar emcp-stdio--tools-cache nil
  "Cached vector of MCP tool definitions.  Built once at startup.")

(defvar emcp-stdio-filter-fn #'emcp-stdio--text-consumer-p
  "Predicate: (SYM) -> non-nil means expose as MCP tool.
Set to `always' to expose every fboundp symbol (true maximalist).")

;;; ---- I/O: one JSON line in, one JSON line out ----

(defun emcp-stdio--read-line ()
  "Read one line from stdin.  Return string or nil at EOF."
  (condition-case nil
      (read-from-minibuffer "")
    (end-of-file nil)))

(defun emcp-stdio--send (alist)
  "Serialize ALIST as JSON, write to stdout, newline, flush.
`json-serialize' returns a unibyte UTF-8 string; decode it so
`princ' emits correct multibyte output in batch mode."
  (princ (decode-coding-string (json-serialize alist) 'utf-8))
  (terpri))

(defun emcp-stdio--respond (id result)
  "Send a JSON-RPC 2.0 success response for ID."
  (emcp-stdio--send `((jsonrpc . "2.0") (id . ,id) (result . ,result))))

(defun emcp-stdio--respond-error (id code msg)
  "Send a JSON-RPC 2.0 error response for ID."
  (emcp-stdio--send
   `((jsonrpc . "2.0") (id . ,id)
     (error . ((code . ,code) (message . ,msg))))))

;;; ---- Tool collection from live obarray ----

(defun emcp-stdio--text-consumer-p (sym)
  "Non-nil if SYM's arglist suggests it consumes text."
  (condition-case nil
      (let ((arglist (format "%s" (help-function-arglist sym t))))
        (and (string-match-p
              "string\\|text\\|str[^iua]\\|buffer\\|sequence\\|object"
              arglist)
             t))
    (error nil)))

(defun emcp-stdio--build-tool (sym)
  "Build one MCP tool definition (alist) for function SYM."
  (let* ((name (symbol-name sym))
         (doc (or (ignore-errors (documentation sym t)) ""))
         (sig (format "%s" (help-function-arglist sym t))))
    `((name . ,name)
      (description . ,(if (> (length doc) 500)
                          (substring doc 0 500)
                        doc))
      (inputSchema
       . ((type . "object")
          (properties
           . ((args . ((type . "array")
                       (items . ((type . "string")))
                       (description . ,sig)))))
          (required . ["args"]))))))

(defun emcp-stdio--collect-tools ()
  "Walk obarray, return vector of MCP tool definitions."
  (let (tools)
    (mapatoms
     (lambda (sym)
       (when (and (fboundp sym)
                  (funcall emcp-stdio-filter-fn sym)
                  ;; skip our own internals
                  (not (string-prefix-p "emcp-stdio-" (symbol-name sym))))
         (push (emcp-stdio--build-tool sym) tools))))
    (apply #'vector (nreverse tools))))

;;; ---- Daemon data layer ----
;;
;; When a running Emacs daemon is reachable, these tools expose live
;; state: buffers, org files, variables — Emacs as a queryable data layer.
;; The batch process handles MCP protocol; the daemon holds the data.

(defvar emcp-stdio--daemon-available nil
  "Non-nil if emacsclient can reach a running daemon.")

(defun emcp-stdio--check-daemon ()
  "Return non-nil if a daemon is reachable."
  (zerop (call-process "emacsclient" nil nil nil
                       "--eval" "(emacs-pid)")))

(defun emcp-stdio--daemon-eval (sexp-string)
  "Evaluate SEXP-STRING in the running daemon.  Return result string.
Filters emacsclient diagnostic lines from the output."
  (with-temp-buffer
    (let ((code (call-process "emacsclient" nil t nil
                              "--eval" sexp-string)))
      (if (zerop code)
          ;; Filter emacsclient diagnostic lines (TCP socket warnings, etc.)
          ;; Strip emacsclient diagnostic lines containing "emacsclient:"
          (let ((lines (split-string (buffer-string) "\n" t)))
            (string-trim
             (mapconcat #'identity
                        (seq-remove
                         (lambda (l) (string-match-p "emacsclient:" l))
                         lines)
                        "\n")))
        (error "daemon-eval failed: %s" (string-trim (buffer-string)))))))

;; Daemon tool definitions: (name arglist docstring handler-type)
;; :raw = first arg is literal sexp; :build = construct sexp from args.
(defvar emcp-stdio--daemon-tool-defs
  '(("emcp-data-eval"
     "(sexp-string)"
     "Evaluate arbitrary Elisp in the running Emacs daemon and return the result. This is the raw query interface — Emacs as a data layer."
     :raw)

    ("emcp-data-buffer-list"
     "()"
     "List all open buffers in the running Emacs daemon with file associations. Returns one buffer per line: name<TAB>filename."
     :build)

    ("emcp-data-buffer-read"
     "(buffer-name)"
     "Read the full contents of BUFFER-NAME from the running Emacs daemon."
     :build)

    ("emcp-data-buffer-insert"
     "(buffer-name text)"
     "Insert TEXT at end of BUFFER-NAME in the running Emacs daemon."
     :build)

    ("emcp-data-find-file"
     "(filename)"
     "Open FILENAME in the running Emacs daemon. Returns the buffer name."
     :build)

    ("emcp-data-org-headings"
     "(filename)"
     "Extract all org headings from FILENAME with level, TODO state, and title. One heading per line: level<TAB>state<TAB>title<TAB>tags."
     :build)

    ("emcp-data-org-set-todo"
     "(filename heading new-state)"
     "Set the TODO state of the first heading matching HEADING in FILENAME to NEW-STATE."
     :build)

    ("emcp-data-org-table"
     "(filename table-name)"
     "Extract the org table at or after TABLE-NAME in FILENAME as tab-separated rows."
     :build)

    ("emcp-data-org-capture"
     "(file heading body)"
     "Append a new org entry with BODY under HEADING in FILE. Creates top-level heading if not found."
     :build))
  "Daemon tool definitions: (NAME ARGLIST DOCSTRING HANDLER-TYPE).")

(defun emcp-stdio--build-daemon-tools ()
  "Build MCP tool definitions for daemon tools.  Returns list of alists."
  (mapcar
   (lambda (def)
     (let ((name (nth 0 def))
           (sig  (nth 1 def))
           (doc  (nth 2 def)))
       `((name . ,name)
         (description . ,doc)
         (inputSchema
          . ((type . "object")
             (properties
              . ((args . ((type . "array")
                          (items . ((type . "string")))
                          (description . ,sig)))))
             (required . ["args"]))))))
   emcp-stdio--daemon-tool-defs))

(defun emcp-stdio--daemon-build-sexp (name args)
  "Build the sexp string for daemon tool NAME with ARGS.
Each branch builds a sexp string using `concat' and `prin1-to-string'
to avoid embedded escaped quotes that confuse the Elisp reader."
  (pcase name
    ("emcp-data-buffer-list"
     (concat "(mapconcat (lambda (b)"
             " (format " (prin1-to-string "%s\t%s")
             " (buffer-name b) (or (buffer-file-name b) "
             (prin1-to-string "") ")))"
             " (buffer-list) " (prin1-to-string "\n") ")"))

    ("emcp-data-buffer-read"
     (format "(with-current-buffer %S (buffer-substring-no-properties (point-min) (point-max)))"
             (nth 0 args)))

    ("emcp-data-buffer-insert"
     (let ((buf (nth 0 args))
           (text (nth 1 args)))
       (concat "(with-current-buffer " (prin1-to-string buf)
               " (goto-char (point-max))"
               " (insert " (prin1-to-string text) ")"
               " (format " (prin1-to-string "inserted %d chars")
               " (length " (prin1-to-string text) ")))")))

    ("emcp-data-find-file"
     (format "(buffer-name (find-file-noselect %S))" (nth 0 args)))

    ("emcp-data-org-headings"
     (let ((file (nth 0 args)))
       (concat "(progn (require 'org)"
               " (with-current-buffer (find-file-noselect " (prin1-to-string file) ")"
               " (mapconcat (lambda (c) (mapconcat #'identity c " (prin1-to-string "\t") "))"
               " (org-map-entries"
               " (lambda () (let ((h (org-heading-components)))"
               " (list (make-string (nth 0 h) ?*)"
               " (or (nth 2 h) " (prin1-to-string "-") ")"
               " (nth 4 h)"
               " (or (nth 5 h) " (prin1-to-string "") ")))))"
               " " (prin1-to-string "\n") ")))")))

    ("emcp-data-org-set-todo"
     (let ((file (nth 0 args))
           (heading (nth 1 args))
           (new-state (nth 2 args)))
       (concat "(progn (require 'org)"
               " (with-current-buffer (find-file-noselect " (prin1-to-string file) ")"
               " (goto-char (point-min))"
               " (re-search-forward (concat "
               (prin1-to-string "^\\*+ .*")
               " (regexp-quote " (prin1-to-string heading) ")))"
               " (org-todo " (prin1-to-string new-state) ")"
               " (save-buffer)"
               " (format " (prin1-to-string "set %s to %s")
               " " (prin1-to-string heading)
               " " (prin1-to-string new-state) ")))")))

    ("emcp-data-org-table"
     (let ((file (nth 0 args))
           (table-name (nth 1 args)))
       (concat "(progn (require 'org)"
               " (with-current-buffer (find-file-noselect " (prin1-to-string file) ")"
               " (goto-char (point-min))"
               " (search-forward " (prin1-to-string table-name) ")"
               " (forward-line 1)"
               " (mapconcat (lambda (row)"
               " (if (eq row 'hline) " (prin1-to-string "---")
               " (mapconcat #'identity row " (prin1-to-string "\t") ")))"
               " (org-table-to-lisp) " (prin1-to-string "\n") ")))")))

    ("emcp-data-org-capture"
     (let ((file (nth 0 args))
           (heading (nth 1 args))
           (body (nth 2 args)))
       (concat "(progn (require 'org)"
               " (with-current-buffer (find-file-noselect " (prin1-to-string file) ")"
               " (goto-char (point-min))"
               " (if (re-search-forward (concat "
               (prin1-to-string "^\\*+ ")
               " (regexp-quote " (prin1-to-string heading) ")) nil t)"
               " (progn (org-end-of-subtree t)"
               " (insert " (prin1-to-string "\n** ") " " (prin1-to-string body)
               " " (prin1-to-string "\n") ")"
               " (save-buffer) " (prin1-to-string "captured") ")"
               " (progn (goto-char (point-max))"
               " (insert " (prin1-to-string "\n* ")
               " " (prin1-to-string heading)
               " " (prin1-to-string "\n")
               " " (prin1-to-string body)
               " " (prin1-to-string "\n") ")"
               " (save-buffer) " (prin1-to-string "captured at top level") "))))")))

    (_ (error "No sexp builder for %s" name))))

(defun emcp-stdio--daemon-call (name args)
  "Dispatch daemon tool NAME with ARGS.  Return result string."
  (let ((def (assoc name emcp-stdio--daemon-tool-defs #'string=)))
    (unless def (error "Unknown daemon tool: %s" name))
    (if (eq (nth 3 def) :raw)
        (emcp-stdio--daemon-eval (car args))
      (emcp-stdio--daemon-eval (emcp-stdio--daemon-build-sexp name args)))))

;;; ---- Method handlers ----

(defun emcp-stdio--handle-initialize (id _params)
  "Handle `initialize' — advertise tool capability."
  (emcp-stdio--respond
   id
   `((protocolVersion . ,emcp-stdio--protocol-version)
     (capabilities . ((tools . ,(make-hash-table :test 'equal))))
     (serverInfo . ((name . ,emcp-stdio--server-name)
                    (version . ,emcp-stdio--server-version))))))

(defun emcp-stdio--handle-tools-list (id _params)
  "Handle `tools/list' — return cached tool definitions."
  (emcp-stdio--respond id `((tools . ,emcp-stdio--tools-cache))))

(defun emcp-stdio--handle-tools-call (id params)
  "Handle `tools/call' — route to local eval or daemon dispatch."
  (let* ((name (alist-get 'name params))
         (arguments (alist-get 'arguments params))
         (args (append (alist-get 'args arguments) nil))) ; vector → list
    (condition-case err
        (let ((result
               (if (string-prefix-p "emcp-data-" name)
                   ;; Daemon tool — dispatch to running Emacs
                   (if emcp-stdio--daemon-available
                       (emcp-stdio--daemon-call name args)
                     (error "No daemon available for %s" name))
                 ;; Local tool — eval in batch process
                 (let ((sym (intern-soft name)))
                   (unless (and sym (fboundp sym))
                     (error "Unknown tool: %s" name))
                   (let ((sexp-str (format "(%s %s)" name
                                           (mapconcat (lambda (a) (format "%S" a))
                                                      args " "))))
                     (format "%s" (eval (read sexp-str) t)))))))
          (emcp-stdio--respond
           id `((content . [((type . "text") (text . ,result))]))))
      (error
       (emcp-stdio--respond
        id `((content . [((type . "text")
                          (text . ,(format "error: %s"
                                           (error-message-string err))))])))))))

;;; ---- Dispatch ----

(defun emcp-stdio--dispatch (msg)
  "Route parsed JSON-RPC message MSG to the right handler."
  (let ((id     (alist-get 'id msg))
        (method (alist-get 'method msg))
        (params (or (alist-get 'params msg) '())))
    (cond
     ;; Notifications (no id) — swallow silently
     ((null id) nil)
     ;; Protocol
     ((string= method "initialize")
      (emcp-stdio--handle-initialize id params))
     ((string= method "ping")
      (emcp-stdio--respond id (make-hash-table :test 'equal)))
     ;; Tools
     ((string= method "tools/list")
      (emcp-stdio--handle-tools-list id params))
     ((string= method "tools/call")
      (emcp-stdio--handle-tools-call id params))
     ;; Unknown
     (t
      (emcp-stdio--respond-error id -32601
                                 (format "Method not found: %s" method))))))

;;; ---- Main ----

(defun emcp-stdio-start ()
  "Entry point.  Build tool cache, then read/dispatch loop on stdin."
  ;; Ensure UTF-8 on stdin/stdout — batch mode defaults can mangle non-ASCII
  (set-language-environment "UTF-8")
  (setq coding-system-for-read 'utf-8)
  (setq coding-system-for-write 'utf-8)
  (when (fboundp 'set-binary-mode)
    (set-binary-mode 'stdin nil)
    (set-binary-mode 'stdout nil))
  ;; Check for running daemon
  (setq emcp-stdio--daemon-available (emcp-stdio--check-daemon))
  (when emcp-stdio--daemon-available
    (message "%s: daemon detected — data layer tools enabled"
             emcp-stdio--server-name))
  ;; Build cache: obarray tools + daemon tools (if available)
  (let ((local-tools (append (emcp-stdio--collect-tools) nil))
        (daemon-tools (when emcp-stdio--daemon-available
                        (emcp-stdio--build-daemon-tools))))
    (setq emcp-stdio--tools-cache
          (apply #'vector (append local-tools daemon-tools))))
  (message "%s: %d tools (%d local%s)"
           emcp-stdio--server-name
           (length emcp-stdio--tools-cache)
           (- (length emcp-stdio--tools-cache)
              (if emcp-stdio--daemon-available
                  (length emcp-stdio--daemon-tool-defs) 0))
           (if emcp-stdio--daemon-available
               (format " + %d daemon" (length emcp-stdio--daemon-tool-defs))
             ", no daemon"))
  ;; Read loop — exits when stdin closes (client disconnects)
  (let (line)
    (while (setq line (emcp-stdio--read-line))
      (unless (string-empty-p line)
        (condition-case err
            (emcp-stdio--dispatch
             (json-parse-string line :object-type 'alist))
          (json-parse-error
           (message "JSON parse error: %s" (error-message-string err)))
          (error
           (message "Dispatch error: %s" (error-message-string err))))))))

(provide 'emcp-stdio)
;;; emcp-stdio.el ends here
