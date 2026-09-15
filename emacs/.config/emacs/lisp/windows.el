;;; windows.el --- window layouts and zen mode  -*- lexical-binding: t -*-

(use-package winner
  :ensure nil
  :config
  (winner-mode 1))

(use-package olivetti
  :commands olivetti-mode)

;; (defvar windows-maximize--saved nil)

;; (defun windows-toggle-maximize ()
;;   "Show only the selected window, then restore its layout."
;;   (interactive)
;;   (if windows-maximize--saved
;;       (progn
;;         (set-window-configuration windows-maximize--saved)
;;         (setq windows-maximize--saved nil))
;;     (setq windows-maximize--saved (current-window-configuration))
;;     (when (window-with-parameter 'window-side)
;;       (window-toggle-side-windows))
;;     (delete-other-windows)))

;; (defvar windows-zen--saved nil)

;; (defun windows-toggle-zen ()
;;   "Toggle a centered, distraction-free view."
;;   (interactive)
;;   (if windows-zen--saved
;;       (progn
;;         (set-window-configuration (car windows-zen--saved))
;;         (setq tab-bar-show t)
;;         (with-current-buffer (cadr windows-zen--saved)
;;           (olivetti-mode -1)
;;           (when (derived-mode-p 'prog-mode 'text-mode)
;;             (display-line-numbers-mode 1)))
;;         (setq windows-zen--saved nil))
;;     (setq windows-zen--saved (list (current-window-configuration) (current-buffer)))
;;     (when (window-with-parameter 'window-side)
;;       (window-toggle-side-windows))
;;     (delete-other-windows)
;;     (setq tab-bar-show nil)
;;     (display-line-numbers-mode -1)
;;     (olivetti-mode 1)))

(defvar-keymap windows-resize-repeat-map
  :repeat t
  "+" #'enlarge-window
  "-" #'shrink-window
  ">" #'enlarge-window-horizontally
  "<" #'shrink-window-horizontally
  "=" #'balance-windows)

(repeat-mode 1)

;;; Keybindings

(leader
  ;; "z"  '(windows-toggle-zen :wk "zen")
  "w"  '(:ignore t :wk "window")
  ;; "wm" '(windows-toggle-maximize :wk "maximize")
  "w=" '(balance-windows :wk "balance")
  "w+" '(enlarge-window :wk "taller")
  "w-" '(shrink-window :wk "shorter")
  "w>" '(enlarge-window-horizontally :wk "wider")
  "w<" '(shrink-window-horizontally :wk "narrower")
  "wu" '(winner-undo :wk "undo layout")
  "wr" '(winner-redo :wk "redo layout")
  "wv" '(evil-window-vsplit :wk "split right")
  "ws" '(evil-window-split :wk "split below")
  "wq" '(evil-window-delete :wk "close")
  "wo" '(delete-other-windows :wk "only this")
  "wf" '(toggle-frame-fullscreen :wk "fullscreen"))
