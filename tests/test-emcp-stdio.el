;;; test-emcp-stdio.el --- ERT tests for emcp-stdio -*- lexical-binding: t -*-

;;; Contract traceability:
;;
;; This file validates invariants from:
;;   - docs/contracts/io-layer.md (JSON output, encoding)
;;   - docs/contracts/tool-collection.md (schema structure, filtering, exclusion)
;;   - docs/contracts/dispatch.md (method routing, error handling, initialize)
;;   - docs/contracts/daemon-data-layer.md (daemon tool defs, unavailability)
;;
;; Invariants tested:
;;   I-1:  send output is valid JSON, one line, UTF-8
;;   I-4:  Non-ASCII survives send (CJK, emoji, accented)
;;   I-7:  respond has exactly 3 keys: jsonrpc, id, result
;;   I-8:  respond jsonrpc = "2.0"
;;   I-16: respond-error has error.code and error.message
;;   T-1:  tool name is string, non-empty
;;   T-2:  tool description is string, <= 500 chars
;;   T-3:  inputSchema.type = "object"
;;   T-4:  inputSchema.properties.args.type = "array"
;;   T-5:  inputSchema.properties.args.items.type = "string"
;;   T-6:  inputSchema.required = ["args"]
;;   T-7:  No tool name starts with "emcp-stdio-"
;;   T-8:  All tools have identical schema shape
;;   T-9:  collect-tools returns a vector
;;   T-10: always filter yields more tools than default
;;   T-11: text-consumer-p matches known text fns
;;   T-12: build-tool returns well-formed alist
;;   D-1:  Every request produces exactly one response
;;   D-2:  Notifications never produce a response
;;   D-3:  Response id matches request id
;;   D-4:  Unknown methods return -32601
;;   D-6:  initialize returns protocolVersion, capabilities, serverInfo
;;   D-7:  protocolVersion = "2024-11-05"
;;   D-8:  serverInfo.name = "emacs-mcp-elisp"
;;   D-9:  serverInfo.version = "0.1.0"
;;   D-10: tools/list returns pre-built tools-cache
;;   D-11: tools/call errors are content text, not JSON-RPC errors
;;   D-12: condition-case wraps dispatch; server never crashes
;;   D-13: ping returns empty object {}
;;   D-14: Local eval: intern-soft + fboundp gate
;;   D-16: Daemon tools routed by "emcp-data-" prefix
;;   DL-1: Daemon tools only registered when daemon reachable
;;   DL-9: Each daemon tool def has 4 elements
;;   DL-10: build-daemon-tools returns well-formed MCP tools
;;   DL-14: No daemon -> error in content
;;   DL-15: Server responds to initialize without daemon
;;   E-17: tools/list >= 20 tools
;;   E-18: tools/list < 5000 tools
;;   E-19: Known functions in tools/list

;;; Commentary:
;;
;; Comprehensive test suite for the pure-Elisp MCP server.
;; Run with:
;;   emacs --batch -Q -l src/emcp-stdio.el -l tests/test-emcp-stdio.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
;; emcp-stdio must be loaded before this file (via -l src/emcp-stdio.el)

;;; ---- Helper: capture stdout from emcp-stdio--send ----

(defun test-emcp--capture-send (alist)
  "Call `emcp-stdio--send' with ALIST, return the string that would go to stdout."
  (with-temp-buffer
    (let ((standard-output (current-buffer)))
      (emcp-stdio--send alist)
      (buffer-string))))

;;; ---- I/O layer tests ----

