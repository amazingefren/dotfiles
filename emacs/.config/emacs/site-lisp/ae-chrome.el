;;; ae-chrome.el --- Theme-colored window chrome -*- lexical-binding: t -*-
;;; Commentary:
;; Provides workspace, tab, header, and modeline focus colors.
;;; Code:

(require 'cl-lib)
(require 'color)
(require 'seq)
(require 'tab-bar)
(require 'tab-line)

(defvar evil-state)

(defgroup ae-chrome nil
  "Theme-colored window chrome."
  :group 'faces)

(defface ae-chrome-active '((t :inherit highlight))
  "Tinted chrome for the selected window."
  :group 'ae-chrome)

(defface ae-chrome-inactive '((t :inherit shadow))
  "Neutral chrome for other windows."
  :group 'ae-chrome)

(defface ae-chrome-hover '((t :inherit highlight))
  "Theme tint for hovered workspace buttons and file headers."
  :group 'ae-chrome)

(defvar ae-chrome--saved-formats nil
  "Default modeline and header formats saved while the mode is enabled.")

(defvar ae-chrome--saved-tab-separator nil
  "Buffer-tab separator saved while the mode is enabled.")

(defvar-local ae-chrome--saved-modeline nil
  "Standard buffer-local modeline saved while AE chrome is enabled.")

(defconst ae-chrome--modeline
  '("%e" " " (:eval (ae-chrome--state)) " %b"
    (:eval (cond (buffer-read-only " RO")
                 ((buffer-modified-p) " •")))
    "  " mode-name (vc-mode ("  " vc-mode))
    mode-line-misc-info mode-line-format-right-align " %l:%c · %p ")
  "Compact modeline showing state, buffer, mode, branch, and position.")

(defconst ae-chrome--faces
  '(header-line header-line-active header-line-inactive
    mode-line mode-line-active mode-line-inactive
    tab-bar tab-bar-tab tab-bar-tab-inactive tab-line tab-line-tab
    tab-line-tab-current tab-line-tab-inactive tab-line-tab-modified
    tab-line-tab-special tab-line-highlight)
  "Native faces styled by AE chrome.")

;;;###autoload
(define-minor-mode ae-chrome-mode
  "Style editor chrome with theme colors for the selected window.
Disabling restores native face specifications and saved default formats.
Custom buffer-local header and modeline formats retain precedence."
  :global t
  :group 'ae-chrome
  (if ae-chrome-mode
      (progn
        (unless ae-chrome--saved-formats
          (setq ae-chrome--saved-tab-separator tab-line-separator)
          (setq ae-chrome--saved-formats
                (list (default-value 'mode-line-format)
                      (default-value 'header-line-format))))
        (setq tab-line-separator "")
        (setq-default
         header-line-format '((:eval (ae-chrome--header)))
         mode-line-format ae-chrome--modeline)
        (dolist (buffer (buffer-list))
          (with-current-buffer buffer
            (when (and (local-variable-p 'mode-line-format)
                       (equal mode-line-format (car ae-chrome--saved-formats)))
              (setq ae-chrome--saved-modeline (list mode-line-format))
              (kill-local-variable 'mode-line-format))))
        (add-hook 'enable-theme-functions #'ae-chrome--theme)
        (add-hook 'disable-theme-functions #'ae-chrome--theme)
        (add-hook 'after-make-frame-functions #'ae-chrome--theme)
        (add-hook 'window-state-change-functions #'ae-chrome--file-headers)
        (advice-add 'tab-line-tab-name-format-default :filter-return #'ae-chrome--pad-tab)
        (when (fboundp 'workspace--tab-item)
          (advice-add 'workspace--tab-item :filter-args #'ae-chrome--pad-workspace))
        (tab-line-force-update t)
        (ae-chrome--file-headers)
        (ae-chrome--theme))
    (remove-hook 'enable-theme-functions #'ae-chrome--theme)
    (remove-hook 'disable-theme-functions #'ae-chrome--theme)
    (remove-hook 'after-make-frame-functions #'ae-chrome--theme)
    (remove-hook 'window-state-change-functions #'ae-chrome--file-headers)
    (dolist (frame (frame-list))
      (dolist (window (window-list frame 'no-minibuffer))
        (when-let* ((saved (window-parameter window 'ae-chrome-header-format)))
          (set-window-parameter window 'header-line-format (car saved))
          (set-window-parameter window 'ae-chrome-header-format nil))))
    (advice-remove 'tab-line-tab-name-format-default #'ae-chrome--pad-tab)
    (advice-remove 'workspace--tab-item #'ae-chrome--pad-workspace)
    (tab-line-force-update t)
    (when ae-chrome--saved-formats
      (setq tab-line-separator ae-chrome--saved-tab-separator)
      (setq-default mode-line-format (car ae-chrome--saved-formats)
                    header-line-format (cadr ae-chrome--saved-formats))
      (setq ae-chrome--saved-formats nil))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (or (not (local-variable-p 'mode-line-format))
                  (equal mode-line-format ae-chrome--modeline))
          (if ae-chrome--saved-modeline
              (setq mode-line-format (car ae-chrome--saved-modeline))
            (kill-local-variable 'mode-line-format)))
        (setq ae-chrome--saved-modeline nil)))
    (dolist (frame (frame-list))
      (dolist (face ae-chrome--faces)
        (face-spec-recalc face frame))
      (dolist (face '(workspace-tab-group workspace-tab-child))
        (when (facep face)
          (face-spec-recalc face frame))))
    (force-window-update)))

(defconst ae-chrome--header-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'ae-chrome-copy-path)
    map)
  "Mouse bindings for file headers.")

(defun ae-chrome--file-headers (&rest _)
  "Show the standard path header only in windows visiting files."
  (dolist (frame (frame-list))
    (dolist (window (window-list frame 'no-minibuffer))
      (let ((saved (window-parameter window 'ae-chrome-header-format)))
        (if (with-current-buffer (window-buffer window)
              (equal header-line-format '((:eval (ae-chrome--header)))))
            (progn
              (unless saved
                (setq saved (list (window-parameter window 'header-line-format)))
                (set-window-parameter window 'ae-chrome-header-format saved))
              (set-window-parameter window 'header-line-format
                                    (if (buffer-file-name (window-buffer window))
                                        (car saved)
                                      'none)))
          (when saved
            (set-window-parameter window 'header-line-format (car saved))
            (set-window-parameter window 'ae-chrome-header-format nil)))))))

(defun ae-chrome--header ()
  "Return a theme-colored header for the window being redisplayed."
  (let* ((active (mode-line-window-selected-p))
         (face (if active 'ae-chrome-active 'ae-chrome-inactive))
         (width (max 0 (- (window-body-width) 2)))
         (path (if buffer-file-name
                   (string-join (last (split-string buffer-file-name "/" t) 3) " / ")
                 (buffer-name)))
         (name (truncate-string-to-width path width nil nil "…"))
         (padding (make-string (max 0 (- width (string-width name))) ?\s)))
    (propertize (string-replace "%" "%%" (concat " " name padding " "))
                'face face
                'help-echo (when buffer-file-name "Click to copy the full file path")
                'mouse-face (when buffer-file-name 'ae-chrome-hover)
                'local-map (when buffer-file-name ae-chrome--header-map))))

(defun ae-chrome-copy-path (event)
  "Copy the full file path from the window clicked in EVENT."
  (interactive "e")
  (with-current-buffer (window-buffer (posn-window (event-start event)))
    (unless buffer-file-name
      (user-error "Buffer %s has no file path" (buffer-name)))
    (kill-new buffer-file-name)
    (message "Copied %s" buffer-file-name)))

(defun ae-chrome--state ()
  "Return the modal editing state, or an empty string without Evil."
  (if (bound-and-true-p evil-local-mode)
      (upcase (symbol-name evil-state))
    ""))

(defun ae-chrome--pad-tab (label)
  "Return LABEL with clickable padding inheriting the tab's text properties."
  (let ((padding (apply #'propertize "  " (text-properties-at 0 label))))
    (concat padding label padding)))

(defun ae-chrome--pad-workspace (arguments)
  "Return workspace item ARGUMENTS with padding around its label."
  (setcar (cdr arguments)
          (propertize
           (concat (propertize " " 'display '(space :height 1.4 :ascent 70))
                   (cadr arguments) " ")
           'mouse-face 'ae-chrome-hover))
  arguments)

(defun ae-chrome--theme (&rest _)
  "Refresh chrome colors from each frame's current theme faces."
  (dolist (frame (seq-filter #'display-color-p (frame-list)))
    (let* ((accent (face-foreground 'font-lock-keyword-face frame t))
           (child-accent (face-foreground 'font-lock-string-face frame t))
           (background (face-background 'default frame t))
           (family (face-attribute 'default :family frame))
           (foreground (face-foreground 'default frame t))
           (muted (face-foreground 'shadow frame t))
           (background-rgb (color-name-to-rgb background frame))
           (accent-rgb (color-name-to-rgb accent frame))
           (child-accent-rgb (color-name-to-rgb child-accent frame))
           (foreground-rgb (color-name-to-rgb foreground frame))
           (border (apply #'color-rgb-to-hex
                          (cl-mapcar (lambda (base color) (+ (* base 0.75) (* color 0.25)))
                                     background-rgb accent-rgb)))
           (child-tint (apply #'color-rgb-to-hex
                              (cl-mapcar (lambda (base color) (+ (* base 0.88) (* color 0.12)))
                                         background-rgb child-accent-rgb)))
           (panel (apply #'color-rgb-to-hex
                         (cl-mapcar (lambda (base text) (+ (* base 0.95) (* text 0.05)))
                                    background-rgb foreground-rgb)))
           (tint (apply #'color-rgb-to-hex
                        (cl-mapcar (lambda (base color) (+ (* base 0.88) (* color 0.12)))
                                   background-rgb accent-rgb)))
           (hover-tint (apply #'color-rgb-to-hex
                              (cl-mapcar (lambda (base color) (+ (* base 0.80) (* color 0.20)))
                                         background-rgb accent-rgb))))
      (set-face-attribute 'ae-chrome-hover frame
                          :inherit 'unspecified :background hover-tint)
      (set-face-attribute 'ae-chrome-active frame
                          :background tint :foreground accent
                          :box `(:line-width (1 . 5) :color ,tint))
      (set-face-attribute 'ae-chrome-inactive frame
                          :background panel :foreground muted
                          :box `(:line-width (1 . 5) :color ,panel))
      (dolist (face ae-chrome--faces)
        (face-spec-recalc face frame)
        (set-face-attribute face frame
                            :box `(:line-width (1 . 5) :color ,panel)
                            :family family :height 1.0 :overline nil :slant 'normal
                            :underline nil :weight 'normal
                            :background panel :foreground muted))
      (dolist (face '(header-line-active mode-line-active tab-bar-tab tab-line-tab-current))
        (set-face-attribute face frame :background tint :foreground accent
                            :box `(:line-width (1 . 5) :color ,tint)))
      (dolist (face '(ae-chrome-active ae-chrome-inactive))
        (set-face-attribute face frame :family family :height 0.9
                            :slant 'normal :underline nil :weight 'normal))
      (dolist (face '(tab-line-tab-modified tab-line-tab-special))
        (face-spec-reset-face face frame)
        (set-face-attribute face frame :slant 'normal :weight 'normal))
      (face-spec-reset-face 'tab-line-highlight frame)
      (dolist (face '(tab-bar-tab tab-bar-tab-inactive))
        (set-face-attribute face frame :box nil))
      (when (facep 'workspace-tab-group)
        (set-face-attribute 'workspace-tab-group frame
                            :box `(:line-width 1 :color ,border)))
      (when (facep 'workspace-tab-child)
        (set-face-attribute 'workspace-tab-child frame
                            :background child-tint :foreground child-accent :box nil))
      (set-face-attribute 'tab-line-tab frame :foreground foreground)))
  (force-window-update))

(provide 'ae-chrome)
;;; ae-chrome.el ends here
