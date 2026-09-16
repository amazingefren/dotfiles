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
;; - Agents run in herdr panes.  Emacs shows one at a time in a side window
;;   through a ghostel terminal attached to that pane.
;; - Agent states are polled and shown as glyphs in the tab bar
;;   (● working, ◆ needs you, ○ idle) and in `herdr-overview', which lists
;;   every agent in every session.
;;
;; Commands: `herdr-start', `herdr-switch', `herdr-toggle', `herdr-prompt', `herdr-rename',
;; `herdr-send-region', `herdr-overview', `herdr-kill', `herdr-bind-session'.
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

;;;; herdr CLI

(defun herdr--run (session &rest args)
  "Run herdr with ARGS against SESSION; return the parsed JSON result.
Signal a user error on failure."
  (with-temp-buffer
    (let* ((args (append (when session (list "--session" session)) args))
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
    (let ((default-directory (expand-file-name "~/")))
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
  "This workspace's session, asking for one the first time."
  (or (gethash (herdr--workspace) herdr--workspace-sessions)
      (call-interactively #'herdr-bind-session)))

;;;; Agents

(defun herdr--agents (session)
  "Live agent list for SESSION from herdr."
  (alist-get 'agents (herdr--run session "agent" "list")))

(defun herdr--agent-names (session)
  (mapcar (lambda (a) (alist-get 'name a)) (herdr--agents session)))

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
  "Pick one of SESSION's agents, showing its state."
  (let* ((agents (herdr--agents session))
         (names (mapcar (lambda (a) (alist-get 'name a)) agents)))
    (unless agents (user-error "No agents in session %s. SPC a s starts one" session))
    (if (= 1 (length names))
        (car names)
      (let ((completion-extra-properties
             `(:annotation-function
               ,(lambda (name)
                  (let ((a (seq-find (lambda (x) (equal (alist-get 'name x) name)) agents)))
                    (format "  %s %s  %s" (herdr--status-glyph (alist-get 'agent_status a))
                            (alist-get 'agent_status a) (or (alist-get 'terminal_title_stripped a) "")))))))
        (completing-read prompt names nil t)))))

(defun herdr--root ()
  (if (fboundp 'workspace-root) (workspace-root) default-directory))

;;;###autoload
(defun herdr-start (kind name)
  "Start a new agent of KIND called NAME in this workspace's session, at the workspace root.
Without a prefix argument KIND is `herdr-default-kind' and NAME is picked for you;
with C-u both are asked."
  (interactive
   (let* ((session (herdr--session))
          (kind (if current-prefix-arg
                    (completing-read "Agent: " herdr-agent-kinds nil t nil nil herdr-default-kind)
                  (herdr--default-kind)))
          (taken (herdr--agent-names session))
          (default (cl-loop for i from 1
                            for n = (if (= i 1) kind (format "%s-%d" kind i))
                            unless (member n taken) return n)))
     (list kind (if current-prefix-arg (read-string "Name: " default) default))))
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
    (herdr--show session name)))

(defun herdr--buffer-name (session name) (format "*herdr: %s/%s*" session name))

(defun herdr--attach-buffer (session name)
  "A ghostel buffer attached to agent NAME in SESSION, created if needed."
  (let ((bname (herdr--buffer-name session name)))
    (or (let ((b (get-buffer bname)))
          (and b (get-buffer-process b) (process-live-p (get-buffer-process b)) b))
        (progn
          (require 'ghostel)
          (when-let* ((old (get-buffer bname))) (kill-buffer old))
          (let ((buffer (get-buffer-create bname)))
            (save-window-excursion
              (ghostel-exec buffer herdr-program (list "--session" session "agent" "attach" name)))
            buffer)))))

(defun herdr--side-window ()
  (seq-find (lambda (w) (and (eq (window-parameter w 'window-side) 'right)
                             (string-prefix-p "*herdr: " (buffer-name (window-buffer w)))))
            (window-list)))

(defun herdr--show (session name)
  "Show agent NAME of SESSION in the right side window and select it."
  (select-window
   (display-buffer (herdr--attach-buffer session name)
                   `((display-buffer-in-side-window)
                     (side . right) (slot . 0)
                     (window-width . ,herdr-window-width)))))

;;;###autoload
(defun herdr-switch (name)
  "Show agent NAME from this workspace's session; asks which when there are several."
  (interactive (list (herdr--read-agent (herdr--session) "Agent: ")))
  (herdr--show (herdr--session) name))

;;;###autoload
(defun herdr-toggle ()
  "Hide the agent window if it is showing, else show the last (or only) agent."
  (interactive)
  (if-let* ((w (herdr--side-window)))
      (delete-window w)
    (let* ((session (herdr--session))
           (names (herdr--agent-names session)))
      (cond ((null names) (call-interactively #'herdr-start))
            ((= 1 (length names)) (herdr--show session (car names)))
            (t (call-interactively #'herdr-switch))))))

(defun herdr--pane (session name)
  (alist-get 'pane_id (seq-find (lambda (a) (equal (alist-get 'name a) name)) (herdr--agents session))))

;;;###autoload
(defun herdr-prompt (name text)
  "Submit TEXT as a prompt to agent NAME and show the agent."
  (interactive
   (let* ((session (herdr--session))
          (name (herdr--read-agent session "Prompt agent: ")))
     (list name (read-string (format "Prompt %s: " name)))))
  (herdr--run (herdr--session) "agent" "prompt" name text)
  (herdr--show (herdr--session) name)
  (herdr--poll))

;;;###autoload
(defun herdr-send-region (beg end)
  "Type an @path#L1-L2 reference for the region into an agent, without submitting.
Also copied to the clipboard.  Point stays in the source buffer."
  (interactive "r")
  (unless buffer-file-name (user-error "Buffer is not visiting a file"))
  (let* ((session (herdr--session))
         (name (herdr--read-agent session "Send to: "))
         (path (file-relative-name buffer-file-name (herdr--root)))
         (ref (format "@%s#L%d-L%d" path (line-number-at-pos beg) (line-number-at-pos (max beg (1- end)))))
         (source (selected-window)))
    (kill-new ref)
    (when (and (fboundp 'evil-visual-state-p) (evil-visual-state-p)) (evil-exit-visual-state))
    (herdr--run session "pane" "send-text" (herdr--pane session name) (concat ref " "))
    (herdr--show session name)
    (select-window source)
    (message "Sent %s to %s" ref name)))

;;;###autoload
(defun herdr-rename (name new-name)
  "Rename agent NAME to NEW-NAME (shown in the picker, overview, and buffer name)."
  (interactive
   (let* ((session (herdr--session))
          (name (herdr--read-agent session "Rename agent: ")))
     (list name (read-string (format "New name for %s: " name) name))))
  (let ((session (herdr--session)))
    (herdr--run session "agent" "rename" name new-name)
    (when-let* ((b (get-buffer (herdr--buffer-name session name))))
      (with-current-buffer b (rename-buffer (herdr--buffer-name session new-name))))
    (herdr--poll)
    (message "Renamed %s -> %s" name new-name)))

(defun herdr--kill (session name)
  "Close NAME's pane in SESSION and its attach buffer."
  (herdr--run session "pane" "close" (herdr--pane session name))
  (when-let* ((b (get-buffer (herdr--buffer-name session name))))
    (let ((kill-buffer-query-functions nil)) (kill-buffer b)))
  (herdr--poll))

;;;###autoload
(defun herdr-kill (name)
  "Close agent NAME's pane (this ends the agent) and its attach buffer."
  (interactive (list (herdr--read-agent (herdr--session) "Kill agent: ")))
  (let ((session (herdr--session)))
    (when (yes-or-no-p (format "Kill agent %s in %s? " name session))
      (herdr--kill session name))))

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
                 (let* ((name (alist-get 'name a))
                        (was (alist-get 'agent_status (seq-find (lambda (o) (equal (alist-get 'name o) name)) old)))
                        (now (alist-get 'agent_status a)))
                   (when (and (equal was "working") (member now '("blocked" "done")))
                     (herdr--notify (format "%s %s" name now) (or (alist-get 'terminal_title_stripped a) ""))))))
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
  (pcase-let ((`(,ws ,session ,name) (tabulated-list-get-id)))
    (let ((new (read-string (format "New name for %s: " name) name)))
      (herdr--run session "agent" "rename" name new)
      (when-let* ((b (get-buffer (herdr--buffer-name session name))))
        (with-current-buffer b (rename-buffer (herdr--buffer-name session new))))
      (herdr-overview-refresh))))

(defun herdr-overview-kill ()
  "Kill the agent on this line after confirmation."
  (interactive)
  (pcase-let ((`(,_workspace ,session ,name) (tabulated-list-get-id)))
    (when (yes-or-no-p (format "Kill agent %s in %s? " name session))
      (herdr--kill session name)
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
         (push (list (list ws session (alist-get 'name a))
                     (vector ws session (alist-get 'name a)
                             (concat (herdr--status-glyph (alist-get 'agent_status a)) " " (alist-get 'agent_status a))
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
  (pcase-let ((`(,ws ,session ,name) (tabulated-list-get-id)))
    (when (and (fboundp 'persp-switch) (not (equal ws (herdr--workspace))))
      (persp-switch ws))
    (herdr--show session name)))

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
