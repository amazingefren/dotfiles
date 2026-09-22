;;; early-init.el --- runs before the GUI frame and before packages load  -*- lexical-binding: t -*-

;; Speed up startup: disable garbage collection while loading, then set a
;; sane 32MB threshold once everything is up.
(setq gc-cons-threshold most-positive-fixnum)
(add-hook 'emacs-startup-hook
          (lambda () (setq gc-cons-threshold (* 32 1024 1024))))

;; XDG paths. Keep ~/.config/emacs for config only:
;;   native-compiled files -> ~/.cache/emacs/eln-cache
;;   installed packages    -> ~/.local/share/emacs/elpa
(require 'xdg)
(startup-redirect-eln-cache (expand-file-name "emacs/eln-cache/" (xdg-cache-home)))
(setq package-user-dir (expand-file-name "emacs/elpa/" (xdg-data-home)))
;; Show warnings and errors from asynchronous native compilation in
;; `*Warnings*'. The detailed compiler output is available in
;; `*Native-compile-Log*'.
(setq native-comp-async-report-warnings-errors t)

;; Some packages' autoload files define transient menus at load time, so
;; transient (bundled with Emacs) must be loaded before packages activate.
(require 'transient)

;; Start in the home directory, not wherever Finder launched the app from
;; (which is inside /opt/homebrew for a brew-installed Emacs.app).
(setq default-directory "~/"
      command-line-default-directory "~/")

;; Frame appearance, set here so the first frame is drawn correctly instead
;; of flashing the defaults first.
(setq inhibit-startup-screen t
      inhibit-startup-echo-area-message user-login-name ; no "For information about GNU Emacs..."
      frame-inhibit-implied-resize t                    ; don't resize frame when font/UI changes
      frame-resize-pixelwise t)                         ; resize by pixel, not by character
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(vertical-scroll-bars) default-frame-alist)
(push '(width . 140) default-frame-alist)               ; initial size in characters
(push '(height . 50) default-frame-alist)

(setq gc-cons-threshold most-positive-fixnum
      gc-cons-percentage 0.5)
(add-hook 'emacs-startup-hook
	  (lambda () (setq gc-cons-threshold 800000)))

;; Use Emacs' own fullscreen
(setq ns-use-native-fullscreen nil)
