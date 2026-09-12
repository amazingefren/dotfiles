;;; home.el --- the home workspace layout  -*- lexical-binding: t -*-

(defun home-open ()
  "Switch to the home workspace and lay it out: RSS above, agents below."
  (interactive)
  (persp-switch "home")
  (delete-other-windows)
  (elfeed)
  (when (zerop (elfeed-db-last-update))   ; never fetched: do it now, in the background
    (elfeed-update))
  (herdr-overview)
  (select-window (get-buffer-window "*elfeed-search*")))

;; Lay out home after startup, unless Emacs was opened on a file.
(add-hook 'emacs-startup-hook
          (lambda () (unless (cl-some #'buffer-file-name (buffer-list)) (home-open))))

;;; Keybindings

(leader "TAB h" '(home-open :wk "home layout"))
