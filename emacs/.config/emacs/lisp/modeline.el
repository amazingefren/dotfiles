;;; modeline.el --- a quiet text-only mode line  -*- lexical-binding: t -*-

(use-package doom-modeline
  :custom
  (doom-modeline-icon nil)   ; Berkeley Mono has no icon glyphs
  (doom-modeline-height 1)
  (doom-modeline-bar-width 3)
  (doom-modeline-buffer-file-name-style 'relative-to-project)
  (doom-modeline-buffer-encoding nil)
  (doom-modeline-minor-modes nil)
  (doom-modeline-modal t)
  (doom-modeline-modal-icon nil)
  (doom-modeline-persp-name t)
  (doom-modeline-display-default-persp-name t)
  (doom-modeline-vcs-max-length 24)
  (doom-modeline-check-simple-format t)
  (doom-modeline-env-version nil)
  (doom-modeline-workspace-name nil)
  (doom-modeline-time nil)
  :config
  (doom-modeline-mode 1))
