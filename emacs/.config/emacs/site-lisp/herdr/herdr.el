;;; herdr.el --- AI coding agents in herdr sessions, one per workspace  -*- lexical-binding: t -*-

;; Author: Efren
;; Version: 0.1
;; Package-Requires: ((emacs "30.1") (ghostel "0.1") (perspective "2.0"))
;; Keywords: tools, terminals

;;; Commentary:

;; herdr (https://herdr.dev) is a persistent terminal server that runs AI
;; coding CLIs and detects what each one is doing: idle, working, blocked
;; (waiting on you), or done.  This package puts that inside Emacs:
;;
;; - Each Emacs workspace (perspective) is bound to one herdr session, named
;;   after that workspace by default.  Sessions outlive Emacs: restart, and
;;   `herdr-switch' reattaches.  `herdr-bind-session' can override the default.
;; - Each Emacs workspace has one Herdr space, with one tab per new agent.
;;   Agents run in herdr panes.  Emacs shows the session in a side window
;;   through a ghostel terminal running the full herdr client, so herdr's
;;   own tabs and shells work there too; agent commands focus that client
;;   on the agent.
;; - Agent states are polled and shown as glyphs in the Emacs workspace bar
;;   and Herdr's agent tab labels, and in `herdr-overview', which groups
;;   agents, shells, tasks, workflows, and subagents beneath their spaces.
;;
;; Commands: `herdr-start', `herdr-switch', `herdr-toggle', `herdr-prompt', `herdr-rename',
;; `herdr-send-region', `herdr-overview', `herdr-kill', `herdr-bind-session', `herdr-clean'.
;; Turn on `herdr-mode' for the polling and tab-bar integration.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'json)
(require 'tabulated-list)
(require 'easymenu)

(declare-function persp-current-name "perspective")
(declare-function persp-names "perspective")
(declare-function persp-switch "perspective")
(declare-function ghostel-exec "ghostel")
(declare-function workspace-root "workspaces")
(declare-function workspace-names "workspaces")
(defvar workspace-roots)
(declare-function emacs-mcp-activity-refresh "mcp")
(defvar workspace-status-function)
;; Declared here so the dynamic binding in `herdr-start' remains dynamic even
;; with lexical binding.  `agents.el' owns the value and consumes it only
;; while constructing its per-launch arguments.
(defvar agents--mcp-launch-context)

(defgroup herdr nil
  "AI coding agents in herdr sessions."
  :group 'tools
  :prefix "herdr-")

(defcustom herdr-program "herdr"
  "The herdr executable."
  :type 'string)

(defcustom herdr-config-file nil
  "herdr config file for sessions run from Emacs, or nil for herdr's default.
Passed as HERDR_CONFIG_PATH to every herdr process this package starts.
A session's server reads it when it starts."
  :type '(choice (const :tag "herdr's default" nil) file))

(defun herdr--environment ()
  "`process-environment' for herdr processes, with `herdr-config-file' applied."
  (if herdr-config-file
      (cons (concat "HERDR_CONFIG_PATH=" (expand-file-name herdr-config-file))
            process-environment)
    process-environment))

