;;; test_io_layer.el --- ERT tests for emcp-stdio I/O layer -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Tests the four I/O functions in emcp-stdio.el:
;;   emcp-stdio--send        — JSON serialization + stdout framing
;;   emcp-stdio--respond      — JSON-RPC 2.0 success response
;;   emcp-stdio--respond-error — JSON-RPC 2.0 error response
;;   (emcp-stdio--read-line tested via bash smoke tests)
;;
;; Run with:
;;   emacs --batch -Q -l src/emcp-stdio.el -l tests/test_io_layer.el -f ert-run-tests-batch-and-exit
;;
;; These tests capture stdout by rebinding `standard-output' to a buffer,
;; then parse the output to verify framing and structure.

;;; Code:

(require 'ert)
(require 'json)

;; Load the module under test (path relative to project root)
(let ((project-root (file-name-directory
                     (directory-file-name
                      (file-name-directory
                       (or load-file-name buffer-file-name))))))
  (load (expand-file-name "src/emcp-stdio.el" project-root) nil t))

;;; --- Helpers ---

(defun test-io--capture-send (alist)
  "Call `emcp-stdio--send' with ALIST, capturing stdout to a string.
Returns the raw string written to stdout."
  (with-temp-buffer
    (let ((standard-output (current-buffer)))
      (emcp-stdio--send alist))
    (buffer-string)))

(defun test-io--capture-respond (id result)
  "Call `emcp-stdio--respond', return captured stdout string."
  (with-temp-buffer
    (let ((standard-output (current-buffer)))
      (emcp-stdio--respond id result))
    (buffer-string)))

(defun test-io--capture-respond-error (id code msg)
  "Call `emcp-stdio--respond-error', return captured stdout string."
  (with-temp-buffer
    (let ((standard-output (current-buffer)))
      (emcp-stdio--respond-error id code msg))
    (buffer-string)))

;;; --- Tests for emcp-stdio--send ---

