;;; agents.el --- Herdr AI coding agents  -*- lexical-binding: t -*-

(use-package live-diff
  :load-path "site-lisp"
  :ensure nil
  :demand t)

(use-package herdr
  :load-path "site-lisp/herdr"
  :ensure nil
  :demand t
  :custom
  (herdr-config-file (expand-file-name "etc/herdr.toml" user-emacs-directory))
  :config
  (herdr-mode 1)
  (evil-set-initial-state 'herdr-overview-mode 'normal)
  (evil-define-key 'normal herdr-overview-mode-map
    (kbd "RET") #'herdr-overview-visit
    (kbd "TAB") #'herdr-overview-toggle-space
    "gr" #'herdr-overview-refresh
    "r" #'herdr-overview-rename
    "x" #'herdr-overview-kill
    "q" #'quit-window))

(defvar agents--mcp-launch-context nil
  "Dynamically bound by Herdr while it launches an agent.

It contains `:root', `:name', `:session', and `:pane'.  The values are passed
to the MCP stdio process as environment variables, then re-injected as hidden
MCP arguments by `bin/emacs-mcp'.")

(defun agents--launch-shell-setup (kind)
  "Return shell setup needed before starting an agent of KIND."
  (when (equal kind "codex")
    (let* ((client (or (executable-find "emacsclient")
                       (user-error "emacsclient is needed for Codex's prompt editor")))
           (editor (format "%s --reuse-frame --socket-name %s"
                           (shell-quote-argument client)
                           (shell-quote-argument (if (boundp 'server-name)
                                                     server-name "server"))))
           (quoted (shell-quote-argument editor)))
      (format "export VISUAL=%s EDITOR=%s" quoted quoted))))

(defun agents--emacs-mcp-arguments ()
  "Return the per-launch Codex configuration for the Emacs MCP server."
  (let* ((program (expand-file-name "bin/emacs-mcp" user-emacs-directory))
         (root (plist-get agents--mcp-launch-context :root))
         (name (plist-get agents--mcp-launch-context :name))
         (session (plist-get agents--mcp-launch-context :session)))
    (unless (file-executable-p program)
      (user-error "Emacs MCP server is missing or not executable: %s" program))
    (unless (and (stringp root) (file-directory-p root))
      (user-error "Cannot start Emacs MCP without an agent workspace root"))
    ;; Codex maps these dotted config values to [mcp_servers.emacs.env].
    ;; `json-serialize' supplies valid TOML basic strings for paths and names.
    (list "-c" (format "mcp_servers.emacs.command=%S" program)
          "-c" (format "mcp_servers.emacs.env.EMACS_MCP_WORKSPACE_ROOT=%s"
                       (json-serialize (file-truename root)))
          "-c" (format "mcp_servers.emacs.env.EMACS_MCP_AGENT_NAME=%s"
                       (json-serialize name))
          "-c" (format "mcp_servers.emacs.env.EMACS_MCP_HERDR_SESSION=%s"
                       (json-serialize session)))))

(defun agents--claude-emacs-mcp-arguments ()
  "Return the per-launch Claude configuration for the Emacs MCP server."
  (let* ((program (expand-file-name "bin/emacs-mcp" user-emacs-directory))
         (hook-program (expand-file-name "bin/claude_subagents.py" user-emacs-directory))
         (root (plist-get agents--mcp-launch-context :root))
         (name (plist-get agents--mcp-launch-context :name))
         (session (plist-get agents--mcp-launch-context :session))
         (pane (plist-get agents--mcp-launch-context :pane))
         (hook `((type . "command")
                 (command . ,(format "HERDR_SESSION=%s HERDR_PANE_ID=%s python3 %s --record"
                                     (shell-quote-argument (or session ""))
                                     (shell-quote-argument (or pane ""))
                                     (shell-quote-argument hook-program)))))
         (plain `[((hooks . [,hook]))])
         (task-update `[((matcher . "TaskUpdate") (hooks . [,hook]))]))
    (unless (file-executable-p program)
      (user-error "Emacs MCP server is missing or not executable: %s" program))
    (unless (file-readable-p hook-program)
      (user-error "Claude overview hook is missing: %s" hook-program))
    (unless (and (stringp root) (file-directory-p root))
      (user-error "Cannot start Emacs MCP without an agent workspace root"))
    (unless (and (stringp session) (stringp pane))
      (user-error "Cannot track Claude without a Herdr session and pane"))
    (list "--settings"
          (json-serialize
           `((hooks . ((SessionStart . ,plain)
                       (SubagentStart . ,plain)
                       (SubagentStop . ,plain)
                       (TaskCreated . ,plain)
                       (TaskCompleted . ,plain)
                       (PostToolUse . ,task-update)
                       (Stop . ,plain)
                       (SessionEnd . ,plain)))))
          "--mcp-config"
          (json-serialize
           `((mcpServers
              . ((emacs
                  . ((command . ,program)
                     (env . ((EMACS_MCP_WORKSPACE_ROOT . ,(file-truename root))
                             (EMACS_MCP_AGENT_NAME . ,name)
                             (EMACS_MCP_HERDR_SESSION . ,session))))))))))))

(defun agents--launch-arguments (kind)
  "Return extra CLI arguments for agent KIND."
  (pcase kind
    ("codex" (agents--emacs-mcp-arguments))
    ("claude" (agents--claude-emacs-mcp-arguments))))

(defun agents-mcp-agent-metadata (pane)
  "Return the live Herdr metadata associated with MCP PANE.

The bridge sends the pane id inherited from Herdr.  This is lookup-only: the
launch root comes from the MCP process environment, not from selected Emacs
state or a model-controlled tool argument."
  (when (and pane (boundp 'herdr--workspace-sessions))
    (let ((pane (format "%s" pane))
          found)
      (maphash
       (lambda (workspace session)
         (dolist (agent (gethash session herdr--agents))
           (when (equal pane (format "%s" (alist-get 'pane_id agent)))
             (setq found `((name . ,(alist-get 'name agent))
                           (session . ,session)
                           (workspace . ,workspace)
                           (state . ,(or (alist-get 'agent_status agent) "unknown")))))))
       herdr--workspace-sessions)
      found)))

(defun agents-mcp-live-agents ()
  "Return every live Herdr agent known to Emacs for the activity dashboard."
  (when (boundp 'herdr--workspace-sessions)
    (let (agents)
      (maphash
       (lambda (workspace session)
         (dolist (agent (gethash session herdr--agents))
           (push `((pane . ,(alist-get 'pane_id agent))
                   (name . ,(alist-get 'name agent))
                   (session . ,session)
                   (workspace . ,workspace)
                   (root . ,(and (boundp 'workspace-roots)
                                 (gethash workspace workspace-roots)))
                   (state . ,(or (alist-get 'agent_status agent) "unknown")))
                 agents)))
       herdr--workspace-sessions)
      agents)))

(defun agents-mcp-show-agent (pane &optional _name)
  "Show the Herdr agent identified by MCP PANE, returning non-nil on success."
  (when-let* ((metadata (agents-mcp-agent-metadata pane))
              (session (alist-get 'session metadata)))
    (herdr--show session (format "%s" pane))
    t))

;;; Keybindings

;; Pane, tab, and shell management happens inside the herdr side window;
;; these are only the Emacs-side entry points.  Everything unbound here
;; (rename, kill, set default kind, MCP activity log) is still on M-x,
;; and rename/kill are also `r'/`x' in the SPC a v overview.
(leader
  "a"  '(:ignore t :wk "agent")
  "aa" '(herdr-start :wk "new agent tab (SPC u: pick kind)")
  "at" '(herdr-toggle :wk "toggle herdr")
  "aj" '(herdr-switch :wk "jump to agent")
  "ap" '(herdr-prompt :wk "prompt agent")
  "al" '(herdr-send-region :wk "send to focused agent")
  "av" '(herdr-overview :wk "view space tree")
  "ad" '(ai-review-show-worktree-diff :wk "review diff")
  "aD" '(live-diff-follow-compact-in-split :wk "follow latest change below agent")
  "ac" '(ai-review-show-compilation :wk "compilation")
  "af" '(live-diff-toggle-file-follow :wk "follow AI edits in this window")
  "aF" '(live-diff-follow-in-split :wk "follow AI edits below agent")
  "ab" '(herdr-bind-session :wk "bind session"))

(defun agents-send-region-or-window-right ()
  "Send the visual selection's reference to an agent from a file buffer.
Anywhere else, keep C-l's usual move to the window on the right."
  (interactive)
  (if buffer-file-name
      (call-interactively #'herdr-send-region)
    (evil-window-right 1)))

(with-eval-after-load 'evil
  (define-key evil-visual-state-map (kbd "C-l") #'agents-send-region-or-window-right))

(defun agents-herdr-navigation-keys ()
  "Let C-h/j/k/l cross herdr panes in every Evil state, vim-tmux-navigator style.
Buffer-local Evil keys outrank evil-ghostel's and ghostel's own bindings."
  (dolist (state '(insert normal emacs))
    (evil-local-set-key state (kbd "C-h") #'herdr-navigate-left)
    (evil-local-set-key state (kbd "C-j") #'herdr-navigate-down)
    (evil-local-set-key state (kbd "C-k") #'herdr-navigate-up)
    (evil-local-set-key state (kbd "C-l") #'herdr-navigate-right)))

(add-hook 'herdr-client-mode-hook #'agents-herdr-navigation-keys)