(ert-deftest emcp-test-send-produces-valid-json ()
  "emcp-stdio--send output is valid JSON followed by newline. [I-1]"
  (let ((output (test-emcp--capture-send '((test . "value") (num . 42)))))
    ;; Must end with newline
    (should (string-suffix-p "\n" output))
    ;; Must be parseable JSON
    (let ((parsed (json-parse-string (string-trim output) :object-type 'alist)))
      (should (equal (alist-get 'test parsed) "value"))
      (should (equal (alist-get 'num parsed) 42)))))

(ert-deftest emcp-test-send-handles-unicode ()
  "Non-ASCII survives json-serialize -> decode-coding-string -> princ. [I-4]"
  (let ((output (test-emcp--capture-send '((text . "hello")))))
    (let ((parsed (json-parse-string (string-trim output) :object-type 'alist)))
      (should (equal (alist-get 'text parsed) "hello"))))
  ;; CJK characters
  (let ((output (test-emcp--capture-send '((text . "\u6F22\u5B57")))))
    (let ((parsed (json-parse-string (string-trim output) :object-type 'alist)))
      (should (equal (alist-get 'text parsed) "\u6F22\u5B57"))))
  ;; Emoji
  (let ((output (test-emcp--capture-send '((text . "\U0001F600")))))
    (let ((parsed (json-parse-string (string-trim output) :object-type 'alist)))
      (should (equal (alist-get 'text parsed) "\U0001F600")))))

(ert-deftest emcp-test-respond-structure ()
  "Response has jsonrpc, id, and result fields. [I-7 I-8]"
  (let* ((output (with-temp-buffer
                   (let ((standard-output (current-buffer)))
                     (emcp-stdio--respond 1 '((foo . "bar")))
                     (buffer-string))))
         (parsed (json-parse-string (string-trim output) :object-type 'alist)))
    (should (equal (alist-get 'jsonrpc parsed) "2.0"))
    (should (equal (alist-get 'id parsed) 1))
    (should (alist-get 'result parsed))
    (should (equal (alist-get 'foo (alist-get 'result parsed)) "bar"))))

(ert-deftest emcp-test-respond-error-structure ()
  "Error response has jsonrpc, id, and error.code + error.message. [I-13 I-16]"
  (let* ((output (with-temp-buffer
                   (let ((standard-output (current-buffer)))
                     (emcp-stdio--respond-error 99 -32601 "Method not found")
                     (buffer-string))))
         (parsed (json-parse-string (string-trim output) :object-type 'alist)))
    (should (equal (alist-get 'jsonrpc parsed) "2.0"))
    (should (equal (alist-get 'id parsed) 99))
    (let ((err (alist-get 'error parsed)))
      (should err)
      (should (equal (alist-get 'code err) -32601))
      (should (equal (alist-get 'message err) "Method not found")))))

;;; ---- Tool collection tests ----

(ert-deftest emcp-test-collect-tools-nonempty ()
  "collect-tools returns a non-empty vector. [T-9]"
  (let ((tools (emcp-stdio--collect-tools)))
    (should (vectorp tools))
    (should (> (length tools) 0))))

(ert-deftest emcp-test-tool-schema-valid ()
  "Every tool has name, description, inputSchema with required fields. [T-1 T-3 T-8]"
  (let ((tools (emcp-stdio--collect-tools)))
    (dotimes (i (min 50 (length tools)))  ;; check first 50 to keep test fast
      (let ((tool (aref tools i)))
        (should (stringp (alist-get 'name tool)))
        (should (stringp (alist-get 'description tool)))
        (let ((schema (alist-get 'inputSchema tool)))
          (should schema)
          (should (equal (alist-get 'type schema) "object"))
          (should (alist-get 'properties schema))
          (should (alist-get 'required schema)))))))

(ert-deftest emcp-test-no-internal-tools-exposed ()
  "No tool name starts with emcp-stdio-. [T-7]"
  (let ((tools (emcp-stdio--collect-tools)))
    (dotimes (i (length tools))
      (let ((name (alist-get 'name (aref tools i))))
        (should-not (string-prefix-p "emcp-stdio-" name))))))

(ert-deftest emcp-test-description-length ()
  "All descriptions are <= 500 chars. [T-2]"
  (let ((tools (emcp-stdio--collect-tools)))
    (dotimes (i (length tools))
      (let ((desc (alist-get 'description (aref tools i))))
        (should (<= (length desc) 500))))))

(ert-deftest emcp-test-text-consumer-heuristic ()
  "Known text functions pass the filter; known non-text functions don't. [T-11]"
  ;; These should pass the text-consumer heuristic (arglist contains
  ;; string/buffer/object/text keywords)
  (should (emcp-stdio--text-consumer-p 'string-trim))
  (should (emcp-stdio--text-consumer-p 'concat))
  (should (emcp-stdio--text-consumer-p 'substring))
  ;; These should NOT pass (numeric/no-string args)
  (should-not (emcp-stdio--text-consumer-p '+))
  (should-not (emcp-stdio--text-consumer-p 'car)))

;;; ---- Dispatch tests ----

(ert-deftest emcp-test-dispatch-initialize ()
  "Initialize returns protocolVersion, capabilities, serverInfo. [D-6 D-7]"
  ;; Ensure tool cache is populated
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let* ((output (with-temp-buffer
                   (let ((standard-output (current-buffer)))
                     (emcp-stdio--dispatch
                      '((jsonrpc . "2.0") (id . 1) (method . "initialize")
                        (params . ((protocolVersion . "2024-11-05")))))
                     (buffer-string))))
         (parsed (json-parse-string (string-trim output) :object-type 'alist))
         (result (alist-get 'result parsed)))
    (should (equal (alist-get 'protocolVersion result) "2024-11-05"))
    (should (alist-get 'capabilities result))
    (let ((info (alist-get 'serverInfo result)))
      (should info)
      (should (stringp (alist-get 'name info)))
      (should (stringp (alist-get 'version info))))))

(ert-deftest emcp-test-dispatch-notification-silent ()
  "Notifications (no id) produce no output. [D-2]"
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let ((output (with-temp-buffer
                  (let ((standard-output (current-buffer)))
                    (emcp-stdio--dispatch
                     '((jsonrpc . "2.0") (method . "notifications/initialized")))
                    (buffer-string)))))
    (should (string-empty-p output))))

(ert-deftest emcp-test-dispatch-unknown-method ()
  "Unknown method returns -32601 error. [D-4]"
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let* ((output (with-temp-buffer
                   (let ((standard-output (current-buffer)))
                     (emcp-stdio--dispatch
                      '((jsonrpc . "2.0") (id . 7) (method . "nonexistent/method")))
                     (buffer-string))))
         (parsed (json-parse-string (string-trim output) :object-type 'alist))
         (err (alist-get 'error parsed)))
    (should err)
    (should (equal (alist-get 'code err) -32601))))

(ert-deftest emcp-test-dispatch-ping ()
  "Ping returns empty object, not an error. [D-13]"
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let* ((output (with-temp-buffer
                   (let ((standard-output (current-buffer)))
                     (emcp-stdio--dispatch
                      '((jsonrpc . "2.0") (id . 2) (method . "ping")))
                     (buffer-string))))
         (parsed (json-parse-string (string-trim output) :object-type 'alist)))
    ;; Must have jsonrpc and id
    (should (equal (alist-get 'jsonrpc parsed) "2.0"))
    (should (equal (alist-get 'id parsed) 2))
    ;; Must NOT have an error field
    (should-not (alist-get 'error parsed))
    ;; The result key must be present in the raw JSON (even if {} parses to nil as alist).
    ;; Verify by checking raw output contains "result"
    (should (string-match-p "\"result\"" output))))

(ert-deftest emcp-test-tools-list ()
  "tools/list returns a result with a tools array. [D-10]"
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let* ((output (with-temp-buffer
                   (let ((standard-output (current-buffer)))
                     (emcp-stdio--dispatch
                      '((jsonrpc . "2.0") (id . 3) (method . "tools/list")))
                     (buffer-string))))
         (parsed (json-parse-string (string-trim output) :object-type 'alist))
         (result (alist-get 'result parsed))
         (tools (alist-get 'tools result)))
    (should tools)
    (should (> (length tools) 0))))

(ert-deftest emcp-test-tools-call-local ()
  "tools/call with string-trim returns trimmed string. [D-14]"
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let* ((output (with-temp-buffer
                   (let ((standard-output (current-buffer)))
                     (emcp-stdio--dispatch
                      `((jsonrpc . "2.0") (id . 4) (method . "tools/call")
                        (params . ((name . "string-trim")
                                   (arguments . ((args . ["  hello  "])))))))
                     (buffer-string))))
         (parsed (json-parse-string (string-trim output) :object-type 'alist))
         (result (alist-get 'result parsed))
         (content (alist-get 'content result)))
    (should content)
    (should (> (length content) 0))
    (let ((text (alist-get 'text (aref content 0))))
      (should (equal text "hello")))))

(ert-deftest emcp-test-tools-call-unknown ()
  "tools/call with nonexistent function returns error in content. [D-11]"
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let* ((output (with-temp-buffer
                   (let ((standard-output (current-buffer)))
                     (emcp-stdio--dispatch
                      `((jsonrpc . "2.0") (id . 5) (method . "tools/call")
                        (params . ((name . "absolutely-no-such-function-xyz")
                                   (arguments . ((args . [])))))))
                     (buffer-string))))
         (parsed (json-parse-string (string-trim output) :object-type 'alist))
         (result (alist-get 'result parsed))
         (content (alist-get 'content result)))
    (should content)
    (let ((text (alist-get 'text (aref content 0))))
      (should (string-match-p "error" text)))))

(ert-deftest emcp-test-tools-call-unicode ()
  "tools/call preserves non-ASCII through the full pipeline. [I-4]"
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
  (let* ((output (with-temp-buffer
                   (let ((standard-output (current-buffer)))
                     (emcp-stdio--dispatch
                      `((jsonrpc . "2.0") (id . 6) (method . "tools/call")
                        (params . ((name . "upcase")
                                   (arguments . ((args . ["\u00e9\u00e0\u00fc"])))))))
                     (buffer-string))))
         (parsed (json-parse-string (string-trim output) :object-type 'alist))
         (result (alist-get 'result parsed))
         (content (alist-get 'content result)))
    (should content)
    (let ((text (alist-get 'text (aref content 0))))
      (should (equal text "\u00c9\u00c0\u00dc")))))

;;; ---- Build-tool shape tests ----

(ert-deftest emcp-test-build-tool-shape ()
  "emcp-stdio--build-tool returns well-formed alist for a known function. [T-12]"
  (let ((tool (emcp-stdio--build-tool 'concat)))
    (should (equal (alist-get 'name tool) "concat"))
    (should (stringp (alist-get 'description tool)))
    (let ((schema (alist-get 'inputSchema tool)))
      (should (equal (alist-get 'type schema) "object"))
      (let ((props (alist-get 'properties schema)))
        (should (alist-get 'args props))
        (let ((args-schema (alist-get 'args props)))
          (should (equal (alist-get 'type args-schema) "array")))))))

;;; ---- Daemon tool definitions ----

(ert-deftest emcp-test-daemon-tool-defs-well-formed ()
  "Each daemon tool definition has 4 elements: name, arglist, doc, handler-type. [DL-9]"
  (dolist (def emcp-stdio--daemon-tool-defs)
    (should (= (length def) 4))
    (should (stringp (nth 0 def)))
    (should (stringp (nth 1 def)))
    (should (stringp (nth 2 def)))
    (should (memq (nth 3 def) '(:raw :build)))))

(ert-deftest emcp-test-build-daemon-tools-shape ()
  "emcp-stdio--build-daemon-tools returns well-formed tool definitions. [DL-10]"
  (let ((tools (emcp-stdio--build-daemon-tools)))
    (should (listp tools))
    (should (> (length tools) 0))
    (dolist (tool tools)
      (should (stringp (alist-get 'name tool)))
      (should (string-prefix-p "emcp-data-" (alist-get 'name tool)))
      (should (stringp (alist-get 'description tool)))
      (should (alist-get 'inputSchema tool)))))

;;; ---- Dispatch tests (converted from test_dispatch.sh) ----

(defun test-emcp--ensure-tools-cache ()
  "Ensure the tools cache is populated for dispatch tests."
  (unless emcp-stdio--tools-cache
    (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools))))

(defun test-emcp--dispatch-capture (msg)
  "Dispatch MSG and return the captured output string."
  (with-temp-buffer
    (let ((standard-output (current-buffer)))
      (emcp-stdio--dispatch msg)
      (buffer-string))))

(defun test-emcp--dispatch-parse (msg)
  "Dispatch MSG and return parsed JSON response as alist.
Returns nil if no output was produced."
  (let ((output (test-emcp--dispatch-capture msg)))
    (if (string-empty-p output)
        nil
      (json-parse-string (string-trim output) :object-type 'alist))))

(ert-deftest emcp-test-dispatch/initialize-full ()
  "Initialize returns protocolVersion=2024-11-05, capabilities.tools, serverInfo.name and version. [D-6 D-7 D-8 D-9]"
  (test-emcp--ensure-tools-cache)
  (let ((resp (test-emcp--dispatch-parse
               '((jsonrpc . "2.0") (id . 1) (method . "initialize") (params . ())))))
    (should resp)
    (should (equal (alist-get 'jsonrpc resp) "2.0"))
    (should (equal (alist-get 'id resp) 1))
    (let ((result (alist-get 'result resp)))
      (should (equal (alist-get 'protocolVersion result) "2024-11-05"))
      ;; capabilities.tools should exist (hash-table or alist)
      (should (alist-get 'capabilities result))
      (let ((info (alist-get 'serverInfo result)))
        (should info)
        (should (not (string-empty-p (alist-get 'name info))))
        (should (not (string-empty-p (alist-get 'version info))))))))

(ert-deftest emcp-test-dispatch/notification-no-response ()
  "Notification (no id) followed by request yields only one response. [D-1 D-2]"
  (test-emcp--ensure-tools-cache)
  ;; Notification should produce no output
  (let ((output (test-emcp--dispatch-capture
                 '((jsonrpc . "2.0") (method . "notifications/initialized") (params . ())))))
    (should (string-empty-p output)))
  ;; A request should produce output
  (let ((output (test-emcp--dispatch-capture
                 '((jsonrpc . "2.0") (id . 99) (method . "ping")))))
    (should (not (string-empty-p output)))
    (let ((parsed (json-parse-string (string-trim output) :object-type 'alist)))
      (should (equal (alist-get 'id parsed) 99)))))

(ert-deftest emcp-test-dispatch/unknown-method-code ()
  "Unknown method returns error code -32601 with method name in message. [D-4]"
  (test-emcp--ensure-tools-cache)
  (let ((resp (test-emcp--dispatch-parse
               '((jsonrpc . "2.0") (id . 2) (method . "bogus/nonexistent") (params . ())))))
    (should resp)
    (let ((err (alist-get 'error resp)))
      (should err)
      (should (equal (alist-get 'code err) -32601))
      (should (string-match-p "bogus/nonexistent" (alist-get 'message err))))))

(ert-deftest emcp-test-dispatch/tools-call-valid-upcase ()
  "tools/call with upcase returns content array with HELLO. [D-14]"
  (test-emcp--ensure-tools-cache)
  (let ((resp (test-emcp--dispatch-parse
               `((jsonrpc . "2.0") (id . 3) (method . "tools/call")
                 (params . ((name . "upcase")
                            (arguments . ((args . ["hello"])))))))))
    (should resp)
    (should (alist-get 'result resp))
    (should-not (alist-get 'error resp))
    (let* ((result (alist-get 'result resp))
           (content (alist-get 'content result)))
      (should (vectorp content))
      (should (> (length content) 0))
      (should (equal (alist-get 'type (aref content 0)) "text"))
      (should (string-match-p "HELLO" (alist-get 'text (aref content 0)))))))

(ert-deftest emcp-test-dispatch/tools-call-nonexistent ()
  "tools/call with nonexistent function returns error text in content. [D-11]"
  (test-emcp--ensure-tools-cache)
  (let ((resp (test-emcp--dispatch-parse
               `((jsonrpc . "2.0") (id . 4) (method . "tools/call")
                 (params . ((name . "this-function-does-not-exist-xyz")
                            (arguments . ((args . [])))))))))
    (should resp)
    ;; Should be in result (error in content), not a JSON-RPC error
    (should (alist-get 'result resp))
    (let* ((content (alist-get 'content (alist-get 'result resp)))
           (text (alist-get 'text (aref content 0))))
      (should (string-match-p "error" text)))))

(ert-deftest emcp-test-dispatch/tools-call-bad-args ()
  "tools/call with bad args returns error in content, not a crash. [D-11 D-12]"
  (test-emcp--ensure-tools-cache)
  (let ((resp (test-emcp--dispatch-parse
               `((jsonrpc . "2.0") (id . 5) (method . "tools/call")
                 (params . ((name . "substring")
                            (arguments . ((args . ["hello" "not-a-number"])))))))))
    (should resp)
    ;; Should produce a result (error caught), not a JSON-RPC error
    (should (alist-get 'result resp))
    (let* ((content (alist-get 'content (alist-get 'result resp)))
           (text (alist-get 'text (aref content 0))))
      (should (string-match-p "error" text)))))

(ert-deftest emcp-test-dispatch/ping-empty-result ()
  "Ping returns empty object result with correct id. [D-3 D-13]"
  (test-emcp--ensure-tools-cache)
  (let ((resp (test-emcp--dispatch-parse
               '((jsonrpc . "2.0") (id . 6) (method . "ping")))))
    (should resp)
    (should (equal (alist-get 'id resp) 6))
    ;; result should be present (in raw JSON)
    (let ((output (test-emcp--dispatch-capture
                   '((jsonrpc . "2.0") (id . 6) (method . "ping")))))
      (should (string-match-p "\"result\"" output)))))

(ert-deftest emcp-test-dispatch/sequential-ids ()
  "Multiple sequential dispatches each return the correct id. [D-3]"
  (test-emcp--ensure-tools-cache)
  (dolist (id '(10 20 30))
    (let ((resp (test-emcp--dispatch-parse
                 `((jsonrpc . "2.0") (id . ,id) (method . "ping")))))
      (should resp)
      (should (equal (alist-get 'id resp) id)))))

;;; ---- Tool collection tests (converted from test_tool_collection.sh) ----

(ert-deftest emcp-test-tool-collection/count-positive ()
  "Tool count > 0 for vanilla Emacs (-Q). [T-9]"
  (let ((tools (emcp-stdio--collect-tools)))
    (should (> (length tools) 0))))

(ert-deftest emcp-test-tool-collection/all-have-name ()
  "Every tool has a non-empty string 'name' field. [T-1]"
  (let ((tools (emcp-stdio--collect-tools)))
    (dotimes (i (length tools))
      (let ((name (alist-get 'name (aref tools i))))
        (should (stringp name))
        (should (> (length name) 0))))))

(ert-deftest emcp-test-tool-collection/all-have-description ()
  "Every tool has a string 'description' field. [T-2]"
  (let ((tools (emcp-stdio--collect-tools)))
    (dotimes (i (length tools))
      (should (stringp (alist-get 'description (aref tools i)))))))

(ert-deftest emcp-test-tool-collection/all-schema-type-object ()
  "Every tool has inputSchema.type = 'object'. [T-3]"
  (let ((tools (emcp-stdio--collect-tools)))
    (dotimes (i (length tools))
      (let ((schema (alist-get 'inputSchema (aref tools i))))
        (should (equal (alist-get 'type schema) "object"))))))

(ert-deftest emcp-test-tool-collection/all-args-type-array ()
  "Every tool has inputSchema.properties.args.type = 'array'. [T-4]"
  (let ((tools (emcp-stdio--collect-tools)))
    (dotimes (i (length tools))
      (let* ((schema (alist-get 'inputSchema (aref tools i)))
             (props (alist-get 'properties schema))
             (args (alist-get 'args props)))
        (should (equal (alist-get 'type args) "array"))))))

(ert-deftest emcp-test-tool-collection/all-items-type-string ()
  "Every tool has inputSchema.properties.args.items.type = 'string'. [T-5]"
  (let ((tools (emcp-stdio--collect-tools)))
    (dotimes (i (length tools))
      (let* ((schema (alist-get 'inputSchema (aref tools i)))
             (props (alist-get 'properties schema))
             (args (alist-get 'args props))
             (items (alist-get 'items args)))
        (should (equal (alist-get 'type items) "string"))))))

(ert-deftest emcp-test-tool-collection/no-emcp-stdio-prefix ()
  "No tool name starts with 'emcp-stdio-' (default filter). [T-7]"
  (let ((tools (emcp-stdio--collect-tools)))
    (dotimes (i (length tools))
      (should-not (string-prefix-p "emcp-stdio-"
                                   (alist-get 'name (aref tools i)))))))

(ert-deftest emcp-test-tool-collection/descriptions-under-500 ()
  "All descriptions are <= 500 characters. [T-2]"
  (let ((tools (emcp-stdio--collect-tools)))
    (dotimes (i (length tools))
      (should (<= (length (alist-get 'description (aref tools i))) 500)))))

(ert-deftest emcp-test-tool-collection/required-is-args ()
  "Every tool has inputSchema.required containing 'args'. [T-6]"
  (let ((tools (emcp-stdio--collect-tools)))
    (dotimes (i (length tools))
      (let* ((schema (alist-get 'inputSchema (aref tools i)))
             (required (alist-get 'required schema)))
        ;; required is a vector ["args"]
        (should (vectorp required))
        (should (equal (aref required 0) "args"))))))

(ert-deftest emcp-test-tool-collection/safe-always-filter-larger ()
  "Tool count with safe-always filter > default filter count. [T-10]"
  (let ((default-count (length (emcp-stdio--collect-tools)))
        (always-tools nil))
    ;; Collect with always filter (with error protection per symbol)
    (mapatoms
     (lambda (sym)
       (when (and (fboundp sym)
                  (not (string-prefix-p "emcp-stdio-" (symbol-name sym))))
         (condition-case nil
             (push (emcp-stdio--build-tool sym) always-tools)
           (error nil)))))
    (should (> (length always-tools) default-count))))

;;; ---- tools/call success cases (converted from test_emcp_stdio_integration.sh) ----

(ert-deftest emcp-test-dispatch/tools-call-downcase ()
  "tools/call downcase('HELLO') returns 'hello'. [D-14]"
  (test-emcp--ensure-tools-cache)
  (let* ((resp (test-emcp--dispatch-parse
                `((jsonrpc . "2.0") (id . 21) (method . "tools/call")
                  (params . ((name . "downcase")
                             (arguments . ((args . ["HELLO"]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (equal text "hello"))))

(ert-deftest emcp-test-dispatch/tools-call-string-trim ()
  "tools/call string-trim(' hello ') returns 'hello'. [D-14]"
  (test-emcp--ensure-tools-cache)
  (let* ((resp (test-emcp--dispatch-parse
                `((jsonrpc . "2.0") (id . 22) (method . "tools/call")
                  (params . ((name . "string-trim")
                             (arguments . ((args . [" hello "]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (equal text "hello"))))

(ert-deftest emcp-test-dispatch/tools-call-concat ()
  "tools/call concat('foo','bar') returns 'foobar'. [D-14]"
  (test-emcp--ensure-tools-cache)
  (let* ((resp (test-emcp--dispatch-parse
                `((jsonrpc . "2.0") (id . 23) (method . "tools/call")
                  (params . ((name . "concat")
                             (arguments . ((args . ["foo" "bar"]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (equal text "foobar"))))

(ert-deftest emcp-test-dispatch/tools-call-capitalize ()
  "tools/call capitalize('hello world') returns 'Hello World'. [D-14]"
  (test-emcp--ensure-tools-cache)
  (let* ((resp (test-emcp--dispatch-parse
                `((jsonrpc . "2.0") (id . 24) (method . "tools/call")
                  (params . ((name . "capitalize")
                             (arguments . ((args . ["hello world"]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (equal text "Hello World"))))

(ert-deftest emcp-test-dispatch/tools-call-string-reverse ()
  "tools/call string-reverse('abc') returns 'cba'. [D-14]"
  (test-emcp--ensure-tools-cache)
  (let* ((resp (test-emcp--dispatch-parse
                `((jsonrpc . "2.0") (id . 25) (method . "tools/call")
                  (params . ((name . "string-reverse")
                             (arguments . ((args . ["abc"]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (equal text "cba"))))

(ert-deftest emcp-test-dispatch/tools-call-content-type-text ()
  "tools/call result has content[0].type = 'text'. [D-11]"
  (test-emcp--ensure-tools-cache)
  (let* ((resp (test-emcp--dispatch-parse
                `((jsonrpc . "2.0") (id . 26) (method . "tools/call")
                  (params . ((name . "upcase")
                             (arguments . ((args . ["test"]))))))))
         (content (alist-get 'content (alist-get 'result resp))))
    (should (vectorp content))
    (should (equal (alist-get 'type (aref content 0)) "text"))
    (should (stringp (alist-get 'text (aref content 0))))))

;;; ---- Error handling tests (converted from integration test) ----

(ert-deftest emcp-test-dispatch/wrong-arity-no-crash ()
  "tools/call with wrong arity returns valid JSON-RPC, not a crash. [D-12]"
  (test-emcp--ensure-tools-cache)
  (let ((resp (test-emcp--dispatch-parse
               `((jsonrpc . "2.0") (id . 31) (method . "tools/call")
                 (params . ((name . "upcase")
                            (arguments . ((args . ["a" "b" "c" "d" "e"])))))))))
    (should resp)
    (should (equal (alist-get 'jsonrpc resp) "2.0"))))

(ert-deftest emcp-test-dispatch/error-response-framing ()
  "Error responses preserve jsonrpc=2.0 and matching id. [D-3 D-11]"
  (test-emcp--ensure-tools-cache)
  (let ((resp (test-emcp--dispatch-parse
               `((jsonrpc . "2.0") (id . 30) (method . "tools/call")
                 (params . ((name . "nonexistent-tool-xyz")
                            (arguments . ((args . ["test"])))))))))
    (should (equal (alist-get 'jsonrpc resp) "2.0"))
    (should (equal (alist-get 'id resp) 30))))

;;; ---- Unknown method tests (converted from integration test) ----

(ert-deftest emcp-test-dispatch/unknown-method-error-32601 ()
  "Unknown method returns error code -32601. [D-4]"
  (test-emcp--ensure-tools-cache)
  (let ((resp (test-emcp--dispatch-parse
               '((jsonrpc . "2.0") (id . 40) (method . "unknown/method") (params . ())))))
    (should (equal (alist-get 'code (alist-get 'error resp)) -32601))))

(ert-deftest emcp-test-dispatch/unknown-method-message ()
  "Unknown method error message contains 'Method not found'. [D-4]"
  (test-emcp--ensure-tools-cache)
  (let ((resp (test-emcp--dispatch-parse
               '((jsonrpc . "2.0") (id . 41) (method . "foo") (params . ())))))
    (should (string-match-p "Method not found" (alist-get 'message (alist-get 'error resp))))))

;;; ---- Unicode tests (converted from integration test C-004) ----

(ert-deftest emcp-test-dispatch/unicode-upcase-accented ()
  "upcase preserves accented characters (cafe -> CAFE). [I-4 E-13]"
  (test-emcp--ensure-tools-cache)
  (let* ((resp (test-emcp--dispatch-parse
                `((jsonrpc . "2.0") (id . 50) (method . "tools/call")
                  (params . ((name . "upcase")
                             (arguments . ((args . ["caf\u00e9"]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (equal text "CAF\u00c9"))))

(ert-deftest emcp-test-dispatch/unicode-cjk-concat ()
  "CJK characters survive concat round-trip. [I-4 E-14]"
  (test-emcp--ensure-tools-cache)
  (let* ((resp (test-emcp--dispatch-parse
                `((jsonrpc . "2.0") (id . 51) (method . "tools/call")
                  (params . ((name . "concat")
                             (arguments . ((args . ["hello " "\u4e16\u754c"]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (string-prefix-p "hello" text))
    (should (string-match-p "\u4e16\u754c" text))))

(ert-deftest emcp-test-dispatch/unicode-emoji-concat ()
  "Emoji survives concat round-trip. [I-4 E-15]"
  (test-emcp--ensure-tools-cache)
  (let* ((resp (test-emcp--dispatch-parse
                `((jsonrpc . "2.0") (id . 52) (method . "tools/call")
                  (params . ((name . "concat")
                             (arguments . ((args . ["\U0001f680" " launch"]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (string-match-p "\U0001f680" text))))

;;; ---- ensure-multibyte helper tests ----

(ert-deftest emcp-test-ensure-multibyte/ascii ()
  "ASCII string passes through unchanged. [I-4]"
  (let ((s "hello"))
    (should (equal (emcp-stdio--ensure-multibyte s) s))))

(ert-deftest emcp-test-ensure-multibyte/multibyte-emoji ()
  "Multibyte emoji string passes through unchanged. [I-4]"
  (let ((s "hello \U0001F600"))
    (should (multibyte-string-p s))
    (should (equal (emcp-stdio--ensure-multibyte s) s))))

(ert-deftest emcp-test-ensure-multibyte/unibyte-utf8 ()
  "Unibyte UTF-8 bytes are decoded to multibyte. [I-4]"
  (let ((s (encode-coding-string "hello \U0001F600" 'utf-8)))
    (should-not (multibyte-string-p s))
    (let ((result (emcp-stdio--ensure-multibyte s)))
      (should (multibyte-string-p result))
      (should (equal result "hello \U0001F600")))))

(ert-deftest emcp-test-ensure-multibyte/non-string ()
  "Non-string values pass through unchanged. [I-4]"
  (should (equal (emcp-stdio--ensure-multibyte 42) 42))
  (should (equal (emcp-stdio--ensure-multibyte nil) nil)))

(ert-deftest emcp-test-ensure-multibyte/json-serialize-survives ()
  "json-serialize accepts the output of ensure-multibyte for emoji. [I-4]
This is the core regression test: without ensure-multibyte,
json-serialize rejects unibyte strings with bytes > 127."
  (let* ((raw (encode-coding-string "hello \U0001F60A" 'utf-8))
         (fixed (emcp-stdio--ensure-multibyte raw))
         (json (json-serialize `((text . ,fixed)))))
    (should (stringp json))
    (let ((parsed (json-parse-string json :object-type 'alist)))
      (should (equal (alist-get 'text parsed) "hello \U0001F60A")))))

;;; ---- emoji dispatch end-to-end tests ----

(ert-deftest emcp-test-dispatch/emoji-concat-smiley ()
  "concat with emoji smiley returns correct result. [I-4 E-15]"
  (test-emcp--ensure-tools-cache)
  (let* ((resp (test-emcp--dispatch-parse
                `((jsonrpc . "2.0") (id . 60) (method . "tools/call")
                  (params . ((name . "concat")
                             (arguments . ((args . ["hello " "\U0001F60A"]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (equal text "hello \U0001F60A"))))

(ert-deftest emcp-test-dispatch/emoji-concat-party ()
  "concat with party popper emoji returns correct result. [I-4 E-15]"
  (test-emcp--ensure-tools-cache)
  (let* ((resp (test-emcp--dispatch-parse
                `((jsonrpc . "2.0") (id . 61) (method . "tools/call")
                  (params . ((name . "concat")
                             (arguments . ((args . ["\U0001F389 party"]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (equal text "\U0001F389 party"))))

(ert-deftest emcp-test-dispatch/upcase-cafe ()
  "upcase with accented characters returns correct result. [I-4 E-13]"
  (test-emcp--ensure-tools-cache)
  (let* ((resp (test-emcp--dispatch-parse
                `((jsonrpc . "2.0") (id . 62) (method . "tools/call")
                  (params . ((name . "upcase")
                             (arguments . ((args . ["caf\u00e9"]))))))))
         (text (alist-get 'text (aref (alist-get 'content (alist-get 'result resp)) 0))))
    (should (equal text "CAF\u00c9"))))

;;; ---- tools/list content validation (converted from integration test) ----

(ert-deftest emcp-test-dispatch/tools-list-count-gte-20 ()
  "tools/list returns >= 20 tools. [E-17]"
  (test-emcp--ensure-tools-cache)
  (let* ((resp (test-emcp--dispatch-parse
                '((jsonrpc . "2.0") (id . 10) (method . "tools/list") (params . ()))))
         (tools (alist-get 'tools (alist-get 'result resp))))
    (should (>= (length tools) 20))))

(ert-deftest emcp-test-dispatch/tools-list-count-lt-5000 ()
  "tools/list returns < 5000 tools (sanity). [E-18]"
  (test-emcp--ensure-tools-cache)
  (let* ((resp (test-emcp--dispatch-parse
                '((jsonrpc . "2.0") (id . 10) (method . "tools/list") (params . ()))))
         (tools (alist-get 'tools (alist-get 'result resp))))
    (should (< (length tools) 5000))))

(ert-deftest emcp-test-dispatch/tools-list-known-functions ()
  "tools/list includes known text functions: string-trim, concat, format. [E-19]"
  (test-emcp--ensure-tools-cache)
  (let* ((resp (test-emcp--dispatch-parse
                '((jsonrpc . "2.0") (id . 10) (method . "tools/list") (params . ()))))
         (tools (alist-get 'tools (alist-get 'result resp)))
         (names (mapcar (lambda (t) (alist-get 'name t)) (append tools nil))))
    (should (member "string-trim" names))
    (should (member "concat" names))
    (should (member "format" names))))

(ert-deftest emcp-test-dispatch/tools-list-no-internals ()
  "tools/list does not expose emcp-stdio-* internal functions. [T-7]"
  (test-emcp--ensure-tools-cache)
  (let* ((resp (test-emcp--dispatch-parse
                '((jsonrpc . "2.0") (id . 10) (method . "tools/list") (params . ()))))
         (tools (alist-get 'tools (alist-get 'result resp)))
         (internal (seq-filter
                    (lambda (t)
                      (string-prefix-p "emcp-stdio-" (alist-get 'name t)))
                    (append tools nil))))
    (should (= (length internal) 0))))

;;; ---- Schema validation on sampled tools (from integration test) ----

(ert-deftest emcp-test-dispatch/tools-list-schema-structure ()
  "Sampled tools have correct schema: name, inputSchema.type=object, args.type=array. [T-3 T-4 T-8]"
  (test-emcp--ensure-tools-cache)
  (let* ((resp (test-emcp--dispatch-parse
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

;;; ---- Initialize handshake field values (from integration test) ----

(ert-deftest emcp-test-dispatch/initialize-server-name ()
  "Initialize serverInfo.name = 'emacs-mcp-elisp'. [D-8]"
  (test-emcp--ensure-tools-cache)
  (let* ((resp (test-emcp--dispatch-parse
                '((jsonrpc . "2.0") (id . 1) (method . "initialize") (params . ()))))
         (info (alist-get 'serverInfo (alist-get 'result resp))))
    (should (equal (alist-get 'name info) "emacs-mcp-elisp"))))

(ert-deftest emcp-test-dispatch/initialize-server-version ()
  "Initialize serverInfo.version = '0.1.0'. [D-9]"
  (test-emcp--ensure-tools-cache)
  (let* ((resp (test-emcp--dispatch-parse
                '((jsonrpc . "2.0") (id . 1) (method . "initialize") (params . ()))))
         (info (alist-get 'serverInfo (alist-get 'result resp))))
    (should (equal (alist-get 'version info) "0.1.0"))))

;;; ---- Notification handling (from integration test) ----

(ert-deftest emcp-test-dispatch/arbitrary-notification-silent ()
  "Arbitrary notification (no id) produces no output. [D-2]"
  (test-emcp--ensure-tools-cache)
  (let ((output (test-emcp--dispatch-capture
                 '((jsonrpc . "2.0") (method . "some/arbitrary/notification")))))
    (should (string-empty-p output))))

;;; ---- Daemon-absent tests (converted from test_daemon_layer.sh) ----

(ert-deftest emcp-test-daemon/no-daemon-tools-excluded ()
  "When daemon-available is nil, tools/list should not include daemon tools. [DL-1]"
  (test-emcp--ensure-tools-cache)
  (let ((emcp-stdio--daemon-available nil))
    ;; Rebuild cache without daemon tools
    (let* ((local-tools (append (emcp-stdio--collect-tools) nil))
           (emcp-stdio--tools-cache (apply #'vector local-tools)))
      (let* ((resp (test-emcp--dispatch-parse
                    '((jsonrpc . "2.0") (id . 1) (method . "tools/list") (params . ()))))
             (tools (alist-get 'tools (alist-get 'result resp)))
             (daemon-tools (seq-filter
                            (lambda (t)
                              (string-prefix-p "emcp-data-" (alist-get 'name t)))
                            (append tools nil))))
        (should (= (length daemon-tools) 0))))))

(ert-deftest emcp-test-daemon/no-daemon-tool-call-returns-error ()
  "Calling daemon tool when daemon-available is nil returns error in content. [DL-14 D-16]"
  (test-emcp--ensure-tools-cache)
  (let ((emcp-stdio--daemon-available nil))
    (let ((resp (test-emcp--dispatch-parse
                 `((jsonrpc . "2.0") (id . 1) (method . "tools/call")
                   (params . ((name . "emcp-data-eval")
                              (arguments . ((args . ["(emacs-version)"])))))))))
      (should resp)
      (let* ((content (alist-get 'content (alist-get 'result resp)))
             (text (alist-get 'text (aref content 0))))
        (should (string-match-p "error" text))))))

(ert-deftest emcp-test-daemon/server-responds-without-daemon ()
  "Server responds to initialize even when no daemon is available. [DL-15]"
  (test-emcp--ensure-tools-cache)
  (let ((emcp-stdio--daemon-available nil))
    (let ((resp (test-emcp--dispatch-parse
                 '((jsonrpc . "2.0") (id . 1) (method . "initialize") (params . ())))))
      (should resp)
      (should (alist-get 'protocolVersion (alist-get 'result resp))))))

(provide 'test-emcp-stdio)
;;; test-emcp-stdio.el ends here