(ert-deftest test-send-produces-valid-json ()
  "emcp-stdio--send output parses as valid JSON."
  (let* ((output (test-io--capture-send '((foo . "bar") (n . 42))))
         ;; Strip trailing newline for parsing
         (json-str (string-trim-right output "\n")))
    (should (json-parse-string json-str :object-type 'alist))
    ;; Verify values survived
    (let ((parsed (json-parse-string json-str :object-type 'alist)))
      (should (equal (alist-get 'foo parsed) "bar"))
      (should (equal (alist-get 'n parsed) 42)))))

(ert-deftest test-send-exactly-one-trailing-newline ()
  "emcp-stdio--send output ends with exactly one newline."
  (let ((output (test-io--capture-send '((a . 1)))))
    ;; Ends with newline
    (should (string-suffix-p "\n" output))
    ;; But not two newlines
    (should-not (string-suffix-p "\n\n" output))))

(ert-deftest test-send-no-embedded-newlines ()
  "emcp-stdio--send output has no newlines except the trailing one."
  (let* ((output (test-io--capture-send '((text . "line1\nline2"))))
         (content (substring output 0 (1- (length output)))))
    ;; The JSON content itself must not contain literal newlines
    ;; (json-serialize escapes \n as \\n)
    (should-not (string-match-p "\n" content))))

(ert-deftest test-send-handles-ascii ()
  "emcp-stdio--send handles plain ASCII correctly."
  (let* ((output (test-io--capture-send '((msg . "hello world"))))
         (parsed (json-parse-string (string-trim-right output "\n")
                                    :object-type 'alist)))
    (should (equal (alist-get 'msg parsed) "hello world"))))

(ert-deftest test-send-handles-non-ascii-latin ()
  "emcp-stdio--send handles accented Latin characters (UTF-8 multibyte)."
  (let* ((test-str "NAIVE RESUME CAFE")  ; plain version for comparison
         (accented "NA\u00cfVE R\u00c9SUM\u00c9 CAF\u00c9")
         (output (test-io--capture-send `((text . ,accented))))
         (parsed (json-parse-string (string-trim-right output "\n")
                                    :object-type 'alist)))
    (should (equal (alist-get 'text parsed) accented))))

(ert-deftest test-send-handles-cjk ()
  "emcp-stdio--send handles CJK characters."
  (let* ((cjk "\u4f60\u597d\u4e16\u754c")  ; "hello world" in Chinese
         (output (test-io--capture-send `((text . ,cjk))))
         (parsed (json-parse-string (string-trim-right output "\n")
                                    :object-type 'alist)))
    (should (equal (alist-get 'text parsed) cjk))))

(ert-deftest test-send-handles-emoji ()
  "emcp-stdio--send handles emoji characters."
  (let* ((emoji "\U0001F600\U0001F680\U0001F4A5")  ; grinning face, rocket, explosion
         (output (test-io--capture-send `((text . ,emoji))))
         (parsed (json-parse-string (string-trim-right output "\n")
                                    :object-type 'alist)))
    (should (equal (alist-get 'text parsed) emoji))))

(ert-deftest test-send-empty-alist ()
  "emcp-stdio--send handles empty hash-table (produces {})."
  (let* ((output (test-io--capture-send (make-hash-table :test 'equal)))
         (json-str (string-trim-right output "\n")))
    (should (equal json-str "{}"))))

(ert-deftest test-send-nested-structure ()
  "emcp-stdio--send handles nested alists and vectors."
  (let* ((data '((outer . ((inner . "value")))
                 (arr . [1 2 3])))
         (output (test-io--capture-send data))
         (parsed (json-parse-string (string-trim-right output "\n")
                                    :object-type 'alist)))
    (should (equal (alist-get 'inner (alist-get 'outer parsed)) "value"))
    (should (equal (alist-get 'arr parsed) [1 2 3]))))

;;; --- Tests for emcp-stdio--respond ---

(ert-deftest test-respond-jsonrpc-field ()
  "emcp-stdio--respond includes jsonrpc = \"2.0\"."
  (let* ((output (test-io--capture-respond 1 '((status . "ok"))))
         (parsed (json-parse-string (string-trim-right output "\n")
                                    :object-type 'alist)))
    (should (equal (alist-get 'jsonrpc parsed) "2.0"))))

(ert-deftest test-respond-id-integer ()
  "emcp-stdio--respond preserves integer id."
  (let* ((output (test-io--capture-respond 42 '((x . 1))))
         (parsed (json-parse-string (string-trim-right output "\n")
                                    :object-type 'alist)))
    (should (equal (alist-get 'id parsed) 42))))

(ert-deftest test-respond-id-string ()
  "emcp-stdio--respond preserves string id."
  (let* ((output (test-io--capture-respond "req-abc" '((x . 1))))
         (parsed (json-parse-string (string-trim-right output "\n")
                                    :object-type 'alist)))
    (should (equal (alist-get 'id parsed) "req-abc"))))

(ert-deftest test-respond-result-present ()
  "emcp-stdio--respond includes the result field."
  (let* ((output (test-io--capture-respond 1 '((tools . []))))
         (parsed (json-parse-string (string-trim-right output "\n")
                                    :object-type 'alist)))
    (should (assq 'result parsed))
    (let ((result (alist-get 'result parsed)))
      (should (equal (alist-get 'tools result) [])))))

(ert-deftest test-respond-no-error-field ()
  "emcp-stdio--respond does NOT include an error field."
  (let* ((output (test-io--capture-respond 1 '((ok . t))))
         (parsed (json-parse-string (string-trim-right output "\n")
                                    :object-type 'alist)))
    (should-not (assq 'error parsed))))

(ert-deftest test-respond-exactly-three-keys ()
  "emcp-stdio--respond produces exactly three top-level keys."
  (let* ((output (test-io--capture-respond 1 '((data . "test"))))
         (parsed (json-parse-string (string-trim-right output "\n")
                                    :object-type 'alist)))
    (should (= (length parsed) 3))
    (should (assq 'jsonrpc parsed))
    (should (assq 'id parsed))
    (should (assq 'result parsed))))

;;; --- Tests for emcp-stdio--respond-error ---

(ert-deftest test-respond-error-jsonrpc-field ()
  "emcp-stdio--respond-error includes jsonrpc = \"2.0\"."
  (let* ((output (test-io--capture-respond-error 1 -32601 "Method not found"))
         (parsed (json-parse-string (string-trim-right output "\n")
                                    :object-type 'alist)))
    (should (equal (alist-get 'jsonrpc parsed) "2.0"))))

(ert-deftest test-respond-error-id-preserved ()
  "emcp-stdio--respond-error preserves the request id."
  (let* ((output (test-io--capture-respond-error 99 -32601 "Not found"))
         (parsed (json-parse-string (string-trim-right output "\n")
                                    :object-type 'alist)))
    (should (equal (alist-get 'id parsed) 99))))

(ert-deftest test-respond-error-code-and-message ()
  "emcp-stdio--respond-error includes error.code and error.message."
  (let* ((output (test-io--capture-respond-error 1 -32601 "Method not found"))
         (parsed (json-parse-string (string-trim-right output "\n")
                                    :object-type 'alist))
         (err (alist-get 'error parsed)))
    (should err)
    (should (equal (alist-get 'code err) -32601))
    (should (equal (alist-get 'message err) "Method not found"))))

(ert-deftest test-respond-error-no-result-field ()
  "emcp-stdio--respond-error does NOT include a result field."
  (let* ((output (test-io--capture-respond-error 1 -32700 "Parse error"))
         (parsed (json-parse-string (string-trim-right output "\n")
                                    :object-type 'alist)))
    (should-not (assq 'result parsed))))

(ert-deftest test-respond-error-exactly-three-keys ()
  "emcp-stdio--respond-error produces exactly three top-level keys."
  (let* ((output (test-io--capture-respond-error 1 -32601 "Not found"))
         (parsed (json-parse-string (string-trim-right output "\n")
                                    :object-type 'alist)))
    (should (= (length parsed) 3))
    (should (assq 'jsonrpc parsed))
    (should (assq 'id parsed))
    (should (assq 'error parsed))))

(ert-deftest test-respond-error-error-has-two-keys ()
  "The error object has exactly code and message."
  (let* ((output (test-io--capture-respond-error 1 -32601 "Missing"))
         (parsed (json-parse-string (string-trim-right output "\n")
                                    :object-type 'alist))
         (err (alist-get 'error parsed)))
    (should (= (length err) 2))
    (should (assq 'code err))
    (should (assq 'message err))))

;;; --- Round-trip tests ---

(ert-deftest test-round-trip-serialize-parse-reserialize ()
  "Serialize, parse, re-serialize produces identical output."
  (let* ((data '((jsonrpc . "2.0") (id . 1)
                 (result . ((content . [((type . "text")
                                         (text . "hello"))])))))
         (output1 (test-io--capture-send data))
         (parsed (json-parse-string (string-trim-right output1 "\n")
                                    :object-type 'alist))
         (output2 (test-io--capture-send parsed)))
    (should (equal output1 output2))))

(ert-deftest test-round-trip-non-ascii ()
  "Non-ASCII round-trip: serialize -> parse -> re-serialize is stable."
  (let* ((data `((text . "caf\u00e9 na\u00efve r\u00e9sum\u00e9")))
         (output1 (test-io--capture-send data))
         (parsed (json-parse-string (string-trim-right output1 "\n")
                                    :object-type 'alist))
         (output2 (test-io--capture-send parsed)))
    (should (equal output1 output2))))

(ert-deftest test-round-trip-emoji ()
  "Emoji round-trip: serialize -> parse -> re-serialize is stable."
  (let* ((data `((text . "\U0001F600 \U0001F4A1 \U0001F30D")))
         (output1 (test-io--capture-send data))
         (parsed (json-parse-string (string-trim-right output1 "\n")
                                    :object-type 'alist))
         (output2 (test-io--capture-send parsed)))
    (should (equal output1 output2))))

(ert-deftest test-round-trip-cjk ()
  "CJK round-trip: serialize -> parse -> re-serialize is stable."
  (let* ((data `((text . "\u6d4b\u8bd5\u4e2d\u6587")))
         (output1 (test-io--capture-send data))
         (parsed (json-parse-string (string-trim-right output1 "\n")
                                    :object-type 'alist))
         (output2 (test-io--capture-send parsed)))
    (should (equal output1 output2))))

;;; --- Protocol structure tests ---

(ert-deftest test-initialize-response-structure ()
  "Simulated initialize response has correct MCP structure."
  (let* ((output (test-io--capture-respond
                  1
                  `((protocolVersion . ,emcp-stdio--protocol-version)
                    (capabilities . ((tools . ,(make-hash-table :test 'equal))))
                    (serverInfo . ((name . ,emcp-stdio--server-name)
                                   (version . ,emcp-stdio--server-version))))))
         (parsed (json-parse-string (string-trim-right output "\n")
                                    :object-type 'alist))
         (result (alist-get 'result parsed)))
    (should (equal (alist-get 'protocolVersion result)
                   emcp-stdio--protocol-version))
    (should (alist-get 'capabilities result))
    (should (alist-get 'serverInfo result))
    (should (equal (alist-get 'name (alist-get 'serverInfo result))
                   emcp-stdio--server-name))))

(ert-deftest test-tool-call-success-content-structure ()
  "Tool call success wraps result in content array with type=text."
  (let* ((result-text "hello")
         (output (test-io--capture-respond
                  5
                  `((content . [((type . "text") (text . ,result-text))]))))
         (parsed (json-parse-string (string-trim-right output "\n")
                                    :object-type 'alist))
         (result (alist-get 'result parsed))
         (content (alist-get 'content result))
         (first-item (aref content 0)))
    (should (vectorp content))
    (should (equal (alist-get 'type first-item) "text"))
    (should (equal (alist-get 'text first-item) "hello"))))

;;; --- I/O layer tests converted from test_io_layer.sh ---

(ert-deftest test-io/initialize-produces-valid-jsonrpc ()
  "Initialize handshake produces valid JSON-RPC with jsonrpc, id, result."
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let* ((output (with-temp-buffer
                   (let ((standard-output (current-buffer)))
                     (emcp-stdio--dispatch
                      '((jsonrpc . "2.0") (id . 1) (method . "initialize")
                        (params . ())))
                     (buffer-string))))
         (parsed (json-parse-string (string-trim output) :object-type 'alist)))
    (should (equal (alist-get 'jsonrpc parsed) "2.0"))
    (should (equal (alist-get 'id parsed) 1))
    (should (assq 'result parsed))))

(ert-deftest test-io/response-no-error-key ()
  "Success response contains jsonrpc, id, result and no error key."
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let* ((output (with-temp-buffer
                   (let ((standard-output (current-buffer)))
                     (emcp-stdio--dispatch
                      '((jsonrpc . "2.0") (id . 42) (method . "initialize")
                        (params . ())))
                     (buffer-string))))
         (parsed (json-parse-string (string-trim output) :object-type 'alist)))
    (should (assq 'jsonrpc parsed))
    (should (assq 'id parsed))
    (should (assq 'result parsed))
    (should-not (assq 'error parsed))))

(ert-deftest test-io/non-ascii-round-trip-accented ()
  "Non-ASCII round-trip: upcase of accented Latin characters."
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let* ((output (with-temp-buffer
                   (let ((standard-output (current-buffer)))
                     (emcp-stdio--dispatch
                      `((jsonrpc . "2.0") (id . 2) (method . "tools/call")
                        (params . ((name . "upcase")
                                   (arguments . ((args . ["caf\u00e9"])))))))
                     (buffer-string))))
         (parsed (json-parse-string (string-trim output) :object-type 'alist))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result parsed)) 0))))
    (should (string-match-p "CAF" text))))

(ert-deftest test-io/emoji-round-trip ()
  "Emoji round-trip via concat."
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let* ((output (with-temp-buffer
                   (let ((standard-output (current-buffer)))
                     (emcp-stdio--dispatch
                      `((jsonrpc . "2.0") (id . 2) (method . "tools/call")
                        (params . ((name . "concat")
                                   (arguments . ((args . ["\U0001f600" "\U0001f680"])))))))
                     (buffer-string))))
         (parsed (json-parse-string (string-trim output) :object-type 'alist))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result parsed)) 0))))
    (should (not (string-empty-p text)))
    (should (not (equal text "null")))))

(ert-deftest test-io/empty-args-handled ()
  "Empty args to concat returns result."
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let* ((output (with-temp-buffer
                   (let ((standard-output (current-buffer)))
                     (emcp-stdio--dispatch
                      `((jsonrpc . "2.0") (id . 2) (method . "tools/call")
                        (params . ((name . "concat")
                                   (arguments . ((args . [])))))))
                     (buffer-string))))
         (parsed (json-parse-string (string-trim output) :object-type 'alist)))
    (should (assq 'result parsed))))

(ert-deftest test-io/unknown-method-returns-32601 ()
  "Unknown method returns JSON-RPC error with code -32601."
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let* ((output (with-temp-buffer
                   (let ((standard-output (current-buffer)))
                     (emcp-stdio--dispatch
                      '((jsonrpc . "2.0") (id . 1) (method . "nonexistent/method")
                        (params . ())))
                     (buffer-string))))
         (parsed (json-parse-string (string-trim output) :object-type 'alist)))
    (should (assq 'error parsed))
    (should-not (assq 'result parsed))
    (should (equal (alist-get 'code (alist-get 'error parsed)) -32601))))

(ert-deftest test-io/notification-no-stdout ()
  "Notification (no id) produces no output on stdout."
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let ((output (with-temp-buffer
                  (let ((standard-output (current-buffer)))
                    (emcp-stdio--dispatch
                     '((jsonrpc . "2.0") (method . "notifications/initialized")))
                    (buffer-string)))))
    (should (string-empty-p output))))

(ert-deftest test-io/multiple-requests-each-valid-json ()
  "Each dispatched request produces valid JSON output."
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let ((msgs '(((jsonrpc . "2.0") (id . 1) (method . "initialize") (params . ()))
                ((jsonrpc . "2.0") (id . 2) (method . "ping")))))
    (dolist (msg msgs)
      (let ((output (with-temp-buffer
                      (let ((standard-output (current-buffer)))
                        (emcp-stdio--dispatch msg)
                        (buffer-string)))))
        (should (not (string-empty-p output)))
        ;; Must be valid JSON
        (should (json-parse-string (string-trim output) :object-type 'alist))))))

(ert-deftest test-io/ping-response-empty-result ()
  "Ping response has valid JSON-RPC with empty result object."
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let* ((output (with-temp-buffer
                   (let ((standard-output (current-buffer)))
                     (emcp-stdio--dispatch
                      '((jsonrpc . "2.0") (id . 1) (method . "ping")))
                     (buffer-string))))
         (parsed (json-parse-string (string-trim output) :object-type 'alist)))
    (should (equal (alist-get 'jsonrpc parsed) "2.0"))
    (should (equal (alist-get 'id parsed) 1))
    ;; result key should be present
    (should (string-match-p "\"result\"" output))))

(ert-deftest test-io/tools-list-returns-tools-array ()
  "tools/list returns result with a tools array."
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let* ((output (with-temp-buffer
                   (let ((standard-output (current-buffer)))
                     (emcp-stdio--dispatch
                      '((jsonrpc . "2.0") (id . 2) (method . "tools/list")
                        (params . ())))
                     (buffer-string))))
         (parsed (json-parse-string (string-trim output) :object-type 'alist))
         (tools (alist-get 'tools (alist-get 'result parsed))))
    (should (vectorp tools))
    (should (> (length tools) 0))))

(provide 'test_io_layer)
;;; test_io_layer.el ends here
