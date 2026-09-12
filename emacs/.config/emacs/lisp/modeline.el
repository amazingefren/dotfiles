;;; modeline.el --- a quiet text-only mode line  -*- lexical-binding: t -*-

(use-package doom-modeline
  :custom
  (doom-modeline-icon nil)                          ; plain text; Berkeley Mono has no icon glyphs
  (doom-modeline-height 1)                          ; as short as the font allows
  (doom-modeline-bar-width 3)
  (doom-modeline-buffer-file-name-style 'relative-to-project)
  (doom-modeline-buffer-encoding nil)               ; everything is utf-8-unix; say nothing
  (doom-modeline-minor-modes nil)
  (doom-modeline-modal t)                           ; evil state, e.g. NORMAL
  (doom-modeline-modal-icon nil)
  (doom-modeline-persp-name t)                      ; current workspace
  (doom-modeline-display-default-persp-name t)
  (doom-modeline-vcs-max-length 24)
  (doom-modeline-check-simple-format t)             ; "2 errors" instead of per-type icons
  (doom-modeline-env-version nil)
  (doom-modeline-workspace-name nil)                ; that's the tab bar's job
  (doom-modeline-time nil)
  :config
  (doom-modeline-mode 1))
