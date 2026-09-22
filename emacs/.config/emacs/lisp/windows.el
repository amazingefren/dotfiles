;;; windows.el --- window layouts  -*- lexical-binding: t -*-

(use-package winner
  :ensure nil
  :config
  (winner-mode 1))

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

;;; Keybindings

(leader
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
