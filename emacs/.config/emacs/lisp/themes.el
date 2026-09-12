;;; themes.el --- themes and persisted theme selection  -*- lexical-binding: t -*-

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
