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
;; - Each Emacs workspace (perspective) is bound to one herdr session.  The
;;   first agent command in a workspace asks which session to use, offering
;;   the running ones plus a new one named after the workspace.  Sessions
;;   outlive Emacs: restart, and `herdr-switch' reattaches.
;; - Agents run in herdr panes.  Emacs shows the session in a side window
;;   through a ghostel terminal running the full herdr client, so herdr's
;;   own tabs and shells work there too; agent commands focus that client
;;   on the agent.
;; - Agent states are polled and shown as glyphs in the tab bar
;;   (● working, ◆ needs you, ○ idle) and in `herdr-overview', which lists
;;   every agent in every session.
;;
;; Commands: `herdr-start', `herdr-switch', `herdr-toggle', `herdr-prompt', `herdr-rename',
;; `herdr-send-region', `herdr-overview', `herdr-kill', `herdr-bind-session', `herdr-clean'.
;; Turn on `herdr-mode' for the polling and tab-bar integration.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'json)

(declare-function persp-current-name "perspective")
(declare-function persp-names "perspective")
(declare-function persp-switch "perspective")
(declare-function ghostel-exec "ghostel")
(declare-function workspace-root "workspaces")
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

(defvar herdr--poll-timer nil)

(defvar-local herdr--client-session nil
  "The herdr session this buffer's client is attached to.")

;;;; herdr CLI

(defun herdr--run (session &rest args)
  "Run herdr with ARGS against SESSION; return the parsed JSON result.
Signal a user error on failure."
  (with-temp-buffer
    (let* ((process-environment (herdr--environment))
           (args (append (when session (list "--session" session)) args))
           (code (apply #'call-process herdr-program nil t nil args))
           (out (string-trim (buffer-string))))
      (cond
       ((and (eq code 0) (string-empty-p out)) nil)   ; some commands (pane send-text) print nothing on success
       ((not (string-prefix-p "{" out))
        (user-error "herdr %s: %s" (string-join args " ") out))
       (t
      (let* ((json (json-parse-string out :object-type 'alist :array-type 'list))
             (err (alist-get 'error json)))
        (when err
          (signal 'herdr-error (list (alist-get 'code err) (alist-get 'message err))))
        (alist-get 'result json)))))))

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

(defun herdr--session-name-for (workspace)
  "A herdr session name derived from WORKSPACE."
  (let ((s (replace-regexp-in-string "[^A-Za-z0-9_-]" "-" workspace)))
    (if (string-empty-p s) "emacs" s)))

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

(defun herdr--session ()
  "This workspace's session, asking for one the first time.
A bound session that was stopped or deleted is started again."
  (if-let* ((session (gethash (herdr--workspace) herdr--workspace-sessions)))
      (herdr--ensure-session session)
    (call-interactively #'herdr-bind-session)))

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

;;;###autoload
(defun herdr-start (kind name)
  "Start a new agent of KIND called NAME in this workspace's session, at the workspace root.
NAME also labels the agent's herdr workspace.  KIND is `herdr-default-kind'
unless given a prefix argument."
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
         (ws (herdr--run session "workspace" "create" "--cwd" root "--label" name))
         (pane (alist-get 'pane_id (alist-get 'root_pane ws))))
    (message "Starting %s as %s in %s…" kind name (abbreviate-file-name root))
    ;; The new pane's shell takes a moment to come up; herdr refuses to start
    ;; an agent until it is at a prompt. Retry for a few seconds.
    ;; A frontend can use this dynamic launch context to configure a local
    ;; companion process (for example, an editor MCP bridge) without Herdr
    ;; taking a dependency on that frontend.  The actual agent still owns the
    ;; shell process and inherits HERDR_PANE_ID from Herdr.
    (let ((agents--mcp-launch-context
           (list :root root :name name :session session :pane pane)))
      (cl-loop for attempt from 1 to 20
               do (condition-case e
                      (cl-return (apply #'herdr--run session "agent" "start" name "--kind" kind "--pane" pane "--timeout" "90000"
                                        (append (when (fboundp 'agents--launch-arguments)
                                                  (when-let* ((arguments (agents--launch-arguments kind)))
                                                    (cons "--" arguments))))))
                    (herdr-error
                     (if (and (equal (nth 1 e) "agent_pane_busy") (< attempt 20))
                         (sleep-for 0.3)
                       (signal (car e) (cdr e)))))))
    (herdr--poll)
    (herdr--show session pane)))

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
          (ghostel-exec buffer herdr-program (list "--session" session)))
        (with-current-buffer buffer
          (setq herdr--client-session session)
          (herdr-client-mode 1))
        (cons buffer t)))))

