;;; test-tier1-smoke.el --- Tier 1: smoke test every MCP tool -*- lexical-binding: t -*-

;;; Contract traceability:
;;
;; This file validates invariants from:
;;   - docs/contracts/dispatch.md (condition-case crash protection)
;;   - docs/contracts/integration-tests.md (state isolation, framing)
;;
;; Invariants tested:
;;   D-12: condition-case wraps dispatch; server never crashes
;;   E-20: No tool corrupts subsequent calls (state isolation)
;;   E-21: Response framing (jsonrpc=2.0, correct id) on all tools
;;   E-22: Predicate tools never crash with string arg
;;   E-23: String-* tools handle input without crash

;;; Commentary:
;;
;; Smoke test: call every tool exposed by emcp-stdio with zero args.
;; Every tool should either return a result or a graceful error.
;; No tool should crash (escape the condition-case in handle-tools-call).
;;
;; Usage (full run):
;;   emacs --batch -Q -l src/emcp-stdio.el -l tests/test-tier1-smoke.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; Usage (batched, tools 0-49):
;;   emacs --batch -Q -l src/emcp-stdio.el -l tests/test-tier1-smoke.el \
;;         --eval '(setq emcp-test-tier1-batch-start 0 emcp-test-tier1-batch-size 50)' \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
;; emcp-stdio must be loaded before this file (via -l src/emcp-stdio.el)

;;; ---- Configuration ----

