;;; init.el --- entry point, loaded after early-init.el  -*- lexical-binding: t -*-

;; Package manager: the built-in package.el.
;; Archives to pull from, and which wins when the same package is in several
;; (higher priority wins). MELPA has the most packages, GNU/NonGNU are curated.
(require 'package)
(setq package-archives '(("gnu"    . "https://elpa.gnu.org/packages/")
                         ("nongnu" . "https://elpa.nongnu.org/nongnu/")
                         ("melpa"  . "https://melpa.org/packages/"))
      package-archive-priorities '(("gnu" . 2) ("nongnu" . 1) ("melpa" . 0))
      ;; Allow upgrading packages that ship with Emacs (eglot, org, ...).
      package-install-upgrade-built-in t)

;; use-package: the macro every package block below is written with. It
;; groups install + settings + keybinds per package.
(require 'use-package)
(setq use-package-always-ensure t            ; auto-install anything not present (:ensure nil opts out)
      use-package-enable-imenu-support t)    ; jump between use-package blocks with imenu

;; Anything set via M-x customize goes to the cache, not into this repo.
;; Real settings belong in lisp/.
(setq custom-file (expand-file-name "emacs/custom.el" (xdg-cache-home)))
(load custom-file 'noerror 'nomessage)

;; Load each module in lisp/ in this order. They are loaded by file path and
;; lisp/ is deliberately NOT on load-path, so a file called vim.el or git.el
;; can never shadow a real package with that name. To add a module, add a
;; file and put its name in this list.
(dolist (file '("defaults" "packages" "environment" "session" "security" "editing" "op"
                "themes" "modeline" "vim" "pickers" "workspaces" "browser" "writing" "lang"
                "git" "feeds" "tree" "terminal" "windows" "music" "ai-review" "ai-intelligence" "mcp" "agents" "home"))
  (load (expand-file-name (concat "lisp/" file) user-emacs-directory) nil 'nomessage))
