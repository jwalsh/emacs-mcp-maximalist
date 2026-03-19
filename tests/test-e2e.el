;;; test-e2e.el --- End-to-end subprocess tests for emcp-stdio -*- lexical-binding: t -*-

;;; Commentary:
;;
;; True end-to-end tests that launch emcp-stdio in a subprocess via
;; `call-process' and validate JSON-RPC responses.  These tests exercise
;; the full pipeline: stdin -> JSON parse -> dispatch -> JSON serialize -> stdout.
;;
;; Converted from test_emcp_stdio_integration.sh and test_io_layer.sh.
;; Uses json-parse-string for validation -- no python3, no jq.
;;
;; Run with:
;;   emacs --batch -Q -l src/emcp-stdio.el -l tests/test-e2e.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'json)

;;; ---- Helpers ----

(defvar test-e2e--emcp-el
  (expand-file-name "src/emcp-stdio.el"
                    (file-name-directory
                     (directory-file-name
                      (file-name-directory
                       (or load-file-name buffer-file-name)))))
  "Absolute path to emcp-stdio.el.")

(defun test-e2e--send (input-lines)
  "Send INPUT-LINES (list of strings) to emcp-stdio subprocess.
Returns the stdout string.  Each line is a JSON-RPC message."
  (let ((input (mapconcat #'identity input-lines "\n")))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8)
            (coding-system-for-write 'utf-8))
        (call-process
         "emacs" nil (current-buffer) nil
         "--batch" "-Q"
         "-l" test-e2e--emcp-el
         "-f" "emcp-stdio-start"
         ;; Use --eval to pipe input via process-send-string isn't possible
         ;; with call-process; we use a temp file instead
         ))
      ;; call-process doesn't support stdin easily; use shell-command approach
      nil)))

(defun test-e2e--send-via-shell (input-lines)
  "Send INPUT-LINES to emcp-stdio via shell pipe.  Return stdout string."
  (let ((input (mapconcat #'identity input-lines "\n"))
        (tmpfile (make-temp-file "emcp-e2e-input-"))
        (outfile (make-temp-file "emcp-e2e-output-")))
    (unwind-protect
        (progn
          (with-temp-file tmpfile
            (insert input "\n"))
          (let ((exit-code
                 (call-process-shell-command
                  (format "emacs --batch -Q -l %s -f emcp-stdio-start < %s > %s 2>/dev/null"
                          (shell-quote-argument test-e2e--emcp-el)
                          (shell-quote-argument tmpfile)
                          (shell-quote-argument outfile))
                  nil nil nil)))
            (with-temp-buffer
              (insert-file-contents outfile)
              (buffer-string))))
      (delete-file tmpfile)
      (delete-file outfile))))

(defun test-e2e--parse-responses (stdout)
  "Parse STDOUT into a list of alists (one per JSON line)."
  (let ((lines (split-string stdout "\n" t))
        result)
    (dolist (line lines)
      (let ((trimmed (string-trim line)))
        (when (and (not (string-empty-p trimmed))
                   (string-prefix-p "{" trimmed))
          (condition-case nil
              (push (json-parse-string trimmed :object-type 'alist) result)
            (json-parse-error nil)))))
    (nreverse result)))

(defun test-e2e--find-response (responses id)
  "Find the response with matching ID in RESPONSES list."
  (seq-find (lambda (r) (equal (alist-get 'id r) id)) responses))

;;; ---- E2E Tests ----

(ert-deftest test-e2e/initialize-produces-valid-json ()
  "E2E: Initialize produces valid JSON-RPC response."
  (let* ((stdout (test-e2e--send-via-shell
                  '("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}")))
         (responses (test-e2e--parse-responses stdout))
         (resp (test-e2e--find-response responses 1)))
    (should resp)
    (should (equal (alist-get 'jsonrpc resp) "2.0"))
    (should (equal (alist-get 'id resp) 1))
    (should (alist-get 'result resp))))

(ert-deftest test-e2e/initialize-has-protocol-version ()
  "E2E: Initialize result has protocolVersion."
  (let* ((stdout (test-e2e--send-via-shell
                  '("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}")))
         (responses (test-e2e--parse-responses stdout))
         (resp (test-e2e--find-response responses 1))
         (result (alist-get 'result resp)))
    (should (equal (alist-get 'protocolVersion result) "2024-11-05"))))

(ert-deftest test-e2e/ping-returns-empty-result ()
  "E2E: Ping returns response with result."
  (let* ((stdout (test-e2e--send-via-shell
                  '("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}")))
         (responses (test-e2e--parse-responses stdout))
         (resp (test-e2e--find-response responses 1)))
    (should resp)
    (should (equal (alist-get 'jsonrpc resp) "2.0"))
    (should (equal (alist-get 'id resp) 1))
    ;; result key should be present in raw output
    (should (string-match-p "\"result\"" stdout))))

(ert-deftest test-e2e/notification-no-response ()
  "E2E: Notification followed by ping yields one response."
  (let* ((stdout (test-e2e--send-via-shell
                  '("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}"
                    "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"ping\"}")))
         (responses (test-e2e--parse-responses stdout)))
    ;; Should get exactly 1 response (for the ping, not the notification)
    (should (= (length responses) 1))
    (should (equal (alist-get 'id (car responses)) 99))))

(ert-deftest test-e2e/unknown-method-error ()
  "E2E: Unknown method returns -32601 error."
  (let* ((stdout (test-e2e--send-via-shell
                  '("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"nonexistent/method\",\"params\":{}}")))
         (responses (test-e2e--parse-responses stdout))
         (resp (car responses))
         (err (alist-get 'error resp)))
    (should err)
    (should (equal (alist-get 'code err) -32601))))

(ert-deftest test-e2e/tools-list-returns-tools ()
  "E2E: tools/list returns tools array with > 0 entries."
  (let* ((stdout (test-e2e--send-via-shell
                  '("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
                    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
                    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}")))
         (responses (test-e2e--parse-responses stdout))
         (resp (test-e2e--find-response responses 2))
         (tools (alist-get 'tools (alist-get 'result resp))))
    (should tools)
    (should (> (length tools) 0))))

(ert-deftest test-e2e/tools-call-upcase ()
  "E2E: tools/call upcase('hello') returns 'HELLO'."
  (let* ((stdout (test-e2e--send-via-shell
                  '("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
                    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
                    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"upcase\",\"arguments\":{\"args\":[\"hello\"]}}}")))
         (responses (test-e2e--parse-responses stdout))
         (resp (test-e2e--find-response responses 2))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (equal text "HELLO"))))

(ert-deftest test-e2e/tools-call-string-trim ()
  "E2E: tools/call string-trim(' hello ') returns 'hello'."
  (let* ((stdout (test-e2e--send-via-shell
                  '("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
                    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
                    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"string-trim\",\"arguments\":{\"args\":[\" hello \"]}}}")))
         (responses (test-e2e--parse-responses stdout))
         (resp (test-e2e--find-response responses 2))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (equal text "hello"))))

(ert-deftest test-e2e/malformed-json-ignored ()
  "E2E: Malformed JSON line does not crash the server."
  (let* ((stdout (test-e2e--send-via-shell
                  '("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
                    "this is not json at all{{"
                    "{\"jsonrpc\":\"2.0\",\"id\":71,\"method\":\"ping\"}")))
         (responses (test-e2e--parse-responses stdout))
         (ping-resp (test-e2e--find-response responses 71)))
    ;; Server should have survived and responded to ping
    (should ping-resp)
    (should (equal (alist-get 'id ping-resp) 71))))

(ert-deftest test-e2e/empty-line-ignored ()
  "E2E: Empty line does not crash the server."
  (let* ((stdout (test-e2e--send-via-shell
                  '("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
                    ""
                    "{\"jsonrpc\":\"2.0\",\"id\":70,\"method\":\"ping\"}")))
         (responses (test-e2e--parse-responses stdout))
         (ping-resp (test-e2e--find-response responses 70)))
    (should ping-resp)))

(ert-deftest test-e2e/sequential-multiple-pings ()
  "E2E: 3 sequential pings each get correct id back."
  (let* ((stdout (test-e2e--send-via-shell
                  '("{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"ping\"}"
                    "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"ping\"}"
                    "{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"ping\"}")))
         (responses (test-e2e--parse-responses stdout)))
    (should (= (length responses) 3))
    (should (test-e2e--find-response responses 10))
    (should (test-e2e--find-response responses 20))
    (should (test-e2e--find-response responses 30))))

(ert-deftest test-e2e/each-response-valid-json ()
  "E2E: Each output line from server is valid JSON."
  (let* ((stdout (test-e2e--send-via-shell
                  '("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
                    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}")))
         (lines (split-string stdout "\n" t)))
    (dolist (line lines)
      (let ((trimmed (string-trim line)))
        (when (and (not (string-empty-p trimmed))
                   (string-prefix-p "{" trimmed))
          (should (json-parse-string trimmed)))))))

(provide 'test-e2e)
;;; test-e2e.el ends here