(defvar emcp-test-tier1-batch-start 0
  "Index of the first tool to test in this batch (0-based).
Set via --eval before running to partition across processes.")

(defvar emcp-test-tier1-batch-size nil
  "Number of tools to test in this batch.
nil means test all tools from `emcp-test-tier1-batch-start'.")

(defvar emcp-test-tier1-skip-patterns
  '("^shell-command"
    "^async-shell-command"
    "^call-process"
    "^call-shell-region"
    "^start-process"
    "^start-file-process"
    "^process-file"
    "^send-string$"
    "^send-string-to-terminal"
    "^suspend-emacs"
    "^set-binary-mode"
    "^gui-select-text"
    "^x-select-text"
    ;; Buffer-killing functions destroy the current buffer context,
    ;; causing "Selecting deleted buffer" when the handler tries to
    ;; serialize the result.
    "^kill-buffer"
    "^bury-buffer")
  "Tool name patterns to skip.  These tools have dangerous side effects
\(shell execution, process spawning, terminal control, buffer destruction)
that are unsafe in automated testing.")

;;; ---- Helpers ----

(defun emcp-test-tier1--skip-p (name)
  "Return non-nil if tool NAME should be skipped."
  (cl-some (lambda (pat) (string-match-p pat name))
           emcp-test-tier1-skip-patterns))

(defun emcp-test-tier1--capture-call (id name args-vector)
  "Call tool NAME with ARGS-VECTOR via the dispatch, capture output.
Returns the parsed response alist, or the symbol `crash' if an
error escapes the handler."
  (condition-case err
      (let ((output
             (with-temp-buffer
               (let ((standard-output (current-buffer)))
                 (emcp-stdio--handle-tools-call
                  id
                  `((name . ,name)
                    (arguments . ((args . ,args-vector)))))
                 (buffer-string)))))
        (if (string-empty-p output)
            ;; No output means the handler silently failed (unexpected)
            'silent-fail
          (condition-case _
              (json-parse-string (string-trim output) :object-type 'alist)
            (json-parse-error 'bad-json))))
    (error
     ;; An error that escaped condition-case in handle-tools-call = crash
     (message "CRASH: %s => %s" name (error-message-string err))
     'crash)))

(defun emcp-test-tier1--classify-response (resp)
  "Classify a response RESP from `emcp-test-tier1--capture-call'.
Returns one of: ok, graceful-error, crash, bad-json, silent-fail."
  (cond
   ((eq resp 'crash) 'crash)
   ((eq resp 'bad-json) 'bad-json)
   ((eq resp 'silent-fail) 'silent-fail)
   ((not (listp resp)) 'crash)
   (t
    (let ((result (alist-get 'result resp)))
      (if result
          (let ((is-error (alist-get 'isError result)))
            (if is-error
                'graceful-error
              'ok))
        ;; If there's a top-level error (shouldn't happen for tools/call)
        (if (alist-get 'error resp)
            'graceful-error
          'ok))))))

;;; ---- Test: All tools callable ----

(ert-deftest emcp-test-tier1-all-tools-callable ()
  "Every tool in the cache can be called without crashing the server. [D-12]

Calls each tool with an empty args array.  Most tools will return a
graceful error (wrong number of arguments).  The test passes if and
only if zero tools crash (error escapes the dispatch handler).

Tools matching `emcp-test-tier1-skip-patterns' are skipped and
reported separately."
  ;; Ensure tool cache is populated
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let* ((all-tools (append emcp-stdio--tools-cache nil))
         (total (length all-tools))
         ;; Apply batch window
         (start (min emcp-test-tier1-batch-start total))
         (end (if emcp-test-tier1-batch-size
                  (min (+ start emcp-test-tier1-batch-size) total)
                total))
         (batch (cl-subseq all-tools start end))
         ;; Counters
         (ok 0)
         (graceful-errors 0)
         (crashes 0)
         (skipped 0)
         (bad-json 0)
         (silent-fails 0)
         ;; Track crashed tool names for reporting
         (crashed-tools nil))
    (message "Tier 1 smoke test: tools %d-%d of %d" start (1- end) total)
    (let ((idx start))
      (dolist (tool batch)
        (let ((name (alist-get 'name tool)))
          (if (emcp-test-tier1--skip-p name)
              (progn
                (cl-incf skipped)
                (message "  SKIP [%d] %s" idx name))
            (let* ((resp (emcp-test-tier1--capture-call idx name []))
                   (class (emcp-test-tier1--classify-response resp)))
              (pcase class
                ('ok (cl-incf ok))
                ('graceful-error (cl-incf graceful-errors))
                ('crash
                 (cl-incf crashes)
                 (push name crashed-tools))
                ('bad-json
                 (cl-incf bad-json)
                 (message "  BAD-JSON [%d] %s" idx name))
                ('silent-fail
                 (cl-incf silent-fails)
                 (message "  SILENT [%d] %s" idx name)))))
          (cl-incf idx))))
    ;; Summary
    (message "")
    (message "Tier 1 Summary (tools %d-%d):" start (1- end))
    (message "  OK:              %d" ok)
    (message "  Graceful errors: %d" graceful-errors)
    (message "  Skipped:         %d" skipped)
    (message "  Bad JSON:        %d" bad-json)
    (message "  Silent fails:    %d" silent-fails)
    (message "  CRASHES:         %d" crashes)
    (message "  Total:           %d" (length batch))
    (when crashed-tools
      (message "")
      (message "CRASHED TOOLS:")
      (dolist (name (nreverse crashed-tools))
        (message "  - %s" name)))
    ;; The pass condition: zero crashes
    (should (= crashes 0))))

;;; ---- Test: No tool corrupts subsequent calls ----

(ert-deftest emcp-test-tier1-no-state-corruption ()
  "After calling all tools, string-trim still works correctly. [E-20]

This verifies that no tool call corrupts global Emacs state in a way
that breaks subsequent tool calls.  We call a known-good tool (string-trim)
before and after the full tool sweep."
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  ;; Baseline: string-trim works
  (let* ((resp-before (emcp-test-tier1--capture-call
                       9990 "string-trim" [" hello "]))
         (text-before (alist-get 'text
                                 (aref (alist-get 'content
                                                  (alist-get 'result resp-before))
                                       0))))
    (should (equal text-before "hello"))
    ;; Call a representative sample of tools (every 10th)
    (let ((tools (append emcp-stdio--tools-cache nil))
          (idx 0))
      (dolist (tool tools)
        (when (= 0 (mod idx 10))
          (let ((name (alist-get 'name tool)))
            (unless (emcp-test-tier1--skip-p name)
              (emcp-test-tier1--capture-call idx name []))))
        (cl-incf idx)))
    ;; Post-sweep: string-trim must still work
    (let* ((resp-after (emcp-test-tier1--capture-call
                        9991 "string-trim" [" world "]))
           (text-after (alist-get 'text
                                  (aref (alist-get 'content
                                                   (alist-get 'result resp-after))
                                        0))))
      (should (equal text-after "world")))))

;;; ---- Test: Response framing invariant ----

(ert-deftest emcp-test-tier1-response-framing ()
  "Every non-skipped tool returns a response with jsonrpc=2.0 and correct id. [E-21]

Even error responses must be properly framed JSON-RPC 2.0."
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let ((sample-tools
         ;; Test every 10th tool for speed (still covers ~78 tools)
         (let ((all (append emcp-stdio--tools-cache nil))
               (result nil)
               (idx 0))
           (dolist (tool all)
             (when (= 0 (mod idx 10))
               (push tool result))
             (cl-incf idx))
           (nreverse result)))
        (bad-framing 0)
        (bad-tools nil))
    (let ((id 5000))
      (dolist (tool sample-tools)
        (let ((name (alist-get 'name tool)))
          (unless (emcp-test-tier1--skip-p name)
            (let ((resp (emcp-test-tier1--capture-call id name [])))
              (when (and (listp resp) (not (memq resp '(crash bad-json silent-fail))))
                (unless (and (equal (alist-get 'jsonrpc resp) "2.0")
                             (equal (alist-get 'id resp) id))
                  (cl-incf bad-framing)
                  (push name bad-tools))))))
        (cl-incf id)))
    (when bad-tools
      (message "Tools with bad framing: %s" (string-join (nreverse bad-tools) ", ")))
    (should (= bad-framing 0))))

;;; ---- Test: Predicate tools with string arg ----

(ert-deftest emcp-test-tier1-predicates-return-value ()
  "Predicate tools (ending in -p) return either a value or graceful error. [E-22]

Predicates are the safest tool class -- they should never crash even
with wrong-type arguments."
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let ((predicate-tools
         (seq-filter
          (lambda (tool)
            (string-match-p "-p$" (alist-get 'name tool)))
          (append emcp-stdio--tools-cache nil)))
        (crashes 0)
        (crashed-names nil))
    (message "Testing %d predicate tools with string arg..."
             (length predicate-tools))
    (dolist (tool predicate-tools)
      (let* ((name (alist-get 'name tool))
             (resp (emcp-test-tier1--capture-call 8000 name ["hello"]))
             (class (emcp-test-tier1--classify-response resp)))
        (when (eq class 'crash)
          (cl-incf crashes)
          (push name crashed-names))))
    (when crashed-names
      (message "CRASHED predicates: %s"
               (string-join (nreverse crashed-names) ", ")))
    (should (= crashes 0))))

;;; ---- Test: String tools with string arg ----

(ert-deftest emcp-test-tier1-string-tools-with-input ()
  "String tools (string-*) handle a single string arg without crashing. [E-23]

Unlike the zero-args test, this provides a valid string argument to
check that the most common tool category actually processes input."
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let ((string-tools
         (seq-filter
          (lambda (tool)
            (string-prefix-p "string-" (alist-get 'name tool)))
          (append emcp-stdio--tools-cache nil)))
        (crashes 0)
        (ok 0)
        (errors 0)
        (crashed-names nil))
    (message "Testing %d string tools with input \"hello world\"..."
             (length string-tools))
    (dolist (tool string-tools)
      (let* ((name (alist-get 'name tool))
             (resp (emcp-test-tier1--capture-call 7000 name ["hello world"]))
             (class (emcp-test-tier1--classify-response resp)))
        (pcase class
          ('ok (cl-incf ok))
          ('graceful-error (cl-incf errors))
          ('crash
           (cl-incf crashes)
           (push name crashed-names))
          (_ (cl-incf errors)))))
    (message "String tools: %d ok, %d errors, %d crashes"
             ok errors crashes)
    (when crashed-names
      (message "CRASHED string tools: %s"
               (string-join (nreverse crashed-names) ", ")))
    (should (= crashes 0))))

(provide 'test-tier1-smoke)
;;; test-tier1-smoke.el ends here
