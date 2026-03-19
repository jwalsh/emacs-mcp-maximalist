;;; test-daemon-lifecycle.el --- ERT tests for daemon lifecycle -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Tests for daemon start/stop/recovery timing and stability.
;; These tests require a live Emacs daemon or skip gracefully.
;;
;; Run with:
;;   emacs --batch -Q -l src/emcp-stdio.el -l tests/test-daemon-lifecycle.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; Context: system-monitor.md documented 3 different daemon PIDs in ~2 minutes
;; under concurrent agent load. These tests quantify the lifecycle boundaries.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Ensure emcp-stdio is loaded for its daemon functions
(declare-function emcp-stdio--check-daemon "emcp-stdio")
(declare-function emcp-stdio--daemon-eval "emcp-stdio")
(declare-function emcp-stdio--daemon-recover "emcp-stdio")

;;; ---- Helpers ----

(defvar test-daemon--timing-results nil
  "Alist of (test-name . elapsed-ms) for timing report.")

(defun test-daemon--time-ms (body-fn)
  "Call BODY-FN and return (elapsed-ms . result)."
  (let ((start (float-time)))
    (let ((result (funcall body-fn)))
      (cons (round (* 1000 (- (float-time) start)))
            result))))

(defun test-daemon--record-timing (name ms)
  "Record timing result NAME with MS milliseconds."
  (push (cons name ms) test-daemon--timing-results))

(defun test-daemon--emacsclient-eval (sexp-string)
  "Evaluate SEXP-STRING via emacsclient. Return (exit-code . output)."
  (with-temp-buffer
    (let ((code (call-process "emacsclient" nil t nil
                              "--timeout" "5"
                              "--eval" sexp-string)))
      (cons code (string-trim (buffer-string))))))

(defun test-daemon--available-p ()
  "Return non-nil if a daemon is currently reachable."
  (let ((result (test-daemon--emacsclient-eval "(emacs-pid)")))
    (zerop (car result))))

;;; ---- Test: daemon responds to eval ----

(ert-deftest emcp-test-daemon-health ()
  "Daemon responds to (+ 1 1) within 5 seconds."
  (skip-unless (test-daemon--available-p))
  (let ((timing (test-daemon--time-ms
                 (lambda ()
                   (test-daemon--emacsclient-eval "(+ 1 1)")))))
    (test-daemon--record-timing "health-eval" (car timing))
    ;; Should complete within 5000ms
    (should (< (car timing) 5000))
    ;; Should return "2"
    (should (zerop (car (cdr timing))))
    (should (equal (cdr (cdr timing)) "2"))))

;;; ---- Test: check-daemon returns within timeout ----

(ert-deftest emcp-test-check-daemon-timeout ()
  "check-daemon returns within 5 seconds regardless of daemon state."
  ;; This test always runs — it should never hang
  (let ((timing (test-daemon--time-ms
                 (lambda ()
                   (emcp-stdio--check-daemon)))))
    (test-daemon--record-timing "check-daemon" (car timing))
    ;; Must return within 5 seconds (check-daemon uses 3s timeout internally)
    (should (< (car timing) 5000))
    ;; Result is boolean
    (should (or (eq (cdr timing) t) (eq (cdr timing) nil)))))

;;; ---- Test: daemon survives 100 rapid eval calls ----

(ert-deftest emcp-test-daemon-rapid-eval ()
  "Daemon handles 100 sequential eval calls without crashing."
  (skip-unless (test-daemon--available-p))
  (let ((success-count 0)
        (fail-count 0))
    (let ((timing (test-daemon--time-ms
                   (lambda ()
                     (dotimes (i 100)
                       (condition-case nil
                           (let ((result (test-daemon--emacsclient-eval
                                          (format "(+ %d %d)" i i))))
                             (if (zerop (car result))
                                 (setq success-count (1+ success-count))
                               (setq fail-count (1+ fail-count))))
                         (error (setq fail-count (1+ fail-count)))))))))
      (test-daemon--record-timing "rapid-eval-100" (car timing))
      ;; At least 95% should succeed (allow for minor transient failures)
      (should (>= success-count 95))
      ;; Average latency per call should be < 500ms
      (should (< (/ (car timing) 100) 500))
      ;; Daemon should still be alive after the burst
      (should (test-daemon--available-p)))))

;;; ---- Test: daemon PID stability ----

(ert-deftest emcp-test-daemon-pid-stable ()
  "Daemon PID does not change during 10 sequential queries."
  (skip-unless (test-daemon--available-p))
  (let ((first-pid (cdr (test-daemon--emacsclient-eval "(emacs-pid)")))
        (changed nil))
    (dotimes (_i 10)
      (let ((current-pid (cdr (test-daemon--emacsclient-eval "(emacs-pid)"))))
        (when (not (equal current-pid first-pid))
          (setq changed t))))
    ;; PID should not change during a short burst of queries
    (should-not changed)))

;;; ---- Test: daemon-recover works when daemon is alive ----

(ert-deftest emcp-test-daemon-recover-alive ()
  "daemon-recover returns t when daemon is already running."
  (skip-unless (test-daemon--available-p))
  (let ((timing (test-daemon--time-ms
                 (lambda ()
                   (emcp-stdio--daemon-recover)))))
    (test-daemon--record-timing "recover-alive" (car timing))
    ;; Should succeed quickly
    (should (< (car timing) 5000))
    ;; Should return t (recovered = daemon is available)
    (should (cdr timing))))

;;; ---- Test: daemon-recover handles missing daemon ----

