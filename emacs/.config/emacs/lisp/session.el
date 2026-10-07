;;; session.el --- persistent editor state and server  -*- lexical-binding: t -*-

(use-package emacs
  :ensure nil
  :config
  (recentf-mode 1)
  (savehist-mode 1)
  (save-place-mode 1)
  (add-hook 'prog-mode-hook #'display-line-numbers-mode)
  (add-hook 'text-mode-hook #'display-line-numbers-mode)
  (add-hook 'text-mode-hook #'visual-line-mode))

(use-package ae-store
  :load-path "site-lisp/ae-store"
  :ensure nil
  :defer t
  :custom
  (ae-store-file (no-littering-expand-var-file-name "ae-store.sqlite")))

(use-package server
  :ensure nil
  :config
  (when-let* ((name (getenv "EMACS_SERVER_NAME")))
    (setq server-name name))
  (unless (server-running-p)
    (server-start)))
