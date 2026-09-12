;;; op.el --- shared 1Password secrets  -*- lexical-binding: t -*-

;; Named 1Password secrets, resolved once per Emacs session.

(defcustom op-account "my.1password.com"
  "1Password account used by the CLI."
  :type 'string)

(defcustom op-secret-references
  '((yarr-username
     . "op://Private/AE RSS/username")
    (yarr-password
     . "op://Private/AE RSS/password")
    (spotify-client-id
     . "op://Private/Spotify/Emacs Smudge Creds/Client ID")
    (spotify-client-secret
     . "op://Private/Spotify/Emacs Smudge Creds/Client Secret"))
  "Named 1Password references used by this Emacs configuration."
  :type '(alist :key-type symbol :value-type string))

(defvar op--cache (make-hash-table :test #'eq)
  "Resolved secret values for the current Emacs session.")

(defvar op--resolved nil
  "Non-nil after the registered references have been resolved.")

(defun op--resolve-secrets ()
  "Resolve all registered references in one `op inject' invocation."
  (let ((op-program (executable-find "op")))
    (unless op-program
      (user-error "1Password CLI (`op') is not available"))
    (let ((template-file (make-temp-file "emacs-op-template-"))
          (output (generate-new-buffer " *op-secrets*"))
          (error-file (make-temp-file "emacs-op-error-")))
      (unwind-protect
          (progn
            ;; `op inject' requires a template file. It contains references,
            ;; not resolved secret values.
            (with-temp-file template-file
              (dolist (entry op-secret-references)
                (insert (symbol-name (car entry))
                        "={{ " (cdr entry) " }}\n")))
            (let ((status
                   (call-process op-program nil
                                 (list output error-file) nil
                                 "--account" op-account "inject"
                                 "--in-file" template-file)))
              (unless (eq status 0)
                (with-temp-buffer
                  (insert-file-contents error-file)
                  (let ((detail (string-trim (buffer-string))))
                    (user-error "1Password could not resolve the registered secrets%s"
                                (if (string-empty-p detail)
                                    ""
                                  (format ": %s" detail))))))
              (with-current-buffer output
                (let ((resolved (buffer-string)))
                  (dolist (entry op-secret-references)
                    (let ((name (symbol-name (car entry))))
                      (when (string-match
                             (concat "^" (regexp-quote name) "=\\(.*\\)$")
                             resolved)
                        (puthash (car entry) (match-string 1 resolved) op--cache))))))
              (setq op--resolved t)))
        (kill-buffer output)
        (delete-file template-file)
        (delete-file error-file)))))

(defun op-secret (name)
  "Return the registered 1Password secret identified by NAME."
  (unless (assq name op-secret-references)
    (user-error "No 1Password reference registered for `%s'" name))
  (unless op--resolved
    (op--resolve-secrets))
  (or (gethash name op--cache)
      (user-error "1Password did not return the `%s' secret" name)))

(defun op-refresh-secrets ()
  "Forget cached 1Password values and resolve them again on next use."
  (interactive)
  (clrhash op--cache)
  (setq op--resolved nil)
  (message "1Password secret cache cleared"))
