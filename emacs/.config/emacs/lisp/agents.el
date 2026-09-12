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

(defvar agents--mcp-launch-context nil
  "Dynamically bound by Herdr while it launches an agent.

It contains `:root', `:name', `:session', and `:pane'.  The values are passed
to the MCP stdio process as environment variables, then re-injected as hidden
MCP arguments by `bin/emacs-mcp'.")

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

(defun agents--launch-arguments (kind)
  "Return extra CLI arguments for agent KIND."
  (when (equal kind "codex")
    (agents--emacs-mcp-arguments)))

(defun agents--default-name (kind)
  "Return the next available name for KIND."
  (let ((taken (herdr--agent-names (herdr--session))))
    (cl-loop for i from 1
             for name = (if (= i 1) kind (format "%s-%d" kind i))
             unless (member name taken)
             return name)))

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
              (session (alist-get 'session metadata))
              (agent (alist-get 'name metadata)))
    (herdr--show session agent)
    t))

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
  "av" '(emacs-mcp-show-activity :wk "activity")
  "af" '(emacs-mcp-toggle-follow :wk "follow mode")
  "aR" '(ai-review-show-worktree-diff :wk "review diff")
  "aC" '(ai-review-show-compilation :wk "compilation")
  "ak" '(herdr-kill :wk "kill")
  "ar" '(herdr-rename :wk "rename")
  "ab" '(herdr-bind-session :wk "bind session"))
