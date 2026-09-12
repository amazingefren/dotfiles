;;; defaults.el --- universal Emacs defaults  -*- lexical-binding: t -*-

(use-package no-littering
  :demand t
  :init
  (setq no-littering-etc-directory (expand-file-name "emacs/etc/" (xdg-data-home))
        no-littering-var-directory (expand-file-name "emacs/var/" (xdg-cache-home)))
  :config
  (no-littering-theme-backups))

;; Keep redisplay responsive in large source files.
(setq-default bidi-display-reordering 'left-to-right
              bidi-paragraph-direction 'left-to-right
              cursor-in-non-selected-windows nil)
(setq bidi-inhibit-bpa t
      redisplay-skip-fontification-on-input t
      highlight-nonselected-windows nil
      ffap-machine-p-known 'reject)

;; Use UTF-8 and Unix line endings for new files.
(set-language-environment "UTF-8")
(prefer-coding-system 'utf-8-unix)
(set-default-coding-systems 'utf-8-unix)
(set-terminal-coding-system 'utf-8)
(set-keyboard-coding-system 'utf-8)
(setq-default buffer-file-coding-system 'utf-8-unix)

(use-package emacs
  :ensure nil
  :custom
  (use-short-answers t)
  (use-dialog-box nil)
  (ring-bell-function #'ignore)
  (create-lockfiles nil)
  (require-final-newline t)
  (sentence-end-double-space nil)
  (tab-always-indent 'complete)
  (display-line-numbers-type 'relative)
  (scroll-margin 4)
  (scroll-conservatively 101)
  (enable-recursive-minibuffers t)
  (read-process-output-max (* 4 1024 1024))
  (window-resize-pixelwise t)
  (frame-title-format "%b")
  (find-file-visit-truename t)
  (vc-follow-symlinks t)
  (confirm-kill-emacs #'yes-or-no-p)
  :config
  (column-number-mode 1)
  (global-auto-revert-mode 1)
  (global-so-long-mode 1)
  (setq mouse-wheel-scroll-amount '(1 ((shift) . hscroll)))
  (setf (alist-get 'continuation fringe-indicator-alist) nil))
