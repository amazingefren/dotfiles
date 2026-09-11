;;; defaults.el --- editor defaults, XDG dirs, font, macOS, secrets  -*- lexical-binding: t -*-

;; no-littering: many packages write state files (backups, history, caches)
;; into the config dir by default. This redirects all of them. Loaded first
;; so every later package sees the new paths.
(use-package no-littering
  :demand t                                  ; load now, not lazily
  :init
  (setq no-littering-etc-directory (expand-file-name "emacs/etc/" (xdg-data-home))   ; config-ish files
        no-littering-var-directory (expand-file-name "emacs/var/" (xdg-cache-home))) ; caches, history
  :config
  (no-littering-theme-backups))              ; also redirect backup~ and #autosave# files

;; GUI Emacs started from the Dock/Spotlight gets a bare PATH, not your zsh
;; one. This runs zsh once and copies PATH over, so mise-managed node/go/python
;; and language servers are found.
(use-package exec-path-from-shell
  :if (display-graphic-p)
  :config
  (exec-path-from-shell-initialize))

;; Redisplay performance.
(setq-default bidi-display-reordering 'left-to-right   ; no bidirectional text scanning...
              bidi-paragraph-direction 'left-to-right) ; ...code is left-to-right
(setq bidi-inhibit-bpa t)                              ; skip bracket-pair matching for bidi
(setq redisplay-skip-fontification-on-input t)         ; don't fontify while keys are pending
(setq-default cursor-in-non-selected-windows nil)      ; one cursor, in the active window only
(setq highlight-nonselected-windows nil)
(setq ffap-machine-p-known 'reject)                    ; find-file-at-point never pings hostnames

;; Encoding: UTF-8 with Unix line endings, everywhere, no guessing. Files that
;; already have another encoding keep it on save; this sets what new files
;; and undetectable ones get.
(set-language-environment "UTF-8")
(prefer-coding-system 'utf-8-unix)
(set-default-coding-systems 'utf-8-unix)
(set-terminal-coding-system 'utf-8)
(set-keyboard-coding-system 'utf-8)
(setq-default buffer-file-coding-system 'utf-8-unix)

;; Built-in settings. "emacs" as the package name is a convention for
;; grouping core settings in a use-package block; :ensure nil = nothing to install.
(use-package emacs
  :ensure nil
  :custom
  (use-short-answers t)                 ; y/n instead of yes/no
  (use-dialog-box nil)                  ; never use GUI popups for questions
  (ring-bell-function #'ignore)         ; no beep, no flash
  (create-lockfiles nil)                ; no .#file lock files
  (require-final-newline t)             ; files end with a newline on save
  (sentence-end-double-space nil)       ; one space after a period
  (indent-tabs-mode nil)                ; spaces, not tabs (editorconfig can override)
  (tab-always-indent 'complete)         ; TAB indents, then completes
  (display-line-numbers-type 'relative) ; relative line numbers like nvim
  (scroll-margin 4)                     ; like vim scrolloff
  (scroll-conservatively 101)           ; scroll one line at a time, never recenter
  (enable-recursive-minibuffers t)      ; allow commands inside the minibuffer
  (read-process-output-max (* 4 1024 1024)) ; bigger reads from subprocesses (faster LSP)
  (window-resize-pixelwise t)
  (frame-title-format "%b")             ; window title = buffer name
  ;; Symlinks: open the real file, not the link. ~/.config/emacs is a link into
  ;; ~/.dotfiles; without this, files opened through it look like they live
  ;; outside any git repo, so project search, magit, and the tree get it wrong.
  (find-file-visit-truename t)
  (vc-follow-symlinks t)                ; and never ask "follow symlink?"
  ;; Never leave Emacs by accident. s-q, C-x C-c, :qa and :wqa ask through this;
  ;; :qa! and :cq are covered separately below.
  (confirm-kill-emacs #'yes-or-no-p)
  :config
  (column-number-mode 1)                ; show column in modeline
  (global-auto-revert-mode 1)           ; reload files changed on disk
  (recentf-mode 1)                      ; track recent files (SPC f r)
  (savehist-mode 1)                     ; remember minibuffer history across restarts
  (save-place-mode 1)                   ; reopen files at the last cursor position
  (electric-pair-mode 1)                ; auto-close brackets and quotes
  (delete-selection-mode 1)             ; typing replaces the selection
  (pixel-scroll-precision-mode 1)       ; smooth trackpad scrolling
  ;; Trackpad momentum keeps sending wheel events after your fingers lift. If a
  ;; modifier is down by then, Emacs turns C-wheel into zoom. Wheel + modifier
  ;; does nothing now; zoom is s-= / s-- like every other Mac app.
  (setq mouse-wheel-scroll-amount '(1 ((shift) . hscroll)))
  (global-set-key (kbd "s-=") #'text-scale-increase)
  (global-set-key (kbd "s--") #'text-scale-decrease)
  (global-set-key (kbd "s-0") (lambda () (interactive) (text-scale-set 0)))
  (global-so-long-mode 1)               ; don't choke on files with huge lines
  (add-hook 'prog-mode-hook #'display-line-numbers-mode) ; line numbers in code...
  (add-hook 'text-mode-hook #'display-line-numbers-mode) ; ...and prose
  ;; Prose wraps at word boundaries instead of mid-word at the window edge, and
  ;; the little continuation arrows in the fringe are gone everywhere.
  (add-hook 'text-mode-hook #'visual-line-mode)
  (setf (alist-get 'continuation fringe-indicator-alist) nil)

  (set-face-attribute 'default nil :family "Berkeley Mono" :height 140) ; height is in 1/10 pt
  ;; Theme: see themes.el (SPC h r t picks one with live preview and remembers it).

  ;; macOS modifiers. Cmd = super so Cmd-C/V/Q/S keep their native meaning
  ;; (Emacs binds those itself). Option = Meta. Right Option stays a plain
  ;; Option so accented characters still type.
  (when (eq system-type 'darwin)
    (setq ns-command-modifier 'super
          ns-option-modifier 'meta
          ns-right-option-modifier 'none)))

;; Emacs server, so `emacsclient' works from any terminal.
(use-package server
  :ensure nil
  :config
  ;; EMACS_SERVER_NAME lets a second instance (tests, experiments) run its own
  ;; server instead of fighting the main one over the socket.
  (when-let* ((name (getenv "EMACS_SERVER_NAME"))) (setq server-name name))
  (unless (server-running-p) (server-start)))

;; Secrets come from 1Password, never from this repo.
;;   (secret-op "op://Vault/Item/field")
;; runs `op read' (Touch ID prompt the first time) and caches the value for
;; this Emacs session.
(defvar secret-op--cache (make-hash-table :test #'equal))
(defcustom secret-op-account "my.1password.com"
  "1Password account `secret-op' reads from."
  :type 'string)

(defun secret-op (reference)
  "Return the secret at 1Password REFERENCE (an op:// URI)."
  (or (gethash reference secret-op--cache)
      (with-temp-buffer
        (let ((code (call-process "op" nil t nil "read" "--account" secret-op-account reference)))
          (unless (eq code 0)
            (user-error "op read failed for %s: %s" reference (string-trim (buffer-string))))
          (puthash reference (string-trim (buffer-string)) secret-op--cache)))))

;; Tokens some packages persist (spot's Spotify refresh token, via plstore)
;; are GPG-encrypted at rest with a dedicated passphrase-less key, so nothing
;; ever prompts. Key created once with:
;;   gpg --batch --passphrase '' --quick-gen-key "Emacs plstore <emacs@muefren.local>" default default never
(setq plstore-encrypt-to '("Emacs plstore"))
(with-eval-after-load 'oauth2
  (setq oauth2-token-file (no-littering-expand-var-file-name "oauth2.plstore")))   ; not in the config repo

;; :qa! and :cq call `kill-emacs' directly, skipping `confirm-kill-emacs'.
;; Ask there too. The "!" still means "discard unsaved changes", it just no
;; longer means "and don't ask".
(with-eval-after-load 'evil
  (define-advice evil-quit-all (:around (orig &optional bang) confirm-quit)
    (if (and bang (not (yes-or-no-p "Quit Emacs and discard unsaved changes? ")))
        (message "Quit cancelled")
      (funcall orig bang)))
  (define-advice evil-quit-all-with-error-code (:around (orig &rest args) confirm-quit)
    (when (yes-or-no-p "Quit Emacs? ")
      (apply orig args))))

;; Respect .editorconfig files in projects. Built in since Emacs 30.
(use-package editorconfig
  :ensure nil
  :config
  (editorconfig-mode 1))
