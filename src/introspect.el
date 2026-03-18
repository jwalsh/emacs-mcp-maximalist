;;; introspect.el --- Walk obarray and emit MCP tool manifest -*- lexical-binding: t -*-
;;
;; Usage:
;;   emacsclient --eval "(load-file \"src/introspect.el\")"
;;   emacsclient --eval "(emcp-write-manifest \"emacs-functions.json\")"
;;   emacsclient --eval "(emcp-write-manifest-compact \"functions-compact.jsonl\")"

(require 'cl-lib)
(require 'json)

(defun emcp--classify (sym)
  "Return category string for SYM based on naming convention."
  (let ((name (symbol-name sym)))
    (cond
     ((string-prefix-p "string-"   name) "string")
     ((string-prefix-p "buffer-"   name) "buffer")
     ((string-prefix-p "file-"     name) "file")
     ((string-prefix-p "org-"      name) "org")
     ((string-prefix-p "replace-"  name) "regexp")
     ((string-prefix-p "regexp-"   name) "regexp")
     ((string-prefix-p "format"    name) "format")
     (t                                  "misc"))))

(defun emcp--text-arg-p (sym)
  "Return non-nil if SYM's arglist suggests text consumption."
  (when (fboundp sym)
    (condition-case nil
        (let* ((arglist (help-function-arglist sym t))
               ;; Filter to symbols only — arglist can contain integers,
               ;; vectors, or other non-symbol elements for some builtins.
               (symbols (cl-remove-if-not #'symbolp arglist))
               (arg-names (mapcar (lambda (a)
                                    (downcase (symbol-name a)))
                                  (cl-remove-if (lambda (a)
                                                  (memq a '(&optional &rest &key)))
                                                symbols))))
          (cl-some (lambda (n)
                     (string-match-p
                      "\\(string\\|str\\|text\\|buffer\\|object\\|obj\\|seq\\|sequence\\)"
                      n))
                   arg-names))
      (error nil))))

(defun emcp--safe-docstring (sym)
  "Return first line of SYM's docstring, or nil."
  (when-let* ((doc (ignore-errors (documentation sym t))))
    (car (split-string doc "\n"))))

(defun emcp-build-manifest ()
  "Return manifest as a list of alists suitable for json-encode."
  (let (results)
    (mapatoms
     (lambda (sym)
       (when (and (fboundp sym)
                  (not (string-match-p "--" (symbol-name sym)))
                  (emcp--text-arg-p sym))
         (let ((doc (emcp--safe-docstring sym)))
           (when doc
             (push `((name     . ,(symbol-name sym))
                     (docstring . ,doc)
                     (arglist  . ,(format "%S"
                                   (help-function-arglist sym t)))
                     (category . ,(emcp--classify sym)))
                   results)))))
     obarray)
    (nreverse results)))

(defun emcp-write-manifest (path)
  "Write manifest JSON to PATH. Returns count of functions written."
  (let* ((manifest (emcp-build-manifest))
         (count    (length manifest))
         (payload  `((functions  . ,(vconcat manifest))
                     (statistics . ((total      . ,count)
                                    (generated  . ,(format-time-string "%Y-%m-%dT%T%z")))))))
    (with-temp-file path
      (insert (json-encode payload)))
    (message "emcp: wrote %d functions to %s" count path)
    count))

(defun emcp-write-manifest-compact (path)
  "Write compact JSONL manifest to PATH.
Each line is a JSON object with keys: n (name), s (arglist), d (docstring).
Returns count of functions written."
  (let* ((manifest (emcp-build-manifest))
         (count    (length manifest)))
    (with-temp-file path
      (dolist (entry manifest)
        (let* ((name     (alist-get 'name entry))
               (arglist  (alist-get 'arglist entry))
               (doc      (alist-get 'docstring entry))
               ;; Truncate docstring to ~60 chars for compactness
               (doc-short (if (> (length doc) 60)
                              (concat (substring doc 0 57) "...")
                            doc))
               (compact  `((n . ,name)
                           (s . ,arglist)
                           (d . ,doc-short))))
          (insert (json-encode compact))
          (insert "\n"))))
    (message "emcp: wrote %d functions (compact JSONL) to %s" count path)
    count))

(defvar emcp-core-categories '("string" "format" "regexp")
  "Categories included in the core manifest.")

(defun emcp-write-manifest-core (path)
  "Write core JSONL manifest to PATH.
Includes only categories in `emcp-core-categories'.
Returns count of functions written."
  (let* ((manifest (emcp-build-manifest))
         (core (cl-remove-if-not
                (lambda (entry)
                  (member (alist-get 'category entry) emcp-core-categories))
                manifest))
         (count (length core)))
    (with-temp-file path
      (dolist (entry core)
        (let* ((name     (alist-get 'name entry))
               (arglist  (alist-get 'arglist entry))
               (doc      (alist-get 'docstring entry))
               (doc-short (if (> (length doc) 60)
                              (concat (substring doc 0 57) "...")
                            doc))
               (compact  `((n . ,name)
                           (s . ,arglist)
                           (d . ,doc-short))))
          (insert (json-encode compact))
          (insert "\n"))))
    (message "emcp: wrote %d core functions to %s" count path)
    count))

(provide 'emcp-introspect)
;;; introspect.el ends here
