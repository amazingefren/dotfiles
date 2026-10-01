;;; windows.el --- window layouts  -*- lexical-binding: t -*-

(use-package winner
  :ensure nil
  :config
  (winner-mode 1))

(use-package dwm
  :load-path "site-lisp/dwm"
  :ensure nil
  :demand t
  :custom
  (dwm-float-buffers '(derived-mode . magit-mode))
  (dwm-view-buffers '(or "\\`\\*herdr: " "\\`\\*herdr overview" "\\`\\*lyra dashboard: "))
  (switch-to-buffer-in-dedicated-window 'pop)
  :bind ("s-<return>" . dwm-zoom)
  :config
  (setopt tab-line-exclude-buffers dwm-view-buffers)
  (dwm-mode 1))

(use-package olivetti
  :commands olivetti-mode)

(defvar-keymap windows-resize-repeat-map
  :repeat t
  "+" #'enlarge-window
  "-" #'shrink-window
  ">" #'enlarge-window-horizontally
  "<" #'shrink-window-horizontally
  "=" #'balance-windows)

(repeat-mode 1)

(defun windows-close-other-tabs ()
  "Drop every buffer but the shown one from the selected window's tab line.
The buffers stay open."
  (interactive)
  (set-window-prev-buffers nil nil)
  (set-window-next-buffers nil nil)
  (set-window-parameter nil 'tab-line-buffers nil)
  (tab-line-force-update nil))

(leader
  "q"  '(quit-window :wk "close / back")
  "bo" '(windows-close-other-tabs :wk "close other tabs in split")
  "w"  '(:ignore t :wk "window")
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