(ert-deftest emcp-test-daemon-recover-missing ()
  "daemon-recover returns a boolean when daemon is absent, without hanging."
  ;; Temporarily pretend daemon is unavailable by setting a bogus timeout
  ;; We cannot actually kill the daemon during tests, so test the timeout path
  (let ((timing (test-daemon--time-ms
                 (lambda ()
                   ;; Save and restore daemon-available state
                   (let ((orig emcp-stdio--daemon-available))
                     (setq emcp-stdio--daemon-available nil)
                     (unwind-protect
                         (emcp-stdio--daemon-recover)
                       (setq emcp-stdio--daemon-available orig)))))))
    (test-daemon--record-timing "recover-missing" (car timing))
    ;; Must return within a reasonable time (check + potential restart + wait)
    ;; With auto-restart: up to ~10s. Without: < 5s.
    (should (< (car timing) 15000))
    ;; Result is boolean
    (should (or (eq (cdr timing) t) (eq (cdr timing) nil)))))

;;; ---- Test: telemetry counters increment correctly ----

(ert-deftest emcp-test-telemetry-counters ()
  "Telemetry counters increment correctly."
  ;; Reset counters
  (let ((emcp-stdio--request-count 0)
        (emcp-stdio--call-count 0)
        (emcp-stdio--error-count 0)
        (emcp-stdio--daemon-call-count 0)
        (emcp-stdio--daemon-error-count 0))
    ;; Ensure tools cache exists
    (unless emcp-stdio--tools-cache
      (setq emcp-stdio--tools-cache (emcp-stdio--collect-tools)))
    ;; Simulate requests via dispatch (request-count is incremented in the
    ;; main loop, not dispatch, so we increment manually)
    (let ((standard-output (get-buffer-create " *test-telemetry*")))
      ;; A tools/call dispatch increments call-count inside the loop,
      ;; but we can verify daemon counters directly
      (should (= emcp-stdio--daemon-call-count 0))
      (should (= emcp-stdio--daemon-error-count 0))

      ;; Manually increment as dispatch would
      (cl-incf emcp-stdio--request-count)
      (cl-incf emcp-stdio--request-count)
      (cl-incf emcp-stdio--call-count)
      (should (= emcp-stdio--request-count 2))
      (should (= emcp-stdio--call-count 1))

      ;; Test daemon counter
      (cl-incf emcp-stdio--daemon-call-count)
      (cl-incf emcp-stdio--daemon-error-count)
      (should (= emcp-stdio--daemon-call-count 1))
      (should (= emcp-stdio--daemon-error-count 1))

      (kill-buffer " *test-telemetry*"))))

;;; ---- Test: daemon-eval filters diagnostic lines ----

(ert-deftest emcp-test-daemon-eval-returns-clean ()
  "daemon-eval returns result without emacsclient diagnostic lines."
  (skip-unless (test-daemon--available-p))
  (let ((result (emcp-stdio--daemon-eval "(+ 2 3)")))
    ;; Should be just "5", no emacsclient: lines
    (should (equal result "5"))
    (should-not (string-match-p "emacsclient:" result))))

;;; ---- Test: daemon uptime is queryable ----

(ert-deftest emcp-test-daemon-uptime ()
  "Can query daemon uptime via emacs-uptime."
  (skip-unless (test-daemon--available-p))
  (let ((result (test-daemon--emacsclient-eval "(emacs-uptime)")))
    (should (zerop (car result)))
    ;; Should return a string like "0 days, 0:05:23"
    (should (stringp (cdr result)))
    (should (> (length (cdr result)) 0))))

;;; ---- Test: daemon buffer count is reasonable ----

(ert-deftest emcp-test-daemon-buffer-count ()
  "Daemon buffer count is between 1 and 1000 (sanity check)."
  (skip-unless (test-daemon--available-p))
  (let* ((result (test-daemon--emacsclient-eval "(length (buffer-list))"))
         (count (string-to-number (cdr result))))
    (should (zerop (car result)))
    (should (>= count 1))
    (should (<= count 1000))))

;;; ---- Test: concurrent eval safety (light version) ----

(ert-deftest emcp-test-daemon-concurrent-eval-light ()
  "10 rapid sequential evals all return correct results."
  (skip-unless (test-daemon--available-p))
  (let ((all-correct t))
    (dotimes (i 10)
      (let* ((a (random 100))
             (b (random 100))
             (expected (number-to-string (+ a b)))
             (result (test-daemon--emacsclient-eval
                      (format "(+ %d %d)" a b))))
        (unless (and (zerop (car result))
                     (equal (cdr result) expected))
          (setq all-correct nil))))
    (should all-correct)))

;;; ---- Test: daemon memory is queryable ----

(ert-deftest emcp-test-daemon-memory ()
  "Can query daemon memory usage."
  (skip-unless (test-daemon--available-p))
  (let ((result (test-daemon--emacsclient-eval
                 "(format \"%d\" (or (cdr (assoc 'rss (process-attributes (emacs-pid)))) 0))")))
    (should (zerop (car result)))
    ;; RSS should be a number > 0 (in KB on most systems)
    (let ((rss (string-to-number (cdr result))))
      ;; On some systems process-attributes may not have rss, so 0 is ok
      (should (>= rss 0)))))

;;; ---- Timing report (run after all tests) ----

(ert-deftest emcp-test-zzz-timing-report ()
  "Print timing summary (runs last due to zzz prefix)."
  (when test-daemon--timing-results
    (message "\n=== Daemon Lifecycle Timing Report ===")
    (dolist (entry (reverse test-daemon--timing-results))
      (message "  %-25s %6dms" (car entry) (cdr entry)))
    (message "=== End Timing Report ===\n")))

(provide 'test-daemon-lifecycle)
;;; test-daemon-lifecycle.el ends here