(defcustom herdr-agent-kinds '("claude" "codex" "gemini" "copilot" "opencode" "pi")
  "Agent kinds offered by `herdr-start'.  Must be kinds herdr knows (see `herdr agent start --help')."
  :type '(repeat string))

(defcustom herdr-default-kind nil
  "Agent kind `herdr-start' uses without a prefix argument.
When nil, ask on first use and save the choice in `custom-file'."
  :type '(choice (const :tag "Ask on first use" nil)
                 (string :tag "Agent kind")))

(defcustom herdr-poll-interval 2
  "Seconds between agent state polls while `herdr-mode' is on."
  :type 'number)

(defcustom herdr-window-width 0.45
  "Width of the agent side window, as a fraction of the frame."
  :type 'number)

(defcustom herdr-notify t
  "Show a desktop notification when an agent needs attention."
  :type 'boolean)

(defface herdr-working '((t :inherit success)) "Glyph for a working agent.")
(defface herdr-attention '((t :inherit warning :weight bold)) "Glyph for an agent that needs you.")

;;;; State

(defvar herdr--workspace-sessions (make-hash-table :test #'equal)
  "Workspace (perspective) name -> herdr session name.")

(defvar herdr--agents (make-hash-table :test #'equal)
  "Session name -> list of agent alists from the last poll.")

(defvar herdr--tab-status-last-sync (make-hash-table :test #'equal)
  "Session name -> time its Herdr tab labels were last checked.")

(defvar herdr--codex-threads (make-hash-table :test #'equal)
  "Herdr (SESSION . PANE) -> root Codex thread ID, reported by Emacs MCP.")

(defvar herdr--claude-sessions (make-hash-table :test #'equal)
  "Herdr (SESSION . PANE) -> Claude session ID from lifecycle hooks.")

(defvar herdr--claude-tasks (make-hash-table :test #'equal)
  "Claude session ID -> active task records from lifecycle hooks.")

(defvar herdr--claude-workflows (make-hash-table :test #'equal)
  "Claude session ID -> last reported workflow runs.")

(defvar herdr--claude-stats (make-hash-table :test #'equal)
  "Claude session ID -> transcript stats: context_tokens, model, branch,
started_ns, last_ns (see bin/claude_subagents.py).")

(defun herdr-register-codex-thread (session pane thread-id)
  "Associate SESSION and PANE with a root Codex THREAD-ID."
  (when (and (stringp session) (stringp pane) (stringp thread-id)
             (string-match-p "\\`[[:xdigit:]-]+\\'" thread-id))
    (puthash (cons session pane) thread-id herdr--codex-threads)))

(defvar herdr--poll-timer nil)

(defvar-local herdr--client-session nil
  "The herdr session this buffer's client is attached to.")

;;;; herdr CLI

(defun herdr--session-args (session args)
  (append (when session (list "--session" session)) args))

(defun herdr--parse (code out args)
  "Return the result of a herdr run that exited with CODE and printed OUT.
Signal a user error or `herdr-error' on failure."
  (let ((out (string-trim out)))
    (cond
     ((and (eq code 0) (string-empty-p out)) nil)   ; some commands (pane send-text) print nothing on success
     ((not (string-prefix-p "{" out))
      (user-error "herdr %s: %s" (string-join args " ") out))
     (t
      (let* ((json (json-parse-string out :object-type 'alist :array-type 'list))
             (err (alist-get 'error json)))
        (when err
          (signal 'herdr-error (list (alist-get 'code err) (alist-get 'message err))))
        (alist-get 'result json))))))

(defun herdr--run (session &rest args)
  "Run herdr with ARGS against SESSION; return the parsed JSON result.
Signal a user error on failure."
  (with-temp-buffer
    (let* ((process-environment (herdr--environment))
           (args (herdr--session-args session args))
           (code (apply #'call-process herdr-program nil t nil args)))
      (herdr--parse code (buffer-string) args))))

(defun herdr--run-async (session args on-success on-error)
  "Run herdr with ARGS against SESSION without blocking Emacs.
Call ON-SUCCESS with the parsed result, or ON-ERROR with the error data."
  (let* ((process-environment (herdr--environment))
         (args (herdr--session-args session args))
         (buffer (generate-new-buffer " *herdr-async*")))
    (make-process
     :name "herdr" :buffer buffer :noquery t
     :command (cons herdr-program args)
     :connection-type 'pipe
     :sentinel
     (lambda (process _event)
       (unless (process-live-p process)
         (let ((outcome
                (condition-case err
                    (cons t (herdr--parse (process-exit-status process)
                                          (with-current-buffer buffer (buffer-string))
                                          args))
                  (error (cons nil err)))))
           (kill-buffer buffer)
           (if (car outcome)
               (funcall on-success (cdr outcome))
             (funcall on-error (cdr outcome)))))))))

(define-error 'herdr-error "herdr")

(defun herdr--sessions ()
  "Alist of (name . running-p) for known herdr sessions."
  (with-temp-buffer
    (call-process herdr-program nil t nil "session" "list")
    (goto-char (point-min)) (forward-line 1)   ; header
    (let (out)
      (while (not (eobp))
        (let ((cols (split-string (buffer-substring (line-beginning-position) (line-end-position)) "[ \t]+" t)))
          (when (>= (length cols) 2)
            (push (cons (car cols) (string= (cadr cols) "running")) out)))
        (forward-line 1))
      (nreverse out))))

(defun herdr--session-running-p (session)
  (alist-get session (herdr--sessions) nil nil #'equal))

(defun herdr--ensure-session (session)
  "Make sure SESSION's server is running; start it headless if not."
  (unless (herdr--session-running-p session)
    (let ((default-directory (expand-file-name "~/"))
          (process-environment (herdr--environment)))
      (call-process "/bin/sh" nil 0 nil "-c"
                    (format "nohup %s --session %s server >/dev/null 2>&1 &"
                            (shell-quote-argument herdr-program)
                            (shell-quote-argument session))))
    (cl-loop repeat 50
             until (herdr--session-running-p session)
             do (sleep-for 0.1))
    (unless (herdr--session-running-p session)
      (user-error "herdr session %s did not start" session)))
  session)

;;;; Sessions <-> workspaces

(defun herdr--workspace ()
  (if (fboundp 'persp-current-name) (persp-current-name) "main"))

(defconst herdr-session-name-max 40
  "Longest session name `herdr--session-name-for' returns.
herdr's sockets live at ~/.config/herdr/sessions/NAME/herdr-client.sock,
and macOS caps a socket path at 104 bytes; past that the server won't start.")

(defun herdr--session-name-for (workspace)
  "A herdr session name derived from WORKSPACE.
A name too long for herdr's socket path is cut short and given a hash of
the full name, so it stays unique."
  (let ((s (replace-regexp-in-string "[^A-Za-z0-9_-]" "-" workspace)))
    (cond ((string-empty-p s) "emacs")
          ((<= (length s) herdr-session-name-max) s)
          (t (format "%s-%s" (substring s 0 (- herdr-session-name-max 7))
                     (substring (md5 workspace) 0 6))))))

;;;###autoload
(defun herdr-bind-session (session)
  "Bind the current workspace to herdr SESSION, starting it if needed.
Prompts with the running sessions plus a fresh one named after the workspace."
  (interactive
   (let* ((ws (herdr--workspace))
          (default (herdr--session-name-for ws))
          (names (delete-dups (cons default (mapcar #'car (herdr--sessions))))))
     (list (completing-read (format "herdr session for %s: " ws) names nil nil nil nil default))))
  (herdr--ensure-session session)
  (puthash (herdr--workspace) session herdr--workspace-sessions)
  (herdr--poll)
  (message "Workspace %s -> herdr session %s" (herdr--workspace) session)
  session)

(defun herdr-delete-workspace-session (workspace)
  "Stop and delete WORKSPACE's herdr session, with every agent in it.
For closing a workspace for good; its client buffer is killed too."
  (let ((session (or (gethash workspace herdr--workspace-sessions)
                     (herdr--session-name-for workspace))))
    ;; Close the client first, so it isn't left showing a dead server.
    (when-let* ((buffer (get-buffer (herdr--buffer-name session))))
      (let ((kill-buffer-query-functions nil)) (kill-buffer buffer)))
    (when (assoc session (herdr--sessions))
      (when (herdr--session-running-p session)
        (call-process herdr-program nil nil nil "session" "stop" session)
        (cl-loop repeat 50
                 while (herdr--session-running-p session)
                 do (sleep-for 0.1)))
      (herdr--delete-session session))
    (remhash workspace herdr--workspace-sessions)
    (remhash session herdr--agents)))

(defun herdr--session-dir (session)
  "SESSION's state directory, from `herdr session list'."
  (with-temp-buffer
    (call-process herdr-program nil t nil "session" "list")
    (goto-char (point-min))
    (when (re-search-forward (concat "^" (regexp-quote session) "[ \t]+[a-z]+[ \t]+\\([^ \t\n]+\\)") nil t)
      (match-string 1))))

(defun herdr--saved-spaces (session)
  "SESSION's spaces as (LABEL . CWD): live if it runs, else from session.json."
  (if (herdr--session-running-p session)
      ;; A space has no folder of its own over the API; its panes start in it.
      (cl-loop for space in (alist-get 'workspaces (herdr--run session "workspace" "list"))
               for panes = (alist-get 'panes (herdr--run session "pane" "list" "--workspace"
                                                          (alist-get 'workspace_id space)))
               collect (cons (alist-get 'label space) (alist-get 'cwd (car panes))))
    (when-let* ((dir (herdr--session-dir session))
                (file (expand-file-name "session.json" dir))
                ((file-readable-p file)))
      (cl-loop for space across (alist-get 'workspaces (json-read-file file) [])
               collect (cons (alist-get 'custom_name space) (alist-get 'identity_cwd space))))))

(defun herdr-workspace-children (project)
  "Spaces in herdr labelled PROJECT@NAME, as (LABEL CWD SESSION).
Only sessions named after one of PROJECT's children are read: their names
start with PROJECT's session name and a dash (`herdr--session-name-for')."
  (let* ((prefix (concat (herdr--session-name-for project) "-"))
         (prefix (substring prefix 0 (min (length prefix) (- herdr-session-name-max 7)))))
    (cl-loop for (session . _running) in (herdr--sessions)
             when (string-prefix-p prefix session)
             append (cl-loop for (label . cwd) in (ignore-errors (herdr--saved-spaces session))
                             when (and (stringp label) (stringp cwd)
                                       (string-prefix-p (concat project "@") label))
                             collect (list label cwd session)))))

(defun herdr-remember-session (workspace session)
  "Bind WORKSPACE to herdr SESSION without starting it.
Its agent counts show as soon as the session runs; the first herdr command
in WORKSPACE starts it if it is stopped."
  (puthash workspace session herdr--workspace-sessions))

(defun herdr--session ()
  "This workspace's session, using its name by default.
A stopped or deleted session is started again."
  (let* ((workspace (herdr--workspace))
         (session (or (gethash workspace herdr--workspace-sessions)
                      (herdr--session-name-for workspace))))
    (herdr--ensure-session session)
    (puthash workspace session herdr--workspace-sessions)
    session))

;;;; Agents

(defun herdr--agents (session)
  "Live agent list for SESSION from herdr."
  (alist-get 'agents (herdr--run session "agent" "list")))

(defun herdr--agent-names (session)
  (delq nil (mapcar (lambda (a) (alist-get 'name a)) (herdr--agents session))))

(defun herdr--agent-label (agent)
  "AGENT's name, or its kind and pane when herdr has no name for it.
Agents resumed or started from inside herdr can be unnamed."
  (or (alist-get 'name agent)
      (format "%s %s" (alist-get 'agent agent) (alist-get 'pane_id agent))))

(defun herdr--agent (session pane)
  (seq-find (lambda (a) (equal (alist-get 'pane_id a) pane)) (herdr--agents session)))

(defun herdr-set-default-kind (kind)
  "Use KIND as the default agent kind on this machine."
  (interactive
   (list (completing-read "Default agent: " herdr-agent-kinds nil t nil nil
                          herdr-default-kind)))
  (customize-save-variable 'herdr-default-kind kind)
  (message "Herdr default agent is now %s" kind)
  kind)

(defun herdr--default-kind ()
  "Return the configured default agent kind, asking once when needed."
  (or herdr-default-kind
      (herdr-set-default-kind
       (completing-read "Default agent: " herdr-agent-kinds nil t))))

(defun herdr--status-glyph (status)
  (pcase status
    ("working"  (propertize "●" 'face 'herdr-working))
    ((or "blocked" "done") (propertize "◆" 'face 'herdr-attention))
    ("idle"     "○")
    (_          "·")))

(defun herdr--tab-base-label (label)
  "Remove a status prefix previously added to tab LABEL."
  (replace-regexp-in-string "\\`[◆✓●○·] " "" label))

(defun herdr--tab-status-symbol (agents)
  "Return the highest-priority status symbol for AGENTS, or nil."
  (cond
   ((seq-some (lambda (a) (equal (alist-get 'agent_status a) "blocked")) agents) "◆")
   ((seq-some (lambda (a) (equal (alist-get 'agent_status a) "done")) agents) "✓")
   ((seq-some (lambda (a) (equal (alist-get 'agent_status a) "working")) agents) "●")
   ((seq-some (lambda (a) (equal (alist-get 'agent_status a) "idle")) agents) "○")
   (agents "·")))

(defun herdr--sync-tab-status (session agents)
  "Show AGENTS' states in SESSION's Herdr tab labels.
Preserve user-edited tab names and only send a rename when a label changes."
  (let ((agent-by-pane (make-hash-table :test #'equal))
        (agents-by-tab (make-hash-table :test #'equal)))
    (dolist (agent agents)
      (puthash (alist-get 'pane_id agent) agent agent-by-pane))
    (dolist (pane (alist-get 'panes (herdr--run session "pane" "list")))
      (when-let* ((tab-id (alist-get 'tab_id pane))
                  (agent (gethash (alist-get 'pane_id pane) agent-by-pane)))
        (push agent (gethash tab-id agents-by-tab))))
    (dolist (tab (alist-get 'tabs (herdr--run session "tab" "list")))
      (let* ((tab-id (alist-get 'tab_id tab))
             (label (alist-get 'label tab))
             (symbol (herdr--tab-status-symbol (gethash tab-id agents-by-tab))))
        (when (and tab-id (stringp label))
          (let* ((base (herdr--tab-base-label label))
                 (desired (if symbol (concat symbol " " base) base)))
            (unless (equal label desired)
              (herdr--run session "tab" "rename" tab-id desired))))))))

(defun herdr--read-agent (session prompt)
  "Pick one of SESSION's agents, showing its state; return its pane id."
  (let* ((agents (herdr--agents session))
         (choices (mapcar (lambda (a) (cons (herdr--agent-label a) a)) agents)))
    (unless agents (user-error "No agents in session %s. SPC a a starts one" session))
    (alist-get 'pane_id
               (if (= 1 (length agents))
                   (car agents)
                 (let ((completion-extra-properties
                        `(:annotation-function
                          ,(lambda (label)
                             (let ((a (alist-get label choices nil nil #'equal)))
                               (format "  %s %s  %s" (herdr--status-glyph (alist-get 'agent_status a))
                                       (alist-get 'agent_status a) (or (alist-get 'terminal_title_stripped a) "")))))))
                   (alist-get (completing-read prompt choices nil t) choices nil nil #'equal))))))

(defun herdr--root ()
  (if (fboundp 'workspace-root) (workspace-root) default-directory))

(defun herdr--find-space (session workspace root)
  "Find WORKSPACE's existing Herdr space in SESSION, preferring ROOT."
  (let* ((spaces (alist-get 'workspaces (herdr--run session "workspace" "list")))
         (matches (seq-filter (lambda (item)
                                (equal (alist-get 'label item) workspace))
                              spaces))
         (space (seq-find (lambda (item)
                            (when-let* ((cwd (alist-get 'cwd item)))
                              (equal (directory-file-name (expand-file-name cwd)) root)))
                          matches)))
    (or space (car matches))))

(defun herdr--space (session workspace root agent-name)
  "Find WORKSPACE's Herdr space in SESSION, or create it at ROOT.
Return (SPACE-ID . PANE-ID).  The pane is non-nil for a new space, and for
a space that holds only its first shell, untouched (see `herdr-ensure-space'):
the agent takes that pane and tab rather than leaving the shell behind."
  (if-let* ((space (herdr--find-space session workspace root)))
      (let* ((id (alist-get 'workspace_id space))
             (panes (alist-get 'panes (herdr--run session "pane" "list" "--workspace" id)))
             (pane (car panes)))
        (if (and pane (null (cdr panes)) (herdr--idle-pane-p session pane))
            (progn (herdr--run session "tab" "rename" (alist-get 'tab_id pane) agent-name)
                   (cons id (alist-get 'pane_id pane)))
          (cons id nil)))
    (let ((created (herdr--run session "workspace" "create"
                               "--cwd" root "--label" workspace "--focus")))
      (herdr--run session "tab" "rename"
                  (alist-get 'tab_id (alist-get 'tab created)) agent-name)
      (cons (alist-get 'workspace_id (alist-get 'workspace created))
            (alist-get 'pane_id (alist-get 'root_pane created))))))

;;;###autoload
(defun herdr-ensure-space ()
  "Make sure the current workspace has its herdr session and space.
A workspace with a space is found again after Emacs restarts (see
`herdr-workspace-children'), even before any agent runs in it.  The space
starts with one shell, which the first agent then takes over."
  (let* ((session (herdr--session))
         (workspace (herdr--workspace))
         (root (directory-file-name (expand-file-name (herdr--root)))))
    (unless (herdr--find-space session workspace root)
      (herdr--run session "workspace" "create" "--cwd" root "--label" workspace "--no-focus"))
    (herdr--poll)))

;;;###autoload
(defun herdr-start (kind name)
  "Start a new agent of KIND called NAME at the workspace root.
The Emacs workspace owns one Herdr space; each agent gets a tab.
KIND is `herdr-default-kind' unless given a prefix argument."
  (interactive
   (let* ((session (herdr--session))
          (kind (if current-prefix-arg
                    (completing-read "Agent: " herdr-agent-kinds nil t nil nil herdr-default-kind)
                  (herdr--default-kind)))
          (taken (herdr--agent-names session))
          (default (cl-loop for i from 1
                            for n = (if (= i 1) kind (format "%s-%d" kind i))
                            unless (member n taken) return n))
          (name (string-trim (read-string (format "Name for %s (default %s): " kind default)
                                          nil nil default))))
     (when (member name taken) (user-error "An agent is already called %s" name))
     (list kind (if (string-empty-p name) default name))))
  (let* ((session (herdr--session))
         (root (directory-file-name (expand-file-name (herdr--root))))
         (space (herdr--space session (herdr--workspace) root name))
         (pane (or (cdr space)
                   (alist-get 'pane_id
                              (alist-get 'root_pane
                                         (herdr--run session "tab" "create"
                                                     "--workspace" (car space)
                                                     "--cwd" root "--label" name "--focus"))))))
    ;; A frontend can use this dynamic launch context to configure a local
    ;; companion process (for example, an editor MCP bridge) without Herdr
    ;; taking a dependency on that frontend.  The actual agent still owns the
    ;; shell process and inherits HERDR_PANE_ID from Herdr.
    (let ((agents--mcp-launch-context
           (list :root root :name name :session session :pane pane)))
      (when (fboundp 'agents--launch-shell-setup)
        (when-let* ((setup (agents--launch-shell-setup kind)))
          (herdr--run session "pane" "run" pane setup)))
      (herdr--start-agent
       session pane name
       (append (list "agent" "start" name "--kind" kind "--pane" pane "--timeout" "90000")
               (when (fboundp 'agents--launch-arguments)
                 (when-let* ((arguments (agents--launch-arguments kind)))
                   (cons "--" arguments))))
       1))
    (message "Starting %s as %s in %s…" kind name (abbreviate-file-name root))
    ;; The new tab is focused, so the client shows the agent booting.
    (herdr--display session)))

(defun herdr--start-agent (session pane name args attempt)
  "Run the `agent start' ARGS for NAME in PANE in the background.
Herdr waits until the agent is ready for input, which takes seconds, so
Emacs must not wait with it.  The new pane's shell takes a moment to come
up and herdr refuses to start an agent until it is at a prompt, so retry
that for a few seconds.  ATTEMPT counts the tries."
  (herdr--run-async
   session args
   (lambda (_result)
     (herdr--poll)
     (ignore-errors (herdr--run session "agent" "focus" pane))
     (message "Started %s" name))
   (lambda (err)
     (if (and (eq (car err) 'herdr-error)
              (equal (nth 1 err) "agent_pane_busy")
              (< attempt 20))
         (run-at-time 0.3 nil #'herdr--start-agent session pane name args (1+ attempt))
       (message "Could not start %s: %s" name (error-message-string err))))))

(defun herdr--buffer-name (session) (format "*herdr: %s*" session))

(defun herdr--client-buffer (session)
  "A ghostel buffer running the full herdr client for SESSION.
Return (BUFFER . FRESH), where FRESH is non-nil if the client was just started.
The full client, unlike `herdr agent attach', forwards mouse clicks and drags
to the pane, and gives the side window herdr's own tabs, shells, and agents."
  (let* ((bname (herdr--buffer-name session))
         (live (let ((b (get-buffer bname)))
                 (and b (get-buffer-process b) (process-live-p (get-buffer-process b)) b))))
    (if live
        (cons live nil)
      (require 'ghostel)
      (when-let* ((old (get-buffer bname))) (kill-buffer old))
      (herdr--ensure-session session)
      (let ((buffer (get-buffer-create bname))
            (process-environment (herdr--environment)))
        (save-window-excursion
          ;; Ghostel's native PTY can omit dynamically bound environment
          ;; variables.  Pass the config path in argv so the client always
          ;; reads the same key bindings as the session server.
          (if herdr-config-file
              (ghostel-exec buffer "/usr/bin/env"
                            (list (concat "HERDR_CONFIG_PATH="
                                          (expand-file-name herdr-config-file))
                                  herdr-program "--session" session))
            (ghostel-exec buffer herdr-program (list "--session" session))))
        (with-current-buffer buffer
          (setq herdr--client-session session)
          (herdr-client-mode 1))
        (cons buffer t)))))

;;;; Moving between herdr panes and Emacs windows

(defun herdr--focused-pane (session)
  (alist-get 'pane_id (seq-find (lambda (p) (eq (alist-get 'focused p) t))
                                (alist-get 'panes (herdr--run session "pane" "list")))))

(defun herdr--focused-agent (session)
  "Return the focused agent in this Emacs workspace's SESSION."
  (let* ((pane (herdr--focused-pane session))
         (agent (and pane (herdr--agent session pane))))
    (unless agent
      (user-error "No focused agent in this workspace; focus one with SPC a j"))
    (when-let* ((space (herdr--find-space
                        session (herdr--workspace)
                        (directory-file-name (expand-file-name (herdr--root))))))
      (unless (equal (alist-get 'workspace_id agent)
                     (alist-get 'workspace_id space))
        (user-error "The focused agent belongs to another space; focus one in %s"
                    (herdr--workspace))))
    agent))

(defun herdr--navigate (direction)
  "Focus the herdr pane in DIRECTION, or the Emacs window there at herdr's edge.
DIRECTION is left, right, up, or down, as in vim-tmux-navigator."
  (let* ((session herdr--client-session)
         (pane (and session (herdr--focused-pane session)))
         (edges (and pane (alist-get 'edges (herdr--run session "pane" "edges" "--pane" pane)))))
    (if (and edges (not (eq (alist-get direction edges) t)))
        (herdr--run session "pane" "focus" "--direction" (symbol-name direction) "--pane" pane)
      (pcase direction
        ('left (windmove-left)) ('right (windmove-right))
        ('up (windmove-up)) ('down (windmove-down))))))

(defun herdr-navigate-left () "Pane or window to the left." (interactive) (herdr--navigate 'left))
(defun herdr-navigate-right () "Pane or window to the right." (interactive) (herdr--navigate 'right))
(defun herdr-navigate-up () "Pane or window above." (interactive) (herdr--navigate 'up))
(defun herdr-navigate-down () "Pane or window below." (interactive) (herdr--navigate 'down))

(defvar herdr-client-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-h") #'herdr-navigate-left)
    (define-key map (kbd "C-j") #'herdr-navigate-down)
    (define-key map (kbd "C-k") #'herdr-navigate-up)
    (define-key map (kbd "C-l") #'herdr-navigate-right)
    map))

(define-minor-mode herdr-client-mode
  "In a herdr client buffer, C-h/j/k/l move between herdr panes, then Emacs windows."
  :keymap herdr-client-mode-map)

(defun herdr--side-window ()
  (seq-find (lambda (w) (and (eq (window-parameter w 'window-side) 'right)
                             (string-prefix-p "*herdr: " (buffer-name (window-buffer w)))))
            (window-list)))

(defun herdr--display (session)
  "Show SESSION's herdr client in the right side window and select it.
Return non-nil if the client was just started."
  (pcase-let ((`(,buffer . ,fresh) (herdr--client-buffer session)))
    (select-window
     (display-buffer buffer
                     `((display-buffer-in-side-window)
                       (side . right) (slot . 0)
                       (window-width . ,herdr-window-width))))
    fresh))

(defun herdr--show (session pane)
  "Show SESSION's herdr client with the agent in PANE focused."
  (let ((fresh (herdr--display session)))
    (herdr--run session "agent" "focus" pane)
    ;; A client that is still connecting misses the first focus; repeat it
    ;; once the handshake has had time to finish.
    (when fresh
      (run-at-time 1 nil (lambda () (ignore-errors (herdr--run session "agent" "focus" pane)))))))

;;;###autoload
(defun herdr-switch (pane)
  "Show the agent in PANE from this workspace's session; asks which when there are several."
  (interactive (list (herdr--read-agent (herdr--session) "Agent: ")))
  (herdr--show (herdr--session) pane))

;;;###autoload
(defun herdr-toggle ()
  "Hide the herdr window if it is showing, else show this workspace's session."
  (interactive)
  (if-let* ((w (herdr--side-window)))
      (delete-window w)
    (herdr--display (herdr--session))))

;;;###autoload
(defun herdr-prompt (pane text)
  "Submit TEXT as a prompt to the agent in PANE and show the agent."
  (interactive
   (let* ((session (herdr--session))
          (pane (herdr--read-agent session "Prompt agent: ")))
     (list pane (read-string (format "Prompt %s: " (herdr--agent-label (herdr--agent session pane)))))))
  (herdr--run (herdr--session) "agent" "prompt" pane text)
  (herdr--show (herdr--session) pane)
  (herdr--poll))

;;;###autoload
(defun herdr-send-region (beg end)
  "Type an @path#L1-L2 reference into the focused agent, without submitting.
Also copy it to the clipboard, then select the agent window."
  (interactive "r")
  (unless buffer-file-name (user-error "Buffer is not visiting a file"))
  (let* ((session (herdr--session))
         (agent (herdr--focused-agent session))
         (pane (alist-get 'pane_id agent))
         (path (file-relative-name buffer-file-name (herdr--root)))
         (ref (format "@%s#L%d-L%d" path (line-number-at-pos beg) (line-number-at-pos (max beg (1- end))))))
    (kill-new ref)
    (when (and (fboundp 'evil-visual-state-p) (evil-visual-state-p)) (evil-exit-visual-state))
    (herdr--run session "pane" "send-text" pane (concat ref " "))
    (herdr--show session pane)
    (message "Sent %s to %s" ref (herdr--agent-label agent))))

(defun herdr--rename (session pane new-name)
  "Rename the agent in PANE to NEW-NAME, preserving its space label.
Rename the tab too when it still has the agent's old name."
  (let* ((agent (herdr--agent session pane))
         (ws-id (alist-get 'workspace_id agent))
         (pane-info (seq-find (lambda (item) (equal (alist-get 'pane_id item) pane))
                              (alist-get 'panes (herdr--run session "pane" "list"
                                                                 "--workspace" ws-id))))
         (tab-id (alist-get 'tab_id pane-info))
         (tab (and tab-id
                   (seq-find (lambda (item) (equal (alist-get 'tab_id item) tab-id))
                             (alist-get 'tabs (herdr--run session "tab" "list"
                                                              "--workspace" ws-id)))))
         (rename-tab (and tab
                          (equal (herdr--tab-base-label (alist-get 'label tab))
                                 (alist-get 'name agent)))))
    (herdr--run session "agent" "rename" pane new-name)
    (when rename-tab
      (herdr--run session "tab" "rename" tab-id new-name))
    (remhash session herdr--tab-status-last-sync)
    (herdr--poll)))

;;;###autoload
(defun herdr-rename (pane new-name)
  "Rename the agent in PANE to NEW-NAME."
  (interactive
   (let* ((session (herdr--session))
          (pane (herdr--read-agent session "Rename agent: "))
          (label (herdr--agent-label (herdr--agent session pane))))
     (list pane (read-string (format "New name for %s: " label) (alist-get 'name (herdr--agent session pane))))))
  (herdr--rename (herdr--session) pane new-name)
  (message "Renamed to %s" new-name))

(defun herdr--kill (session pane)
  "Close PANE in SESSION."
  (herdr--run session "pane" "close" pane)
  (herdr--poll))

;;;###autoload
(defun herdr-kill (pane)
  "Close the agent's PANE (this ends the agent)."
  (interactive (list (herdr--read-agent (herdr--session) "Kill agent: ")))
  (let ((session (herdr--session)))
    (when (yes-or-no-p (format "Kill agent %s in %s? " (herdr--agent-label (herdr--agent session pane)) session))
      (herdr--kill session pane))))

;;;; Cleanup

(defun herdr--idle-pane-p (session pane)
  "Non-nil when PANE runs no agent and its shell is at a prompt.
The shell owns the foreground process group only while nothing runs in it."
  (and (not (alist-get 'agent pane))
       (let ((info (alist-get 'process_info
                              (herdr--run session "pane" "process-info" "--pane" (alist-get 'pane_id pane)))))
         (equal (alist-get 'foreground_process_group_id info) (alist-get 'shell_pid info)))))

(defun herdr--idle-workspaces (session)
  "SESSION's workspaces whose every pane is an idle shell, as (ID . LABEL)."
  (cl-loop for ws in (alist-get 'workspaces (herdr--run session "workspace" "list"))
           for id = (alist-get 'workspace_id ws)
           for panes = (alist-get 'panes (herdr--run session "pane" "list" "--workspace" id))
           when (and panes (seq-every-p (lambda (p) (herdr--idle-pane-p session p)) panes))
           collect (cons id (alist-get 'label ws))))

(defun herdr--delete-session (session)
  (with-temp-buffer
    (call-process herdr-program nil t nil "session" "delete" "--json" session)
    (unless (string-match-p "\"deleted\":true" (buffer-string))
      (user-error "herdr session delete %s: %s" session (string-trim (buffer-string))))))

;;;###autoload
(defun herdr-clean ()
  "Delete stopped herdr sessions and close idle spaces, after one confirmation.
Stopped sessions bound to an Emacs workspace, and herdr's default session, are
kept.  Spaces are closed only in running sessions bound to an Emacs workspace;
a space is idle when every pane in it is a shell at its prompt, with no agent."
  (interactive)
  (let* ((bound (hash-table-values herdr--workspace-sessions))
         (sessions (herdr--sessions))
         (stopped (cl-loop for (name . running) in sessions
                           unless (or running (member name bound) (equal name "default"))
                           collect name))
         (idle (cl-loop for (name . running) in sessions
                        when (and running (member name bound))
                        append (mapcar (lambda (ws) (cons name ws)) (herdr--idle-workspaces name)))))
    (if (not (or stopped idle))
        (message "Nothing to clean")
      (with-current-buffer (get-buffer-create "*herdr clean*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (when stopped
            (insert "Delete stopped sessions:\n")
            (dolist (s stopped) (insert "  " s "\n")))
          (when idle
            (insert (if stopped "\n" "") "Close idle spaces:\n")
            (pcase-dolist (`(,session ,id . ,label) idle)
              (insert (format "  %s: %s (%s)\n" session label id)))))
        (special-mode)
        (goto-char (point-min)))
      (let ((window (display-buffer "*herdr clean*")))
        (unwind-protect
            (when (yes-or-no-p (format "Delete %d session(s) and close %d space(s)? "
                                       (length stopped) (length idle)))
              (dolist (s stopped) (herdr--delete-session s))
              (pcase-dolist (`(,session ,id . ,_label) idle)
                (herdr--run session "workspace" "close" id))
              (herdr--poll)
              (message "Deleted %d session(s), closed %d space(s)" (length stopped) (length idle)))
          (when (window-live-p window) (quit-window t window)))))))

;;;; Polling and tab-bar glyphs

(defun herdr--poll ()
  "Refresh agent states and tab labels; notify on new attention."
  (let (seen)
    (maphash
     (lambda (_ws session)
       (unless (member session seen)
         (push session seen)
         (when (herdr--session-running-p session)
           (let* ((old (gethash session herdr--agents))
                  (fetched (condition-case nil
                               (cons t (herdr--agents session))
                             (error nil))))
             (when fetched
               (let ((new (cdr fetched)))
                 (when herdr-notify
                   (dolist (a new)
                     (let* ((pane (alist-get 'pane_id a))
                            (was (alist-get 'agent_status (seq-find (lambda (o) (equal (alist-get 'pane_id o) pane)) old)))
                            (now (alist-get 'agent_status a)))
                       (when (and (equal was "working") (member now '("blocked" "done")))
                         (herdr--notify (format "%s %s" (herdr--agent-label a) now) (or (alist-get 'terminal_title_stripped a) ""))))))
                 (puthash session new herdr--agents)
                 ;; Pane and tab listings are costlier than agent polling.
                 ;; Check immediately on status changes, and periodically for
                 ;; manual tab renames or moves made inside the Herdr client.
                 (let ((last (gethash session herdr--tab-status-last-sync))
                       (now (float-time)))
                   (when (or (not last)
                             (>= (- now last) 10)
                             (not (equal
                                   (mapcar (lambda (a) (cons (alist-get 'pane_id a)
                                                             (alist-get 'agent_status a))) old)
                                   (mapcar (lambda (a) (cons (alist-get 'pane_id a)
                                                             (alist-get 'agent_status a))) new))))
                     (when (ignore-errors (herdr--sync-tab-status session new) t)
                       (puthash session now herdr--tab-status-last-sync))))))))))
     herdr--workspace-sessions))
  (force-mode-line-update t)
  ;; Refresh open overviews less often than agent state: listing every pane and
  ;; its foreground process is more expensive than polling agent statuses.
  (dolist (buffer (buffer-list))
    (when (and (eq (buffer-local-value 'major-mode buffer) 'herdr-overview-mode)
               (get-buffer-window buffer t)
               (>= (- (float-time)
                      (buffer-local-value 'herdr-overview--last-refresh buffer)) 10))
      (with-current-buffer buffer
        (setq herdr-overview--last-refresh (float-time))
        (let ((id (tabulated-list-get-id)))
          (setq tabulated-list-entries (herdr--overview-entries))
          (tabulated-list-print t)
          (when id (goto-char (point-min))
                (while (and (not (eobp)) (not (equal (tabulated-list-get-id) id))) (forward-line 1))))))))
  ;; The optional Emacs MCP dashboard derives each row's state from this poll.
  ;; Keep it fresh without making Herdr depend on the bridge.
  (when (fboundp 'emacs-mcp-activity-refresh)
    (dolist (buffer (buffer-list))
      (when (eq (buffer-local-value 'major-mode buffer) 'emacs-mcp-activity-mode)
        (with-current-buffer buffer (emacs-mcp-activity-refresh)))))

(defun herdr--notify (title body)
  (message "[herdr] %s: %s" title body)
  ;; Use a separate User Notifications helper instead of AppleScript. The
  ;; latter makes macOS ask Emacs for cross-application AppleEvents access.
  (when-let* ((notifier (executable-find "terminal-notifier"))
              (process
               (start-process
                (format "herdr-notifier-%s" (float-time)) nil notifier
                "-title" title
                "-message" body
                "-sender" "org.gnu.Emacs"
                "-activate" "org.gnu.Emacs")))
    (set-process-query-on-exit-flag process nil)))

(defun herdr--agent-count-glyphs (agents)
  "Compact state counts for AGENTS."
  (let ((working (seq-count (lambda (a) (equal (alist-get 'agent_status a) "working")) agents))
        (attention (seq-count (lambda (a) (member (alist-get 'agent_status a) '("blocked" "done"))) agents))
        (idle (seq-count (lambda (a) (equal (alist-get 'agent_status a) "idle")) agents)))
    (string-join
     (delq nil
           (list (when (> working 0) (propertize (format "●%d" working) 'face 'herdr-working))
                 (when (> attention 0) (propertize (format "◆%d" attention) 'face 'herdr-attention))
                 (when (> idle 0) (propertize (format "○%d" idle) 'face 'shadow))))
     " ")))

(defun herdr-workspace-glyph (workspace)
  "Tab-bar glyph for WORKSPACE from its session's agent states, e.g. \"●2◆1\".
WORKSPACE may be a list of workspaces, whose agents are counted together."
  (herdr--agent-count-glyphs
   (cl-loop for ws in (ensure-list workspace)
            for session = (gethash ws herdr--workspace-sessions)
            when session append (gethash session herdr--agents))))

;;;; Overview

(defvar herdr--overview-process-cache (make-hash-table :test #'equal)
  "Recent foreground command summaries, keyed by (SESSION . PANE).")

(defun herdr--overview-process (session pane)
  "Return the foreground command in PANE, or nil at the shell prompt.
Cache the query briefly to avoid repeated process inspection."
  (let* ((key (cons session pane))
         (cached (gethash key herdr--overview-process-cache)))
    (if (and cached (< (- (float-time) (car cached)) 10))
        (cdr cached)
      (let* ((info (alist-get 'process_info
                             (ignore-errors (herdr--run session "pane" "process-info"
                                                        "--pane" pane))))
             (running (not (equal (alist-get 'foreground_process_group_id info)
                                  (alist-get 'shell_pid info))))
             (process (car (last (alist-get 'foreground_processes info))))
             (raw (and running
                       (or (alist-get 'cmdline process)
                           (let ((argv (alist-get 'argv process)))
                             (when (listp argv) (string-join argv " ")))
                           (alist-get 'name process)
                           "running process")))
             (command (and (stringp raw)
                           (string-trim (replace-regexp-in-string "[[:cntrl:]]+" " " raw)))))
        (puthash key (cons (float-time) command) herdr--overview-process-cache)
        command))))

(defvar herdr-overview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'herdr-overview-visit)
    (define-key map (kbd "TAB") #'herdr-overview-toggle-space)
    (define-key map (kbd "g") #'herdr-overview-refresh)
    (define-key map (kbd "r") #'herdr-overview-rename)
    (define-key map (kbd "x") #'herdr-overview-kill)
    (define-key map [mouse-3] #'herdr-overview-menu)
    map))

(defcustom herdr-context-window 1000000
  "Context window, in tokens, the overview measures Claude's context against."
  :type 'integer)

(defconst herdr-overview--columns
  [("Project / space / pane" 38 nil) ("Kind" 8 nil) ("State" 13 nil)
   ("Context" 16 nil :right-align t) ("Model" 9 nil) ("Branch" 24 nil)
   ("Up" 5 nil :right-align t) ("Last" 5 nil :right-align t) ("Activity" 30 nil)]
  "Columns in the Herdr overview.")

(defun herdr-overview--cells (name kind state &optional activity stats)
  "An overview row's cells.  STATS is a plist of :context :model :branch :up :last."
  (vector name kind state
          (or (plist-get stats :context) "") (or (plist-get stats :model) "")
          (or (plist-get stats :branch) "") (or (plist-get stats :up) "")
          (or (plist-get stats :last) "") (or activity "")))

(defun herdr-overview--age (ns)
  "Time since NS (nanoseconds since the epoch), as 45s, 12m, 3h or 2d."
  (if (not (numberp ns)) ""
    (let ((s (max 0 (- (float-time) (/ ns 1e9)))))
      (propertize (cond ((< s 60) (format "%ds" s)) ((< s 3600) (format "%dm" (/ s 60)))
                        ((< s 86400) (format "%dh" (/ s 3600))) (t (format "%dd" (/ s 86400))))
                  'face 'shadow))))

(defun herdr-overview--context (tokens)
  "TOKENS of context as \"239k ▰▰▱▱▱ 24%\", colored as it fills."
  (if (not (numberp tokens)) ""
    (let* ((ratio (min 1.0 (/ (float tokens) herdr-context-window)))
           (filled (round (* ratio 5)))
           (face (cond ((>= ratio 0.8) 'error) ((>= ratio 0.5) 'warning) (t 'success))))
      (concat (format "%dk " (round tokens 1000))
              (propertize (make-string filled ?▰) 'face face)
              (propertize (make-string (- 5 filled) ?▱) 'face 'shadow)
              (format " %2d%%" (round (* 100 ratio)))))))

(defun herdr-overview--model (model)
  "MODEL shortened for the overview: claude-opus-5-5 -> opus 5.5."
  (if (not (stringp model)) ""
    (let ((m (replace-regexp-in-string "\\`claude-" "" model)))
      (if (string-match "\\`\\([a-z]+\\)-\\([0-9]+\\)-\\([0-9]+\\)" m)
          (format "%s %s.%s" (match-string 1 m) (match-string 2 m) (match-string 3 m))
        m))))

(defun herdr-overview--agent-stats (session agent)
  "Stats plist for AGENT in SESSION, from its Claude transcript."
  (when-let* ((root (herdr-overview--root session agent))
              (stats (gethash root herdr--claude-stats)))
    (list :context (herdr-overview--context (alist-get 'context_tokens stats))
          :model (herdr-overview--model (alist-get 'model stats))
          :branch (or (alist-get 'branch stats) "")
          :up (herdr-overview--age (alist-get 'started_ns stats))
          :last (herdr-overview--age (alist-get 'last_ns stats)))))

(defun herdr--git-branch (dir)
  "DIR's checked-out branch, read from .git/HEAD (worktrees too), or nil."
  (ignore-errors
    (let* ((dot (expand-file-name ".git" dir))
           (gitdir (if (file-regular-p dot)
                       (with-temp-buffer
                         (insert-file-contents dot)
                         (and (re-search-forward "^gitdir: \\(.*\\)$" nil t)
                              (expand-file-name (match-string 1) dir)))
                     dot))
           (head (with-temp-buffer
                   (insert-file-contents (expand-file-name "HEAD" gitdir))
                   (string-trim (buffer-string)))))
      (if (string-prefix-p "ref: refs/heads/" head) (substring head 16)
        (substring head 0 (min 8 (length head)))))))

(defvar-local herdr-overview--collapsed nil
  "Space keys hidden in this overview buffer.")

(defun herdr-overview-rename (&optional row)
  "Rename the agent or shell on ROW, or at point."
  (interactive)
  (setq row (or row (tabulated-list-get-id)))
  (pcase row
    (`(agent ,_workspace ,session ,pane . ,_)
     (let* ((agent (herdr--agent session pane))
            (new (read-string (format "New name for %s: " (herdr--agent-label agent))
                              (alist-get 'name agent))))
       (unless (string-empty-p (string-trim new))
         (herdr--rename session pane new)
         (herdr-overview-refresh))))
    (`(terminal ,_workspace ,session ,_pane ,tab ,_space)
     (let ((new (read-string "New shell tab name: ")))
       (unless (string-empty-p (string-trim new))
         (herdr--run session "tab" "rename" tab new)
         (herdr-overview-refresh))))
    (_ (user-error "Select an agent or shell to rename"))))

(defun herdr-overview-kill (&optional row)
  "Close the agent or shell on ROW, or at point, after confirmation."
  (interactive)
  (setq row (or row (tabulated-list-get-id)))
  (pcase row
    (`(agent ,_workspace ,session ,pane . ,_)
     (when (yes-or-no-p (format "Kill agent %s in %s? "
                                (herdr--agent-label (herdr--agent session pane)) session))
       (herdr--kill session pane)
       (herdr-overview-refresh)))
    (`(terminal ,_workspace ,session ,pane . ,_)
     (when (yes-or-no-p (format "Close shell %s in %s? " pane session))
       (herdr--run session "pane" "close" pane)
       (herdr-overview-refresh)))
    (_ (user-error "Select an agent or shell to close"))))

(defun herdr-overview-copy-id ()
  "Copy the selected space or pane ID."
  (interactive)
  (let ((row (tabulated-list-get-id)))
    (unless row (user-error "Select a Herdr space or pane"))
    (kill-new (nth 3 row))
    (message "Copied %s" (nth 3 row))))

(defun herdr-overview-menu (event)
  "Show actions for the overview row clicked by mouse EVENT."
  (interactive "e")
  (mouse-set-point event)
  (let* ((row (tabulated-list-get-id))
         (kind (car row)))
    (when row
      (popup-menu
       (easy-menu-create-menu
        "Herdr"
        (append
         `([,(pcase kind
                ((or 'subagent 'task 'workflow) "Show parent agent")
                ('space "Visit space")
                ('project "Visit project")
                ('agent "Visit agent")
                (_ "Visit shell"))
            herdr-overview-visit t])
         (pcase kind
           ((or 'space 'project) '(["Fold / expand" herdr-overview-toggle-space t]))
           ((or 'agent 'terminal)
            `(["Rename" herdr-overview-rename t]
              [,(if (eq kind 'agent) "Kill agent" "Close shell")
               herdr-overview-kill t])))
         `([,(pcase kind
                ('subagent "Copy ID")
                ('task "Copy task ID")
                ('workflow "Copy workflow ID")
                (_ "Copy ID"))
            herdr-overview-copy-id t]
           ["Refresh" herdr-overview-refresh t])))
       event))))

(define-derived-mode herdr-overview-mode tabulated-list-mode "herdr"
  "Spaces, agents, shells, and Claude work in Herdr sessions."
  (setq tabulated-list-format herdr-overview--columns)
  (setq herdr-overview--collapsed (make-hash-table :test #'equal))
  (setq mode-line-format nil)   ; the column header already says what this is; save the row
  (tabulated-list-init-header))

(defvar-local herdr-overview--scope 'all
  "Which workspaces this overview buffer lists: `all', or a workspace name.")

(defvar-local herdr-overview--last-refresh 0
  "Time this overview last fetched spaces and panes from Herdr.")

(defun herdr-overview-toggle-space (&optional row)
  "Fold or expand the space at point."
  (interactive)
  (setq row (or row (tabulated-list-get-id)))
  (unless row
    (user-error "Select a Herdr space or pane"))
  (pcase-let ((`(,kind ,ws ,session ,id . ,rest) row))
    (let* ((space-id (if (eq kind 'space) id (cadr rest)))
           (key (if (eq kind 'project) (list 'project ws) (list ws session space-id))))
      (puthash key (not (gethash key herdr-overview--collapsed))
               herdr-overview--collapsed)
      (herdr-overview-refresh)
      (goto-char (point-min))
      (while (and (not (eobp))
                  (not (equal (tabulated-list-get-id)
                              (if (eq kind 'project) row (list 'space ws session space-id)))))
        (forward-line 1)))))

(defun herdr-overview--button-action (button)
  "Activate the space or pane associated with BUTTON."
  (let ((row (button-get button 'herdr-row)))
    (if (memq (car row) '(space project))
        (herdr-overview-toggle-space row)
      (herdr-overview-visit row))))

(defun herdr-overview--button (label row help)
  "Make LABEL a clickable overview entry for ROW with tooltip HELP."
  (cons label (list 'action #'herdr-overview--button-action
                    'herdr-row row
                    'follow-link t
                    'help-echo help)))

(defun herdr-overview--subagents ()
  "Return a parent ID -> children table from Codex and Claude state."
  (let ((roots (delete-dups (hash-table-values herdr--codex-threads)))
        (children (make-hash-table :test #'equal))
        (program (expand-file-name "bin/codex_subagents.py" user-emacs-directory))
        (claude-program (expand-file-name "bin/claude_subagents.py" user-emacs-directory)))
    (clrhash herdr--claude-sessions)
    (clrhash herdr--claude-tasks)
    (clrhash herdr--claude-workflows)
    (clrhash herdr--claude-stats)
    (when (and roots (file-readable-p program))
      (with-temp-buffer
        (when (eq 0 (apply #'call-process "python3" nil t nil program roots))
          (dolist (child (json-parse-string (buffer-string)
                                           :object-type 'alist :array-type 'list
                                           :null-object nil))
            (let ((parent (alist-get 'parent_thread_id child)))
              (push child (gethash parent children)))))))
    (when (file-readable-p claude-program)
      (with-temp-buffer
        (when (eq 0 (call-process "python3" nil t nil claude-program "--list"))
          (let ((state (json-parse-string (buffer-string)
                                          :object-type 'alist :array-type 'list
                                          :null-object nil)))
            (dolist (root (alist-get 'roots state))
              (puthash (cons (alist-get 'session root) (alist-get 'pane root))
                       (alist-get 'id root) herdr--claude-sessions)
              (puthash (alist-get 'id root) root herdr--claude-stats))
            (dolist (child (alist-get 'children state))
              (push child (gethash (alist-get 'parent_thread_id child) children)))
            (dolist (task (alist-get 'tasks state))
              (push task (gethash (alist-get 'root task) herdr--claude-tasks)))
            (dolist (run (alist-get 'workflows state))
              (push run (gethash (alist-get 'root run) herdr--claude-workflows)))))))
    (maphash (lambda (parent items)
               (puthash parent (nreverse items) children))
             children)
    (dolist (table (list herdr--claude-tasks herdr--claude-workflows))
      (maphash (lambda (root items) (puthash root (nreverse items) table)) table))
    children))

(defun herdr-overview--root (session agent)
  "Return the internal session ID for AGENT in Herdr SESSION."
  (let ((key (cons session (alist-get 'pane_id agent))))
    (pcase (alist-get 'agent agent)
      ("codex" (gethash key herdr--codex-threads))
      ("claude" (gethash key herdr--claude-sessions)))))

(defun herdr-overview--subagent-rows (children parent ws session pane space prefix)
  "Build descendant rows beneath PARENT, indented with PREFIX."
  (let ((items (gethash parent children)) rows)
    (dolist (child items)
      (let* ((last (eq child (car (last items))))
             (id (alist-get 'id child))
             (path (alist-get 'agent_path child))
             (role (alist-get 'role child))
             (id-type (or (alist-get 'id_kind child) "thread"))
             (short-id (substring id 0 (min 8 (length id))))
             (name (or (alist-get 'agent_nickname child)
                       (and (stringp path) (file-name-nondirectory path))
                       role "subagent"))
             (row (list 'subagent ws session id pane space parent)))
        (push (list row
                    (herdr-overview--cells
                     (herdr-overview--button
                      (concat (propertize (concat prefix (if last "└─ " "├─ ")) 'face 'shadow)
                              name)
                      row (format "Show parent agent · %s %s" id-type id))
                     "subagent" (or (alist-get 'status child) "")
                     (or path (format "%s %s" id-type short-id))))
              rows)
        (setq rows (nconc (nreverse (herdr-overview--subagent-rows
                                    children id ws session pane space
                                    (concat prefix (if last "   " "│  "))))
                          rows))))
    (nreverse rows)))

(defun herdr-overview--claude-rows (children root ws session pane space prefix)
  "Build Claude task, workflow, and subagent rows beneath ROOT."
  (let* ((tasks (gethash root herdr--claude-tasks))
         (workflows (gethash root herdr--claude-workflows))
         (work (append (mapcar (lambda (task) (cons 'task task)) tasks)
                       (mapcar (lambda (run) (cons 'workflow run)) workflows)))
         (subagents (herdr-overview--subagent-rows
                     children root ws session pane space prefix))
         rows)
    (dolist (item work)
      (let* ((kind (car item))
             (record (cdr item))
             (id (alist-get 'id record))
             (last (and (eq item (car (last work))) (null subagents)))
             (row (list kind ws session id pane space root))
             (title (or (alist-get 'title record) id)))
        (push (list row
                    (herdr-overview--cells
                     (herdr-overview--button
                      (concat (propertize (concat prefix (if last "└─ " "├─ ")) 'face 'shadow)
                              title)
                      row "Click to show Claude agent")
                     (symbol-name kind)
                     (or (alist-get 'status record) "")
                     (format "%s %s" (symbol-name kind) id)))
              rows)))
    (append (nreverse rows) subagents)))

(defun herdr-overview--agent-rows (children agent ws session space prefix)
  "Return overview children for AGENT with display PREFIX."
  (when-let* ((root (herdr-overview--root session agent)))
    (let ((pane (alist-get 'pane_id agent)))
      (if (equal (alist-get 'agent agent) "claude")
          (herdr-overview--claude-rows children root ws session pane space prefix)
        (herdr-overview--subagent-rows
         children root ws session pane space prefix)))))

(defun herdr-overview--project (ws)
  "The project workspace WS belongs to: \"web\" for \"web@fix\"."
  (car (split-string ws "@")))

(defun herdr-overview--workspace-order ()
  "Bound workspaces in the tab bar's order, else by name."
  (let ((bound (hash-table-keys herdr--workspace-sessions)))
    (if (fboundp 'workspace-names)
        (append (seq-filter (lambda (w) (member w bound)) (workspace-names))
                (seq-remove (lambda (w) (member w (workspace-names))) bound))
      (sort bound #'string<))))

(defun herdr-overview--child-label (ws root)
  "How child workspace WS shows under its project: ⎇ branch for a worktree."
  (let ((name (substring ws (1+ (string-search "@" ws)))))
    (if (and root (file-regular-p (expand-file-name ".git" root)))
        (concat "⎇ " name) name)))

(defun herdr-overview--collapsed-p (key)
  (and (hash-table-p herdr-overview--collapsed) (gethash key herdr-overview--collapsed)))

(defun herdr-overview--plural (n word)
  (format "%d %s%s" n word (if (= n 1) "" "s")))

(defun herdr-overview--space-rows (children ws session space indent label)
  "Rows for SPACE of workspace WS in SESSION: a header, then its panes.
INDENT prefixes every row, LABEL names the header."
  (let* ((space-id (alist-get 'workspace_id space))
         (panes (alist-get 'panes (herdr--run session "pane" "list" "--workspace" space-id)))
         (tabs (alist-get 'tabs (herdr--run session "tab" "list" "--workspace" space-id)))
         (last-pane (car (last panes)))
         (pane-ids (mapcar (lambda (pane) (alist-get 'pane_id pane)) panes))
         (space-agents (seq-filter (lambda (agent) (member (alist-get 'pane_id agent) pane-ids))
                                   (gethash session herdr--agents)))
         (roots (delq nil (mapcar (lambda (agent) (herdr-overview--root session agent)) space-agents)))
         (agent-count (length space-agents))
         (shell-count (- (length panes) agent-count))
         (subagent-count
          (cl-loop for agent in space-agents
                   for root = (herdr-overview--root session agent)
                   sum (if root (length (herdr-overview--subagent-rows
                                         children root ws session (alist-get 'pane_id agent) space-id ""))
                         0)))
         (task-count (cl-loop for root in roots sum (length (gethash root herdr--claude-tasks))))
         (workflow-count (cl-loop for root in roots sum (length (gethash root herdr--claude-workflows))))
         (context (cl-loop for root in roots
                           sum (or (alist-get 'context_tokens (gethash root herdr--claude-stats)) 0)))
         (last-ns (or (cl-loop for root in roots
                               maximize (or (alist-get 'last_ns (gethash root herdr--claude-stats)) 0))
                      0))
         (dir (or (and (boundp 'workspace-roots) (gethash ws workspace-roots))
                  (alist-get 'cwd (car panes))))
         (collapsed (herdr-overview--collapsed-p (list ws session space-id)))
         (row (list 'space ws session space-id))
         rows)
    (push (list row
                (herdr-overview--cells
                 (herdr-overview--button
                  (concat indent (propertize (if collapsed "▸ " "▾ ") 'face 'shadow)
                          (propertize label 'face 'font-lock-function-name-face))
                  row (if collapsed "Click to expand space" "Click to fold space"))
                 (propertize "space" 'face 'shadow)
                 (herdr--agent-count-glyphs space-agents)
                 (propertize
                  (string-join
                   (delq nil (list (herdr-overview--plural agent-count "agent")
                                   (herdr-overview--plural shell-count "shell")
                                   (and (> subagent-count 0) (herdr-overview--plural subagent-count "subagent"))
                                   (and (> task-count 0) (herdr-overview--plural task-count "task"))
                                   (and (> workflow-count 0) (herdr-overview--plural workflow-count "workflow"))))
                   " · ")
                  'face 'shadow)
                 (list :context (if (> context 0) (propertize (format "%dk total" (round context 1000)) 'face 'shadow) "")
                       :branch (or (and dir (herdr--git-branch dir)) "")
                       :last (if (> last-ns 0) (herdr-overview--age last-ns) ""))))
          rows)
    (unless collapsed
      (dolist (pane panes)
        (let* ((pane-id (alist-get 'pane_id pane))
               (agent (seq-find (lambda (a) (equal (alist-get 'pane_id a) pane-id))
                                (gethash session herdr--agents)))
               (status (and agent (alist-get 'agent_status agent)))
               (title (or (alist-get 'terminal_title_stripped pane)
                          (alist-get 'terminal_title_stripped agent) ""))
               (command (unless agent (herdr--overview-process session pane-id)))
               (tab (seq-find (lambda (item) (equal (alist-get 'tab_id item) (alist-get 'tab_id pane))) tabs))
               (name (if agent (herdr--agent-label agent)
                       (seq-find (lambda (c) (and (stringp c) (not (string-empty-p c))))
                                 (list (alist-get 'label pane) (alist-get 'label tab) pane-id))))
               (row (list (if agent 'agent 'terminal) ws session pane-id (alist-get 'tab_id pane) space-id)))
          (push (list row
                      (herdr-overview--cells
                       (herdr-overview--button
                        (concat indent (propertize (if (eq pane last-pane) "  └─ " "  ├─ ") 'face 'shadow) name)
                        row (if agent "Click to show agent" "Click to show shell"))
                       (if agent (or (alist-get 'agent agent) "agent") "shell")
                       (if agent (concat (herdr--status-glyph status) " " (or status ""))
                         (if command "running" "shell"))
                       (if agent title (or command title))
                       (when agent (herdr-overview--agent-stats session agent))))
                rows)
          (when agent
            (dolist (subrow (herdr-overview--agent-rows
                             children agent ws session space-id
                             (concat indent (if (eq pane last-pane) "     " "  │  "))))
              (push subrow rows))))))
    (nreverse rows)))

(defun herdr--overview-entries ()
  "Overview rows, grouped by project in tab-bar order.
A project with worktrees or sub-workspaces gets a header row, with its own
spaces and each child's nested beneath it."
  (let ((children (herdr-overview--subagents)) groups rows)
    ;; (PROJECT . ((WS . SESSION) ...)), in order.
    (dolist (ws (herdr-overview--workspace-order))
      (let ((session (gethash ws herdr--workspace-sessions)))
        (when (and (or (eq herdr-overview--scope 'all)
                       (equal (herdr-overview--project ws) (herdr-overview--project herdr-overview--scope)))
                   (herdr--session-running-p session))
          (let* ((project (herdr-overview--project ws))
                 (group (assoc project groups)))
            (if group (setcdr group (append (cdr group) (list (cons ws session))))
              (push (list project (cons ws session)) groups))))))
    (dolist (group (nreverse groups))
      (let* ((project (car group))
             (members (cdr group))
             (nested (seq-some (lambda (m) (string-search "@" (car m))) members))
             (key (list 'project project))
             (collapsed (and nested (herdr-overview--collapsed-p key))))
        (when nested
          (let ((agents (cl-loop for (_ . session) in members append (gethash session herdr--agents))))
            (push (list (list 'project project nil project)
                        (herdr-overview--cells
                         (herdr-overview--button
                          (concat (propertize (if collapsed "▸ " "▾ ") 'face 'shadow)
                                  (propertize project 'face '(:inherit font-lock-keyword-face :weight bold)))
                          (list 'project project nil project)
                          (if collapsed "Click to expand project" "Click to fold project"))
                         (propertize "project" 'face 'shadow)
                         (herdr--agent-count-glyphs agents)
                         (propertize (format "%s · %s"
                                             (herdr-overview--plural (length members) "workspace")
                                             (herdr-overview--plural (length agents) "agent"))
                                     'face 'shadow)))
                  rows)))
        (unless collapsed
          (pcase-dolist (`(,ws . ,session) members)
            (let ((root (and (boundp 'workspace-roots) (gethash ws workspace-roots))))
              (dolist (space (alist-get 'workspaces (herdr--run session "workspace" "list")))
                (let* ((space-label (or (alist-get 'label space) (alist-get 'workspace_id space)))
                       (label (cond ((not nested) (if (equal space-label ws) ws (format "%s › %s" ws space-label)))
                                    ((equal ws project) "base")
                                    (t (herdr-overview--child-label ws root)))))
                  (dolist (r (herdr-overview--space-rows children ws session space
                                                         (if nested "  " "") label))
                    (push r rows)))))))))
    (nreverse rows)))

;;;###autoload
(defun herdr-overview (&optional scope)
  "List Herdr spaces, agents, shells, tasks, and workflows.  RET visits; TAB folds.
SCOPE is `all' (default) or a workspace name; see `herdr-overview-workspace'."
  (interactive)
  (herdr--poll)
  ;; One buffer per scope, so a workspace's table stays that workspace's table
  ;; and the all-workspaces one (home) is separate.
  (let* ((scope (or scope 'all))
         (buffer (get-buffer-create (if (eq scope 'all) "*herdr overview*" (format "*herdr overview: %s*" scope)))))
    (with-current-buffer buffer
      (unless (and (eq major-mode 'herdr-overview-mode)
                   (equal tabulated-list-format herdr-overview--columns))
        (herdr-overview-mode))
      (setq herdr-overview--scope scope)
      (herdr-overview-refresh))
    ;; Keep the dashboard below code while the terminal client stays on the right.
    (select-window
     (display-buffer buffer
                     '((display-buffer-reuse-window display-buffer-at-bottom)
                       (window-height . (lambda (w) (fit-window-to-buffer w 12 4)))
                       (preserve-size . (nil . t)))))))

;;;###autoload
(defun herdr-overview-workspace ()
  "List this workspace's Herdr spaces, agents, and terminals."
  (interactive)
  (herdr-overview (herdr--workspace)))

(defun herdr-overview-refresh ()
  (interactive)
  (when (called-interactively-p 'interactive)
    (clrhash herdr--overview-process-cache))
  (setq herdr-overview--last-refresh (float-time))
  (herdr--poll)
  (setq tabulated-list-entries (herdr--overview-entries))
  (tabulated-list-print t))

(defun herdr-overview-visit (&optional row)
  "Switch to the selected space, agent, or terminal."
  (interactive)
  (setq row (or row (tabulated-list-get-id)))
  (unless row
    (user-error "Select a Herdr space, agent, or terminal"))
  (pcase-let ((`(,kind ,ws ,session ,id . ,rest) row))
    (when (and (fboundp 'persp-switch) (not (equal ws (herdr--workspace)))
               (or (not (eq kind 'project)) (member ws (persp-names))))
      (persp-switch ws))
    (pcase kind
      ('agent (herdr--show session id))
      ((or 'subagent 'task 'workflow) (herdr--show session (car rest)))
      ('terminal
       (herdr--run session "workspace" "focus" (cadr rest))
       (herdr--run session "tab" "focus" (car rest))
       (herdr--display session))
      ('space
       (herdr--run session "workspace" "focus" id)
       (herdr--display session))
      ('project nil))))

;;;; Mode

;;;###autoload
(define-minor-mode herdr-mode
  "Poll Herdr agent states and show them in Emacs and Herdr tab bars."
  :global t
  (when herdr--poll-timer (cancel-timer herdr--poll-timer) (setq herdr--poll-timer nil))
  (if herdr-mode
      (progn
        (setq herdr--poll-timer (run-with-timer 1 herdr-poll-interval #'herdr--poll))
        (when (boundp 'workspace-status-function)
          (setq workspace-status-function #'herdr-workspace-glyph)))
    (when (boundp 'workspace-status-function)
      (setq workspace-status-function nil))))

(provide 'herdr)
;;; herdr.el ends here
