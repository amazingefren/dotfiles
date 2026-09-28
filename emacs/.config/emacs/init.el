;;; init.el --- entry point, loaded after early-init.el  -*- lexical-binding: t -*-

(require 'package)
(setq package-archives '(("gnu"    . "https://elpa.gnu.org/packages/")
                         ("nongnu" . "https://elpa.nongnu.org/nongnu/")
                         ("melpa"  . "https://melpa.org/packages/"))
      package-archive-priorities '(("gnu" . 2) ("nongnu" . 1) ("melpa" . 0))
      package-install-upgrade-built-in t)

(require 'use-package)
(setq use-package-always-ensure t
      use-package-enable-imenu-support t)

(setq custom-file (expand-file-name "emacs/custom.el" (xdg-cache-home)))
(load custom-file 'noerror 'nomessage)

;; lisp/ is deliberately not on load-path, so vim.el or git.el can't shadow a package.
(dolist (file '("defaults" "packages" "environment" "session" "security" "editing" "op"
                "themes" "modeline" "vim" "pickers" "workspaces" "browser" "writing" "lang"
                "git" "feeds" "tree" "terminal" "windows" "music" "ai-review" "ai-intelligence" "laya" "mcp" "agents" "home"))
  (load (expand-file-name (concat "lisp/" file) user-emacs-directory) nil 'nomessage))
