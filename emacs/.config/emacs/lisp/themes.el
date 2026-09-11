;;; themes.el --- themes, live preview, and remembering the choice  -*- lexical-binding: t -*-
;;
;; SPC h r t previews themes on the whole frame as you move through the list;
;; RET keeps one, C-g restores the old one. The pick is saved and restored on
;; the next start, so this file never needs editing to change theme.
;;
;; Collections installed:
;;   modus-*   built in: vivendi, operandi, plus -tinted and -deuteranopia variants
;;   ef-*      same author, 30+ softer variants (ef-dream, ef-night, ef-elea-dark...)
;;   doom-*    the popular set: doom-one, doom-tokyo-night, doom-gruvbox, doom-nord...
;;   catppuccin  set `catppuccin-flavor' to mocha / macchiato / frappe / latte

(use-package ef-themes)
(use-package doom-themes
  :custom (doom-themes-enable-bold t) (doom-themes-enable-italic t))
(use-package catppuccin-theme
  :custom (catppuccin-flavor 'mocha))

(defvar themes-file (no-littering-expand-var-file-name "theme.el")
  "Where the chosen theme is remembered.")

(defun themes-load-saved (default)
  "Load the remembered theme, or DEFAULT if none was saved."
  (let ((theme (or (ignore-errors
                     (with-temp-buffer (insert-file-contents themes-file) (read (current-buffer))))
                   default)))
    (mapc #'disable-theme custom-enabled-themes)
    (condition-case nil
        (load-theme theme t)
      (error (load-theme default t)))))

(defun themes-pick ()
  "Pick a theme with live preview and remember it for next time."
  (interactive)
  (call-interactively #'consult-theme)
  (when-let* ((theme (car custom-enabled-themes)))
    (with-temp-file themes-file (prin1 theme (current-buffer)))
    (message "Theme %s saved" theme)))

(themes-load-saved 'modus-vivendi)   ; the SPC h r t binding lives in vim.el
