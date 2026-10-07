;;; chrome.el --- AE editor chrome -*- lexical-binding: t -*-

(use-package ae-chrome
  :load-path "site-lisp"
  :ensure nil
  :demand t
  :config
  (setq window-divider-default-places 'right-only
        window-divider-default-right-width 8)
  (window-divider-mode 1)
  (ae-chrome-mode 1))