;;;; Moving between herdr panes and Emacs windows

(defun herdr--focused-pane (session)
  (alist-get 'pane_id (seq-find (lambda (p) (eq (alist-get 'focused p) t))
                                (alist-get 'panes (herdr--run session "pane" "list")))))

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
  "Hide the herdr side window if it is showing, else show this workspace's session."
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
  "Type an @path#L1-L2 reference for the region into an agent, without submitting.
Also copied to the clipboard.  Point stays in the source buffer."
  (interactive "r")
  (unless buffer-file-name (user-error "Buffer is not visiting a file"))
  (let* ((session (herdr--session))
         (pane (herdr--read-agent session "Send to: "))
         (path (file-relative-name buffer-file-name (herdr--root)))
         (ref (format "@%s#L%d-L%d" path (line-number-at-pos beg) (line-number-at-pos (max beg (1- end)))))
         (source (selected-window)))
    (kill-new ref)
    (when (and (fboundp 'evil-visual-state-p) (evil-visual-state-p)) (evil-exit-visual-state))
    (herdr--run session "pane" "send-text" pane (concat ref " "))
    (herdr--show session pane)
    (select-window source)
    (message "Sent %s to %s" ref (herdr--agent-label (herdr--agent session pane)))))

(defun herdr--rename (session pane new-name)
  "Rename the agent in PANE to NEW-NAME, and its herdr workspace with it.
The workspace is renamed only when it holds just this agent, as the ones
`herdr-start' creates do."
  (let* ((agent (herdr--agent session pane))
         (ws-id (alist-get 'workspace_id agent))
         (ws (seq-find (lambda (w) (equal (alist-get 'workspace_id w) ws-id))
                       (alist-get 'workspaces (herdr--run session "workspace" "list")))))
    (herdr--run session "agent" "rename" pane new-name)
    (when (eql (alist-get 'pane_count ws) 1)
      (herdr--run session "workspace" "rename" ws-id new-name))
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
  "Refresh `herdr--agents' for every bound session; notify on new attention."
  (let (seen)
    (maphash
     (lambda (_ws session)
       (unless (member session seen)
         (push session seen)
         (when (herdr--session-running-p session)
           (let ((old (gethash session herdr--agents))
                 (new (ignore-errors (herdr--agents session))))
             (when herdr-notify
               (dolist (a new)
                 (let* ((pane (alist-get 'pane_id a))
                        (was (alist-get 'agent_status (seq-find (lambda (o) (equal (alist-get 'pane_id o) pane)) old)))
                        (now (alist-get 'agent_status a)))
                   (when (and (equal was "working") (member now '("blocked" "done")))
                     (herdr--notify (format "%s %s" (herdr--agent-label a) now) (or (alist-get 'terminal_title_stripped a) ""))))))
             (puthash session new herdr--agents)))))
     herdr--workspace-sessions))
  (force-mode-line-update t)
  ;; Keep every open overview table current.
  (dolist (buffer (buffer-list))
    (when (and (eq (buffer-local-value 'major-mode buffer) 'herdr-overview-mode)
               (get-buffer-window buffer t))
      (with-current-buffer buffer
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

(defun herdr-workspace-glyph (workspace)
  "Tab-bar glyph for WORKSPACE from its session's agent states, e.g. \"●2◆1\"."
  (if-let* ((session (gethash workspace herdr--workspace-sessions))
            (agents (gethash session herdr--agents)))
      (let ((working (seq-count (lambda (a) (equal (alist-get 'agent_status a) "working")) agents))
            (attention (seq-count (lambda (a) (member (alist-get 'agent_status a) '("blocked" "done"))) agents))
            (idle (seq-count (lambda (a) (equal (alist-get 'agent_status a) "idle")) agents)))
        (string-join
         (delq nil
               (list (when (> working 0) (propertize (format "●%d" working) 'face 'herdr-working))
                     (when (> attention 0) (propertize (format "◆%d" attention) 'face 'herdr-attention))
                     (when (> idle 0) (propertize (format "○%d" idle) 'face 'shadow))))
         " "))
    ""))

;;;; Overview

(defvar herdr-overview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'herdr-overview-visit)
    (define-key map (kbd "g") #'herdr-overview-refresh)
    (define-key map (kbd "r") #'herdr-overview-rename)
    (define-key map (kbd "x") #'herdr-overview-kill)
    map))

(defun herdr-overview-rename ()
  "Rename the agent on this line."
  (interactive)
  (pcase-let ((`(,_workspace ,session ,pane) (tabulated-list-get-id)))
    (let* ((agent (herdr--agent session pane))
           (new (read-string (format "New name for %s: " (herdr--agent-label agent)) (alist-get 'name agent))))
      (herdr--rename session pane new)
      (herdr-overview-refresh))))

(defun herdr-overview-kill ()
  "Kill the agent on this line after confirmation."
  (interactive)
  (pcase-let ((`(,_workspace ,session ,pane) (tabulated-list-get-id)))
    (when (yes-or-no-p (format "Kill agent %s in %s? " (herdr--agent-label (herdr--agent session pane)) session))
      (herdr--kill session pane)
      (herdr-overview-refresh))))

(define-derived-mode herdr-overview-mode tabulated-list-mode "herdr"
  "Every agent in every herdr session bound to a workspace."
  (setq tabulated-list-format [("Workspace" 16 t) ("Session" 14 t) ("Agent" 14 t) ("State" 9 t) ("Doing" 40 nil)])
  (setq mode-line-format nil)   ; the column header already says what this is; save the row
  (tabulated-list-init-header))

(defvar-local herdr-overview--scope 'all
  "Which workspaces this overview buffer lists: `all', or a workspace name.")

(defun herdr--overview-entries ()
  (let (rows)
    (maphash
     (lambda (ws session)
       (dolist (a (and (or (eq herdr-overview--scope 'all) (equal ws herdr-overview--scope))
                       (gethash session herdr--agents)))
         (push (list (list ws session (alist-get 'pane_id a))
                     (vector ws session (herdr--agent-label a)
                             (concat (herdr--status-glyph (alist-get 'agent_status a)) " " (or (alist-get 'agent_status a) ""))
                             (or (alist-get 'terminal_title_stripped a) "")))
               rows)))
     herdr--workspace-sessions)
    (nreverse rows)))

;;;###autoload
(defun herdr-overview (&optional scope)
  "List agents with their state. RET jumps to one, r renames, g refreshes.
SCOPE is `all' (default) or a workspace name; see `herdr-overview-workspace'."
  (interactive)
  (herdr--poll)
  ;; One buffer per scope, so a workspace's table stays that workspace's table
  ;; and the all-workspaces one (home) is separate.
  (let* ((scope (or scope 'all))
         (buffer (get-buffer-create (if (eq scope 'all) "*herdr agents*" (format "*herdr agents: %s*" scope)))))
    (with-current-buffer buffer
      (unless (eq major-mode 'herdr-overview-mode) (herdr-overview-mode))
      (setq herdr-overview--scope scope)
      (herdr-overview-refresh))
    ;; A short strip along the bottom, sized to its rows, above the shell panel.
    (select-window
     (display-buffer buffer
                     '((display-buffer-reuse-window display-buffer-at-bottom)
                       (window-height . (lambda (w) (fit-window-to-buffer w 12 4)))
                       (preserve-size . (nil . t)))))))

;;;###autoload
(defun herdr-overview-workspace ()
  "List this workspace's agents with their state."
  (interactive)
  (herdr-overview (herdr--workspace)))

(defun herdr-overview-refresh ()
  (interactive)
  (herdr--poll)
  (setq tabulated-list-entries (herdr--overview-entries))
  (tabulated-list-print t))

(defun herdr-overview-visit ()
  "Switch to the agent's workspace and show it."
  (interactive)
  (pcase-let ((`(,ws ,session ,pane) (tabulated-list-get-id)))
    (when (and (fboundp 'persp-switch) (not (equal ws (herdr--workspace))))
      (persp-switch ws))
    (herdr--show session pane)))

;;;; Mode

;;;###autoload
(define-minor-mode herdr-mode
  "Poll herdr agent states and show them in the tab bar."
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
