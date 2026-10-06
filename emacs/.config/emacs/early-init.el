;;; early-init.el --- runs before the GUI frame and before packages load  -*- lexical-binding: t -*-

;; A collection pauses Emacs ~60ms, so collect rarely and when idle.
(setq gc-cons-threshold most-positive-fixnum)
(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 128 1024 1024))
            (run-with-idle-timer 15 t #'garbage-collect)))

(require 'xdg)
(startup-redirect-eln-cache (expand-file-name "emacs/eln-cache/" (xdg-cache-home)))
(setq package-user-dir (expand-file-name "emacs/elpa/" (xdg-data-home)))
(setq native-comp-async-report-warnings-errors t)

;; Finder launches a brew-installed Emacs.app inside /opt/homebrew.
(setq default-directory "~/"
      command-line-default-directory "~/")

(setq inhibit-startup-screen t
      inhibit-startup-echo-area-message user-login-name
      frame-inhibit-implied-resize t
      frame-resize-pixelwise t)
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(vertical-scroll-bars) default-frame-alist)
(push '(width . 140) default-frame-alist)
(push '(height . 50) default-frame-alist)

(setq ns-use-native-fullscreen nil)
