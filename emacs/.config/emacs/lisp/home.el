;;; home.el --- the home workspace layout  -*- lexical-binding: t -*-

(defun home-open ()
  "Switch to the home workspace and lay it out: RSS as the master, agenda and agents beside it."
  (interactive)
  (persp-switch "home")
  (delete-other-windows)
  (elfeed)
  (feeds-refresh)
  (with-selected-window (split-window-right)
    (org-agenda nil "h"))
  (herdr-overview)
  (let ((feeds (get-buffer-window "*elfeed-search*")))
    (dwm-set-master feeds)
    (select-window feeds)))

(add-hook 'emacs-startup-hook
          (lambda () (unless (cl-some #'buffer-file-name (buffer-list)) (home-open))))

(leader "TAB h" '(home-open :wk "home layout"))
