;;; home.el --- the home workspace layout  -*- lexical-binding: t -*-

(defun home-open ()
  "Switch to the home workspace and lay it out: RSS and agenda above, agents below."
  (interactive)
  (persp-switch "home")
  (delete-other-windows)
  (elfeed)
  (feeds-refresh)
  (with-selected-window (split-window-right)
    (org-agenda nil "h"))
  (herdr-overview)
  (select-window (get-buffer-window "*elfeed-search*")))

(add-hook 'emacs-startup-hook
          (lambda () (unless (cl-some #'buffer-file-name (buffer-list)) (home-open))))

(leader "TAB h" '(home-open :wk "home layout"))
