;;; publish.el --- Export org files to derived formats -*- lexical-binding: t -*-
;;
;; Usage:
;;   emacsclient -l lisp/publish.el
;;   emacsclient --eval '(emcp-publish-readme)'
;;
;; Or from Makefile:
;;   gmake sync

(require 'ox-md)

(defun emcp-publish-readme ()
  "Export README.org to README.md for GitHub/uv consumption."
  (let ((org-file (expand-file-name "README.org" default-directory))
        (md-file (expand-file-name "README.md" default-directory)))
    (with-current-buffer (find-file-noselect org-file)
      (org-export-to-file 'md md-file nil nil nil nil nil)
      (kill-buffer))
    (message "emcp: published %s → %s" org-file md-file)
    md-file))

(defun emcp-publish-all ()
  "Export all publishable org files."
  (emcp-publish-readme)
  (message "emcp: all published"))

(provide 'publish)
;;; publish.el ends here
