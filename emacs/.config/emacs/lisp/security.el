;;; security.el --- encrypted local credentials  -*- lexical-binding: t -*-

(defconst security-plstore-recipient "Emacs plstore")
(defconst security-plstore-identity "Emacs plstore <emacs@muefren.local>")

(setq plstore-encrypt-to (list security-plstore-recipient))
(with-eval-after-load 'oauth2
  (setq oauth2-token-file (no-littering-expand-var-file-name "oauth2.plstore")))

(defun security-plstore-key-available-p ()
  "Return non-nil when this machine has the local Plstore key."
  (and (executable-find "gpg")
       (with-temp-buffer
         (and (zerop (call-process "gpg" nil t nil "--batch" "--with-colons"
                                   "--list-keys" security-plstore-recipient))
              (re-search-forward "^pub:" nil t)))))

(defun security-ensure-plstore-key ()
  "Create this machine's local Plstore key after confirmation."
  (unless (security-plstore-key-available-p)
    (unless (executable-find "gpg")
      (user-error "GPG is required to save Spotify's refresh token"))
    (unless (yes-or-no-p "Create a local encryption key for Emacs credentials? ")
      (user-error "Spotify authorization cancelled: no local encryption key"))
    (with-temp-buffer
      (unless (zerop (call-process "gpg" nil t nil "--batch" "--passphrase" ""
                                   "--quick-gen-key" security-plstore-identity
                                   "default" "default" "never"))
        (user-error "Could not create the local encryption key: %s"
                    (string-trim (buffer-string)))))))
