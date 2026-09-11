;;; home.el --- the home workspace  -*- lexical-binding: t -*-
;;
;; Emacs starts in the `home' workspace laid out with the essentials: RSS in
;; the main window and the all-workspaces agent overview along the bottom.
;; Spotify has no view of its own; the current track sits in the mode line
;; once Spotify has been used (SPC o s ...). SPC TAB h rebuilds this layout.

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

(leader "TAB h" '(home-open :wk "home layout"))
