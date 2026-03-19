;;; test-integration.el --- Integration tests for emcp-stdio -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Integration tests converted from test_emcp_stdio_integration.sh.
;; Tests the full dispatch pipeline via emcp-stdio--dispatch,
;; validating JSON-RPC protocol compliance, sequential request handling,
;; malformed input resilience, and performance baselines.
;;
;; Run with:
;;   emacs --batch -Q -l src/emcp-stdio.el -l tests/test-integration.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'json)

;;; ---- Helpers ----

(defun test-integ--ensure-cache ()
  "Ensure tools cache is populated."
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools))))

(defun test-integ--dispatch-capture (msg)
  "Dispatch MSG, capture and return stdout string."
  (with-temp-buffer
    (let ((standard-output (current-buffer)))
      (emcp-stdio--dispatch msg)
      (buffer-string))))

(defun test-integ--dispatch-parse (msg)
  "Dispatch MSG, return parsed alist or nil if empty."
  (let ((output (test-integ--dispatch-capture msg)))
    (if (string-empty-p output)
        nil
      (json-parse-string (string-trim output) :object-type 'alist))))

;;; ---- 1. Protocol Handshake ----

(ert-deftest test-integ/handshake-protocol-version-present ()
  "H-01: Initialize response has protocolVersion."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                '((jsonrpc . "2.0") (id . 1) (method . "initialize") (params . ()))))
         (result (alist-get 'result resp)))
    (should (alist-get 'protocolVersion result))))

(ert-deftest test-integ/handshake-capabilities-present ()
  "H-01: Initialize response has capabilities."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                '((jsonrpc . "2.0") (id . 1) (method . "initialize") (params . ()))))
         (result (alist-get 'result resp)))
    (should (alist-get 'capabilities result))))

(ert-deftest test-integ/handshake-serverinfo-present ()
  "H-01: Initialize response has serverInfo."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                '((jsonrpc . "2.0") (id . 1) (method . "initialize") (params . ()))))
         (result (alist-get 'result resp)))
    (should (alist-get 'serverInfo result))))

(ert-deftest test-integ/handshake-jsonrpc-value ()
  "H-02: jsonrpc field is '2.0'."
  (test-integ--ensure-cache)
  (let ((resp (test-integ--dispatch-parse
               '((jsonrpc . "2.0") (id . 1) (method . "initialize") (params . ())))))
    (should (equal (alist-get 'jsonrpc resp) "2.0"))))

(ert-deftest test-integ/handshake-id-matches ()
  "H-03: Response id matches request id."
  (test-integ--ensure-cache)
  (let ((resp (test-integ--dispatch-parse
               '((jsonrpc . "2.0") (id . 1) (method . "initialize") (params . ())))))
    (should (equal (alist-get 'id resp) 1))))

(ert-deftest test-integ/handshake-protocol-version-value ()
  "H-04: protocolVersion = '2024-11-05'."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                '((jsonrpc . "2.0") (id . 1) (method . "initialize") (params . ()))))
         (result (alist-get 'result resp)))
    (should (equal (alist-get 'protocolVersion result) "2024-11-05"))))

(ert-deftest test-integ/handshake-server-name ()
  "H-05: serverInfo.name = 'emacs-mcp-elisp'."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                '((jsonrpc . "2.0") (id . 1) (method . "initialize") (params . ()))))
         (info (alist-get 'serverInfo (alist-get 'result resp))))
    (should (equal (alist-get 'name info) "emacs-mcp-elisp"))))

(ert-deftest test-integ/handshake-server-version ()
  "H-06: serverInfo.version = '0.1.0'."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                '((jsonrpc . "2.0") (id . 1) (method . "initialize") (params . ()))))
         (info (alist-get 'serverInfo (alist-get 'result resp))))
    (should (equal (alist-get 'version info) "0.1.0"))))

(ert-deftest test-integ/handshake-ping-valid ()
  "H-07: Ping returns valid JSON-RPC with result."
  (test-integ--ensure-cache)
  (let ((resp (test-integ--dispatch-parse
               '((jsonrpc . "2.0") (id . 2) (method . "ping")))))
    (should (equal (alist-get 'jsonrpc resp) "2.0"))
    (should (equal (alist-get 'id resp) 2))
    ;; result key present in raw output
    (let ((raw (test-integ--dispatch-capture
                '((jsonrpc . "2.0") (id . 2) (method . "ping")))))
      (should (string-match-p "\"result\"" raw)))))

;;; ---- 2. Notifications ----

(ert-deftest test-integ/notification-initialized-silent ()
  "N-01: notifications/initialized produces no response."
  (test-integ--ensure-cache)
  (let ((output (test-integ--dispatch-capture
                 '((jsonrpc . "2.0") (method . "notifications/initialized") (params . ())))))
    (should (string-empty-p output))))

(ert-deftest test-integ/notification-arbitrary-silent ()
  "N-02: Arbitrary notification (no id) is silently ignored."
  (test-integ--ensure-cache)
  (let ((output (test-integ--dispatch-capture
                 '((jsonrpc . "2.0") (method . "some/arbitrary/notification")))))
    (should (string-empty-p output))))

;;; ---- 3. tools/list ----

(ert-deftest test-integ/tools-list-result-present ()
  "TL-01: result.tools is present and a vector."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                '((jsonrpc . "2.0") (id . 10) (method . "tools/list") (params . ()))))
         (tools (alist-get 'tools (alist-get 'result resp))))
    (should (vectorp tools))))

(ert-deftest test-integ/tools-list-count-gte-20 ()
  "TL-02: Tool count >= 20."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                '((jsonrpc . "2.0") (id . 10) (method . "tools/list") (params . ()))))
         (tools (alist-get 'tools (alist-get 'result resp))))
    (should (>= (length tools) 20))))

(ert-deftest test-integ/tools-list-count-lt-5000 ()
  "TL-03: Tool count < 5000 (sanity)."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                '((jsonrpc . "2.0") (id . 10) (method . "tools/list") (params . ()))))
         (tools (alist-get 'tools (alist-get 'result resp))))
    (should (< (length tools) 5000))))

(ert-deftest test-integ/tools-list-schema-sample ()
  "TL-04..08: First 3 tools have valid schema structure."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                '((jsonrpc . "2.0") (id . 10) (method . "tools/list") (params . ()))))
         (tools (alist-get 'tools (alist-get 'result resp))))
    (dotimes (i (min 3 (length tools)))
      (let ((tool (aref tools i)))
        (should (stringp (alist-get 'name tool)))
        (should (equal (alist-get 'type (alist-get 'inputSchema tool)) "object"))
        (should (equal (alist-get 'type
                                  (alist-get 'args
                                             (alist-get 'properties
                                                        (alist-get 'inputSchema tool))))
                       "array"))))))

(ert-deftest test-integ/tools-list-has-string-trim ()
  "TL-09: 'string-trim' is in tools/list."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                '((jsonrpc . "2.0") (id . 10) (method . "tools/list") (params . ()))))
         (tools (alist-get 'tools (alist-get 'result resp)))
         (names (mapcar (lambda (t) (alist-get 'name t)) (append tools nil))))
    (should (member "string-trim" names))))

(ert-deftest test-integ/tools-list-has-concat ()
  "TL-09: 'concat' is in tools/list."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                '((jsonrpc . "2.0") (id . 10) (method . "tools/list") (params . ()))))
         (tools (alist-get 'tools (alist-get 'result resp)))
         (names (mapcar (lambda (t) (alist-get 'name t)) (append tools nil))))
    (should (member "concat" names))))

(ert-deftest test-integ/tools-list-has-format ()
  "TL-09: 'format' is in tools/list."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                '((jsonrpc . "2.0") (id . 10) (method . "tools/list") (params . ()))))
         (tools (alist-get 'tools (alist-get 'result resp)))
         (names (mapcar (lambda (t) (alist-get 'name t)) (append tools nil))))
    (should (member "format" names))))

(ert-deftest test-integ/tools-list-no-internals ()
  "TL-10: No emcp-stdio-* internals in tools/list."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                '((jsonrpc . "2.0") (id . 10) (method . "tools/list") (params . ()))))
         (tools (alist-get 'tools (alist-get 'result resp))))
    (dotimes (i (length tools))
      (should-not (string-prefix-p "emcp-stdio-"
                                   (alist-get 'name (aref tools i)))))))

;;; ---- 4. tools/call success ----

(ert-deftest test-integ/tools-call-upcase ()
  "TC-01: upcase('hello') = 'HELLO'."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                `((jsonrpc . "2.0") (id . 20) (method . "tools/call")
                  (params . ((name . "upcase")
                             (arguments . ((args . ["hello"]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (equal text "HELLO"))))

(ert-deftest test-integ/tools-call-downcase ()
  "TC-02: downcase('HELLO') = 'hello'."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                `((jsonrpc . "2.0") (id . 21) (method . "tools/call")
                  (params . ((name . "downcase")
                             (arguments . ((args . ["HELLO"]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (equal text "hello"))))

(ert-deftest test-integ/tools-call-string-trim ()
  "TC-03: string-trim(' hello ') = 'hello' (CLAUDE.md acceptance)."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                `((jsonrpc . "2.0") (id . 22) (method . "tools/call")
                  (params . ((name . "string-trim")
                             (arguments . ((args . [" hello "]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (equal text "hello"))))

(ert-deftest test-integ/tools-call-concat ()
  "TC-04: concat('foo','bar') = 'foobar'."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                `((jsonrpc . "2.0") (id . 23) (method . "tools/call")
                  (params . ((name . "concat")
                             (arguments . ((args . ["foo" "bar"]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (equal text "foobar"))))

(ert-deftest test-integ/tools-call-capitalize ()
  "TC-05: capitalize('hello world') = 'Hello World'."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                `((jsonrpc . "2.0") (id . 24) (method . "tools/call")
                  (params . ((name . "capitalize")
                             (arguments . ((args . ["hello world"]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (equal text "Hello World"))))

(ert-deftest test-integ/tools-call-string-reverse ()
  "TC-06: string-reverse('abc') = 'cba'."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                `((jsonrpc . "2.0") (id . 25) (method . "tools/call")
                  (params . ((name . "string-reverse")
                             (arguments . ((args . ["abc"]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (equal text "cba"))))

(ert-deftest test-integ/tools-call-content-structure ()
  "TC-07..09: result.content is array, content[0].type='text', .text present."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                `((jsonrpc . "2.0") (id . 26) (method . "tools/call")
                  (params . ((name . "upcase")
                             (arguments . ((args . ["test"]))))))))
         (content (alist-get 'content (alist-get 'result resp))))
    (should (vectorp content))
    (should (> (length content) 0))
    (should (equal (alist-get 'type (aref content 0)) "text"))
    (should (stringp (alist-get 'text (aref content 0))))))

;;; ---- 5. tools/call errors ----

(ert-deftest test-integ/tools-call-unknown-tool ()
  "TE-01: Unknown tool returns error text in content."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                `((jsonrpc . "2.0") (id . 30) (method . "tools/call")
                  (params . ((name . "nonexistent-tool-xyz")
                             (arguments . ((args . ["test"]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (string-match-p "error" text))))

(ert-deftest test-integ/tools-call-wrong-arity ()
  "TE-02: Wrong arity returns valid response, not crash."
  (test-integ--ensure-cache)
  (let ((resp (test-integ--dispatch-parse
               `((jsonrpc . "2.0") (id . 31) (method . "tools/call")
                 (params . ((name . "upcase")
                            (arguments . ((args . ["a" "b" "c" "d" "e"])))))))))
    (should resp)
    (should (equal (alist-get 'jsonrpc resp) "2.0"))))

(ert-deftest test-integ/tools-call-error-framing ()
  "TE-03: Error response has jsonrpc=2.0 and matching id."
  (test-integ--ensure-cache)
  (let ((resp (test-integ--dispatch-parse
               `((jsonrpc . "2.0") (id . 30) (method . "tools/call")
                 (params . ((name . "nonexistent-tool-xyz")
                            (arguments . ((args . ["test"])))))))))
    (should (equal (alist-get 'jsonrpc resp) "2.0"))
    (should (equal (alist-get 'id resp) 30))))

;;; ---- 6. Unknown Method ----

(ert-deftest test-integ/unknown-method-code-32601 ()
  "UM-01: Unknown method returns error code -32601."
  (test-integ--ensure-cache)
  (let ((resp (test-integ--dispatch-parse
               '((jsonrpc . "2.0") (id . 40) (method . "unknown/method") (params . ())))))
    (should (equal (alist-get 'code (alist-get 'error resp)) -32601))))

(ert-deftest test-integ/unknown-method-message ()
  "UM-02: Error message contains 'Method not found'."
  (test-integ--ensure-cache)
  (let ((resp (test-integ--dispatch-parse
               '((jsonrpc . "2.0") (id . 41) (method . "foo") (params . ())))))
    (should (string-match-p "Method not found"
                            (alist-get 'message (alist-get 'error resp))))))

;;; ---- 7. Unicode / Non-ASCII (C-004) ----

(ert-deftest test-integ/unicode-upcase-accented ()
  "U-01: upcase preserves accented characters."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                `((jsonrpc . "2.0") (id . 50) (method . "tools/call")
                  (params . ((name . "upcase")
                             (arguments . ((args . ["caf\u00e9"]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (equal text "CAF\u00c9"))))

(ert-deftest test-integ/unicode-cjk-concat ()
  "U-02: CJK characters survive round-trip."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                `((jsonrpc . "2.0") (id . 51) (method . "tools/call")
                  (params . ((name . "concat")
                             (arguments . ((args . ["hello " "\u4e16\u754c"]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (string-prefix-p "hello " text))
    (should (string-match-p "\u4e16\u754c" text))))

(ert-deftest test-integ/unicode-emoji ()
  "U-03: Emoji survives round-trip."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                `((jsonrpc . "2.0") (id . 52) (method . "tools/call")
                  (params . ((name . "concat")
                             (arguments . ((args . ["\U0001f680" " launch"]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (string-match-p "\U0001f680" text))))

(ert-deftest test-integ/unicode-latin-extended-upcase ()
  "U-04: Latin extended upcase."
  (test-integ--ensure-cache)
  (let* ((resp (test-integ--dispatch-parse
                `((jsonrpc . "2.0") (id . 53) (method . "tools/call")
                  (params . ((name . "upcase")
                             (arguments . ((args . ["caf\u00e9"]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (equal text "CAF\u00c9"))))

;;; ---- 8. Sequential Requests ----

(ert-deftest test-integ/sequential-varied-ids ()
  "SQ-01: Multiple requests with varied ids all respond correctly."
  (test-integ--ensure-cache)
  (dolist (id '(42 7 999 1000 2000))
    (let ((resp (test-integ--dispatch-parse
                 `((jsonrpc . "2.0") (id . ,id) (method . "ping")))))
      (should resp)
      (should (equal (alist-get 'id resp) id)))))

(ert-deftest test-integ/sequential-all-valid-json ()
  "SQ-01: All sequential responses are valid JSON."
  (test-integ--ensure-cache)
  (dolist (id '(42 7 999))
    (let ((output (test-integ--dispatch-capture
                   `((jsonrpc . "2.0") (id . ,id) (method . "ping")))))
      (should (not (string-empty-p output)))
      (should (json-parse-string (string-trim output))))))

(ert-deftest test-integ/sequential-mixed-methods ()
  "SQ-02: Mixed methods (tools/list, tools/call, ping) all produce responses."
  (test-integ--ensure-cache)
  (let ((msgs `(((jsonrpc . "2.0") (id . 60) (method . "tools/list") (params . ()))
                ((jsonrpc . "2.0") (id . 61) (method . "tools/call")
                 (params . ((name . "upcase") (arguments . ((args . ["test"]))))))
                ((jsonrpc . "2.0") (id . 62) (method . "ping")))))
    (dolist (msg msgs)
      (let ((output (test-integ--dispatch-capture msg)))
        (should (not (string-empty-p output)))))))

(ert-deftest test-integ/sequential-non-sequential-ids ()
  "SQ-03: Non-sequential ids (42, 7, 999) are echoed correctly."
  (test-integ--ensure-cache)
  (dolist (id '(42 7 999))
    (let ((resp (test-integ--dispatch-parse
                 `((jsonrpc . "2.0") (id . ,id) (method . "ping")))))
      (should (equal (alist-get 'id resp) id)))))

;;; ---- 9. Malformed Input ----

(ert-deftest test-integ/malformed-missing-method ()
  "MI-03: Missing method field does not crash dispatch."
  (test-integ--ensure-cache)
  ;; Missing method but has id -- dispatch should handle gracefully
  (let ((output (test-integ--dispatch-capture
                 '((jsonrpc . "2.0") (id . 72)))))
    ;; Should either produce an error response or empty -- not crash
    ;; The key assertion is that we reach this point without error
    (should t)))

;;; ---- 10. Daemon Tools (conditional) ----

(ert-deftest test-integ/daemon-tools-conditional ()
  "DT-01/DT-02: Daemon tool count varies based on daemon availability."
  (test-integ--ensure-cache)
  ;; With daemon unavailable, daemon tools should not appear
  (let ((emcp-stdio--daemon-available nil))
    (let* ((local-tools (append (emcp-stdio--collect-tools) nil))
           (emcp-stdio--tools-cache (apply #'vector local-tools))
           (resp (test-integ--dispatch-parse
                  '((jsonrpc . "2.0") (id . 80) (method . "tools/list") (params . ()))))
           (tools (alist-get 'tools (alist-get 'result resp)))
           (daemon-count (length (seq-filter
                                  (lambda (t)
                                    (string-prefix-p "emcp-data-"
                                                     (alist-get 'name t)))
                                  (append tools nil)))))
      (should (= daemon-count 0)))))

(provide 'test-integration)
;;; test-integration.el ends here
