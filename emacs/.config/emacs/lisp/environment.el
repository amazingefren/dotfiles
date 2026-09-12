;;; environment.el --- macOS environment and appearance  -*- lexical-binding: t -*-

;; Import the shell PATH before packages look for executables.
(use-package exec-path-from-shell
  :if (eq system-type 'darwin)
  :demand t
  :custom
  (exec-path-from-shell-shell-name "/bin/zsh")
  :config
  (exec-path-from-shell-initialize))

(set-face-attribute 'default nil :family "Berkeley Mono" :height 140)

(when (eq system-type 'darwin)
  (setq ns-command-modifier 'super
        ns-option-modifier 'meta
        ns-right-option-modifier 'none))
