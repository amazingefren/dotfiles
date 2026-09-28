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

(defvar-local themes--popup-tint nil "Face-remap cookies of this buffer's tint.")

(defun themes-popup-tint ()
  "Give the current buffer a background one shade off the theme's."
  (require 'color)
  (mapc #'face-remap-remove-relative themes--popup-tint)
  (let ((bg (face-background 'default nil t)))
    (when (color-defined-p bg)
      (let ((shade (if (eq (frame-parameter nil 'background-mode) 'dark)
                       (color-lighten-name bg 8)
                     (color-darken-name bg 4))))
        (setq themes--popup-tint
              (list (face-remap-add-relative 'default :background shade)
                    (face-remap-add-relative 'fringe :background shade)))))))

(add-hook 'enable-theme-functions
          (lambda (_theme)
            (dolist (b (buffer-list))
              (with-current-buffer b (when themes--popup-tint (themes-popup-tint))))))

(themes-load-saved 'modus-vivendi)
