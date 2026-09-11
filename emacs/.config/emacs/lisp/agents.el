;;; agents.el --- AI coding CLIs (claude, codex, ...) via herdr  -*- lexical-binding: t -*-
;;
;; herdr (site-lisp/herdr/herdr.el) runs agents in persistent herdr sessions,
;; one session per workspace, shows one agent at a time in a right side window,
;; and feeds each agent's state (working / needs you / idle) into the tab bar.
;; Sessions outlive Emacs.

;; ghostel: terminal emulator built on libghostty-vt, the engine behind
;; Ghostty and cmux. Unlike vterm it supports synchronized output, which is
;; what stops Claude Code's constant redraws from flickering. The native
;; module is a prebuilt binary downloaded on first use.
(use-package ghostel
  :commands (ghostel ghostel-project ghostel-exec)
  :custom
  (ghostel-module-auto-install 'download)                 ; fetch the prebuilt module, don't ask
  (ghostel-module-directory (no-littering-expand-var-file-name "ghostel/")) ; keep it out of the package tree
  (ghostel-max-scrollback (* 20 1024 1024))               ; 20MB; long agent sessions get truncated at the 5MB default
  ;; Keys Emacs keeps instead of sending to the terminal. C-l added so it can
  ;; move windows below. (C-j / C-k stay with the agent: newline, kill-line.)
  (ghostel-keymap-exceptions '("C-c" "C-x" "C-u" "C-h" "C-l" "M-x" "M-:" "C-\\"))
  :config
  ;; C-h / C-l leave the terminal for the window on that side.
  (define-key ghostel-mode-map (kbd "C-h") #'evil-window-left)
  (define-key ghostel-mode-map (kbd "C-l") #'evil-window-right))

;; Vim keys in the terminal. Insert state types into the agent; Esc goes to
;; the agent too (it uses Esc to interrupt). C-c ESC drops into normal state
;; for scrolling and yanking; i or a return to insert.
(use-package evil-ghostel
  :after (ghostel evil)
  :custom (evil-ghostel-escape 'terminal)
  :hook (ghostel-mode . evil-ghostel-mode)
  :config
  ;; evil-ghostel sends C-l to the terminal in insert state; window movement wins.
  (evil-define-key* 'insert evil-ghostel-mode-map (kbd "C-l") #'evil-window-right))

(use-package herdr
  :load-path "site-lisp/herdr"   ; my own package, not from an archive
  :ensure nil
  :demand t                      ; small, and herdr-mode must be on for the tab bar
  :config
  (herdr-mode 1)                 ; poll agent states into the tab bar
  ;; Vim keys in the overview table (evil owns RET otherwise).
  (evil-set-initial-state 'herdr-overview-mode 'normal)
  (evil-define-key 'normal herdr-overview-mode-map
    (kbd "RET") #'herdr-overview-visit
    "gr" #'herdr-overview-refresh
    "r"  #'herdr-overview-rename
    "q"  #'quit-window))

(defun herdr-start-claude () "Start a Claude agent here." (interactive) (herdr-start "claude" (herdr--default-name "claude")))
(defun herdr-start-codex  () "Start a Codex agent here."  (interactive) (herdr-start "codex"  (herdr--default-name "codex")))
(defun herdr--default-name (kind)
  (let ((taken (herdr--agent-names (herdr--session))))
    (cl-loop for i from 1 for n = (if (= i 1) kind (format "%s-%d" kind i)) unless (member n taken) return n)))

(leader
  "a"  '(:ignore t :wk "agent")
  "aa" '(herdr-toggle :wk "show/hide agent")
  "as" '(herdr-start :wk "start agent (C-u: pick kind/name)")
  "ac" '(herdr-start-claude :wk "start claude")
  "ax" '(herdr-start-codex :wk "start codex")
  "az" '(herdr-switch :wk "switch agent")
  "ap" '(herdr-prompt :wk "prompt agent")
  "al" '(herdr-send-region :wk "send region reference")
  "ad" '(herdr-overview-workspace :wk "agents here")
  "aD" '(herdr-overview :wk "agents everywhere")
  "ak" '(herdr-kill :wk "kill agent")
  "ar" '(herdr-rename :wk "rename agent")
  "ab" '(herdr-bind-session :wk "bind herdr session"))
