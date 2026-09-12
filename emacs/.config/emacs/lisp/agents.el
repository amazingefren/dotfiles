;;; agents.el --- Herdr AI coding agents  -*- lexical-binding: t -*-

(use-package herdr
  :load-path "site-lisp/herdr"
  :ensure nil
  :demand t
  :config
  (herdr-mode 1)
  (evil-set-initial-state 'herdr-overview-mode 'normal)
  (evil-define-key 'normal herdr-overview-mode-map
    (kbd "RET") #'herdr-overview-visit
    "gr" #'herdr-overview-refresh
    "r" #'herdr-overview-rename
    "x" #'herdr-overview-kill
    "q" #'quit-window))

(defun agents--default-name (kind)
  "Return the next available name for KIND."
  (let ((taken (herdr--agent-names (herdr--session))))
    (cl-loop for i from 1
             for name = (if (= i 1) kind (format "%s-%d" kind i))
             unless (member name taken)
             return name)))

(defun agents-start-claude ()
  "Start a Claude agent."
  (interactive)
  (herdr-start "claude" (agents--default-name "claude")))

(defun agents-start-codex ()
  "Start a Codex agent."
  (interactive)
  (herdr-start "codex" (agents--default-name "codex")))

;;; Keybindings

(leader
  "a"  '(:ignore t :wk "agent")
  "aa" '(herdr-toggle :wk "show/hide")
  "as" '(herdr-start :wk "start (C-u: pick kind/name)")
  "ac" '(agents-start-claude :wk "start Claude")
  "ax" '(agents-start-codex :wk "start Codex")
  "aS" '(herdr-set-default-kind :wk "set default")
  "az" '(herdr-switch :wk "switch")
  "ap" '(herdr-prompt :wk "prompt")
  "al" '(herdr-send-region :wk "send region")
  "ad" '(herdr-overview-workspace :wk "agents here")
  "aD" '(herdr-overview :wk "agents everywhere")
  "ak" '(herdr-kill :wk "kill")
  "ar" '(herdr-rename :wk "rename")
  "ab" '(herdr-bind-session :wk "bind session"))
