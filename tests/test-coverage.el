;;; test-coverage.el --- Function-level coverage tracking for emcp-stdio -*- lexical-binding: t -*-

;;; Contract traceability:
;;
;; This file is a coverage instrumentation tool, not a test file.
;; It does not directly validate contract invariants.
;; It measures which emcp-stdio-* functions are exercised by other test files.

;;; Commentary:
;;
;; Instruments every `emcp-stdio-*' defun with :before advice that records
;; whether the function was called during the ERT test run.  After tests
;; complete, prints a coverage report to stderr showing which functions
;; were hit and which were missed.
;;
;; Usage:
;;   emacs --batch -Q -l src/emcp-stdio.el \
;;         -l tests/test-coverage.el \
;;         -f emcp-coverage-run
;;
;; The exit code mirrors ert-run-tests-batch-and-exit: 0 if all tests
;; pass, 1 otherwise.  Coverage data is purely informational and does
;; not affect the exit code.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; ---- Coverage state ----

(defvar emcp-coverage--all-fns nil
  "List of function name strings found in src/emcp-stdio.el.")

(defvar emcp-coverage--called (make-hash-table :test 'equal)
  "Hash table: function-name-string -> call count.")

(defvar emcp-coverage--source-file "src/emcp-stdio.el"
  "Relative path to the source file under test.")

;; ---- Collect defun names from source ----

(defun emcp-coverage--collect-defuns ()
  "Parse `emcp-coverage--source-file' and return a list of defun name strings.
Only collects names matching `emcp-stdio-' prefix."
  (let ((fns nil)
        (file (expand-file-name emcp-coverage--source-file
                                (or (getenv "PROJECT_ROOT")
                                    default-directory))))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (re-search-forward
              "^(defun \\(emcp-stdio[^ \t\n]+\\)" nil t)
        (push (match-string 1) fns)))
    (nreverse fns)))

;; ---- Instrument / de-instrument ----

(defun emcp-coverage--instrument ()
  "Add :before advice to every function in `emcp-coverage--all-fns'.
Each advice increments the call count in `emcp-coverage--called'."
  (dolist (fn-name emcp-coverage--all-fns)
    (let ((sym (intern fn-name)))
      (when (fboundp sym)
        ;; Use a closure capturing fn-name
        (let ((tracker (lambda (&rest _args)
                         (let ((cur (gethash fn-name emcp-coverage--called 0)))
                           (puthash fn-name (1+ cur) emcp-coverage--called)))))
          (advice-add sym :before tracker
                      `((name . ,(intern (concat "coverage-tracker--" fn-name))))))))))

(defun emcp-coverage--remove-advice ()
  "Remove all coverage-tracker advice."
  (dolist (fn-name emcp-coverage--all-fns)
    (let ((sym (intern fn-name))
          (advice-name (intern (concat "coverage-tracker--" fn-name))))
      (when (fboundp sym)
        (advice-remove sym advice-name)))))

;; ---- Reporting ----

(defun emcp-coverage--report ()
  "Print a coverage report to stderr.
Returns a plist (:covered N :missed N :total N :percent F :missed-fns LIST)."
  (let ((covered 0)
        (missed 0)
        (missed-fns nil)
        (total (length emcp-coverage--all-fns)))
    (message "")
    (message "============================================================")
    (message "  FUNCTION COVERAGE REPORT: %s" emcp-coverage--source-file)
    (message "============================================================")
    (message "")
    ;; Sort: covered first, then missed
    (let ((sorted (sort (copy-sequence emcp-coverage--all-fns)
                        (lambda (a b)
                          (let ((ca (gethash a emcp-coverage--called 0))
                                (cb (gethash b emcp-coverage--called 0)))
                            (cond
                             ;; Both covered or both missed: alphabetical
                             ((and (> ca 0) (> cb 0)) (string< a b))
                             ((and (= ca 0) (= cb 0)) (string< a b))
                             ;; Covered before missed
                             (t (> ca 0))))))))
      (dolist (fn-name sorted)
        (let ((count (gethash fn-name emcp-coverage--called 0)))
          (if (> count 0)
              (progn
                (cl-incf covered)
                (message "  COVERED  (%3d calls): %s" count fn-name))
            (cl-incf missed)
            (push fn-name missed-fns)
            (message "  MISSED   (  0 calls): %s" fn-name)))))
    (let ((pct (if (> total 0)
                   (* 100.0 (/ (float covered) total))
                 0.0)))
      (message "")
      (message "------------------------------------------------------------")
      (message "  Coverage: %d/%d functions (%.1f%%)" covered total pct)
      (message "  Covered:  %d" covered)
      (message "  Missed:   %d" missed)
      (message "------------------------------------------------------------")
      (when missed-fns
        (message "")
        (message "  Functions with ZERO test coverage:")
        (dolist (fn (nreverse missed-fns))
          (message "    - %s" fn)))
      (message "")
      (list :covered covered :missed missed :total total
            :percent pct :missed-fns (nreverse missed-fns)))))

;; ---- Main entry point ----

(defun emcp-coverage-run ()
  "Load all test files, instrument source, run tests, report coverage.
Exits with code 0 if all tests pass, 1 otherwise."
  ;; Discover defuns
  (setq emcp-coverage--all-fns (emcp-coverage--collect-defuns))
  (message "%s: found %d functions to track"
           emcp-coverage--source-file (length emcp-coverage--all-fns))

  ;; Load test files
  (let ((test-dir (expand-file-name
                   "tests/"
                   (or (getenv "PROJECT_ROOT") default-directory))))
    (dolist (file '("test-emcp-stdio.el"
                    "test_io_layer.el"
                    "test_sexp_construction.el"
                    "test-integration.el"))
      (let ((path (expand-file-name file test-dir)))
        (when (file-exists-p path)
          (load path nil t)
          (message "  loaded: %s" file)))))

  ;; Instrument
  (emcp-coverage--instrument)
  (message "  instrumented %d functions" (length emcp-coverage--all-fns))

  ;; Run tests (capture pass/fail)
  (let ((test-result nil))
    (condition-case err
        (progn
          (ert-run-tests-batch)
          (setq test-result t))
      (error
       (message "Test runner error: %s" (error-message-string err))
       (setq test-result nil)))

    ;; Remove advice before reporting
    (emcp-coverage--remove-advice)

    ;; Report
    (emcp-coverage--report)

    ;; Exit
    (kill-emacs (if test-result 0 1))))

(provide 'test-coverage)
;;; test-coverage.el ends here
