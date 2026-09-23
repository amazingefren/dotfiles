;;; mcp.el --- Local MCP bridge for Emacs  -*- lexical-binding: t -*-

(require 'json)
(require 'flymake)
(require 'imenu)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)

(defvar emacs-mcp--request-root nil
  "Dynamically bound launch root for the current MCP request.")

(cl-defstruct (emacs-mcp-activity
               (:constructor emacs-mcp-activity-create))
  "The most recent MCP activity for one agent."
  id agent pane workspace root tool target state diagnostics last-seen)

(defvar emacs-mcp--activity (make-hash-table :test #'equal)
  "Agent id -> `emacs-mcp-activity' for local MCP requests.")

(define-derived-mode emacs-mcp-activity-mode tabulated-list-mode "AI activity"
  "A live, interactive overview of agents using the local Emacs MCP bridge."
  (setq tabulated-list-format
        [("Agent" 20 t) ("Workspace" 26 t) ("State" 10 t)
         ("Action" 21 t) ("Last target" 36 t) ("Diagnostics" 12 t)
         ("Last seen" 10 t)])
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(defvar emacs-mcp-activity-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'emacs-mcp-activity-visit)
    (define-key map (kbd "g") #'emacs-mcp-activity-refresh)
    (define-key map (kbd "a") #'emacs-mcp-activity-show-agent)
    map)
  "Keymap for `emacs-mcp-activity-mode'.")

(defun emacs-mcp--activity-buffer ()
  (let ((buffer (get-buffer-create "*AI activity*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'emacs-mcp-activity-mode)
        (emacs-mcp-activity-mode))
      (emacs-mcp-activity-refresh))
    buffer))

(defun emacs-mcp-show-activity ()
  "Show the local AI activity log."
  (interactive)
  (display-buffer (emacs-mcp--activity-buffer)
                  '((display-buffer-in-side-window)
                    (side . bottom) (slot . 2)
                    (window-height . 0.25))))

(defun emacs-mcp--agent-metadata (arguments)
  "Return the registered Herdr metadata for ARGUMENTS's agent, if available."
  (when-let* ((pane (gethash "__emacs_mcp_pane" arguments))
              ((fboundp 'agents-mcp-agent-metadata)))
    (agents-mcp-agent-metadata pane)))

(defun emacs-mcp--argument (name arguments metadata)
  "Return hidden MCP argument NAME, falling back to METADATA.

The stdio bridge, rather than the agent, sets all `__emacs_mcp_*' arguments.
They are deliberately absent from MCP tool schemas."
  (or (gethash name arguments)
      (alist-get (intern (substring name 12)) metadata)))

(defun emacs-mcp--agent-id (arguments metadata)
  (or (emacs-mcp--argument "__emacs_mcp_pane" arguments metadata)
      (emacs-mcp--argument "__emacs_mcp_agent_name" arguments metadata)
      (gethash "__emacs_mcp_agent" arguments)
      "agent"))

(defun emacs-mcp--workspace-name (activity)
  (let ((root (emacs-mcp-activity-root activity)))
    (if (and root (file-name-absolute-p root))
        (abbreviate-file-name (directory-file-name root))
      (or (emacs-mcp-activity-workspace activity) "unbound"))))

(defun emacs-mcp--sync-herdr-activity ()
  "Seed the dashboard from Herdr before any MCP tool has been called."
  (when (fboundp 'agents-mcp-live-agents)
    (dolist (metadata (agents-mcp-live-agents))
      (let* ((pane (alist-get 'pane metadata))
             (id (format "%s" (or pane (alist-get 'name metadata))))
             (old (gethash id emacs-mcp--activity)))
        (puthash id
                 (emacs-mcp-activity-create
                  :id id
                  :agent (or (alist-get 'name metadata) "agent")
                  :pane pane
                  :workspace (alist-get 'workspace metadata)
                  :root (or (and old (emacs-mcp-activity-root old))
                            (alist-get 'root metadata))
                  :tool (and old (emacs-mcp-activity-tool old))
                  :target (and old (emacs-mcp-activity-target old))
                  :state (or (alist-get 'state metadata) "unknown")
                  :diagnostics (and old (emacs-mcp-activity-diagnostics old))
                  :last-seen (and old (emacs-mcp-activity-last-seen old)))
                 emacs-mcp--activity)))))

(defun emacs-mcp--activity-herdr-state (activity)
  (or (and (fboundp 'agents-mcp-agent-metadata)
           (alist-get 'state (agents-mcp-agent-metadata
                              (emacs-mcp-activity-pane activity))))
      (emacs-mcp-activity-state activity)
      "unknown"))

(defun emacs-mcp--activity-entries ()
  (emacs-mcp--sync-herdr-activity)
  (let (entries)
    (maphash
     (lambda (id activity)
       (let ((state (emacs-mcp--activity-herdr-state activity)))
         (push (list id
                     (vector (or (emacs-mcp-activity-agent activity) "agent")
                             (emacs-mcp--workspace-name activity)
                             state
                             (or (emacs-mcp-activity-tool activity) "—")
                             (or (emacs-mcp-activity-target activity) "—")
                             (if-let* ((count (emacs-mcp-activity-diagnostics activity)))
                                 (number-to-string count)
                               "—")
                             (or (emacs-mcp-activity-last-seen activity) "—")))
               entries)))
     emacs-mcp--activity)
    (nreverse entries)))

(defun emacs-mcp-activity-refresh ()
  "Refresh the AI activity table without changing the selected agent."
  (interactive)
  (when (derived-mode-p 'emacs-mcp-activity-mode)
    (let ((id (tabulated-list-get-id)))
      (setq tabulated-list-entries (emacs-mcp--activity-entries))
      (tabulated-list-print t)
      (when id
        (goto-char (point-min))
        (while (and (not (eobp)) (not (equal id (tabulated-list-get-id))))
          (forward-line 1))))))

(defun emacs-mcp--activity-at-point ()
  (or (gethash (tabulated-list-get-id) emacs-mcp--activity)
      (user-error "No agent on this line")))

(defun emacs-mcp-activity-show-agent ()
  "Show the Herdr terminal for the agent at point, when it is still available."
  (interactive)
  (let ((activity (emacs-mcp--activity-at-point)))
    (if (fboundp 'agents-mcp-show-agent)
        (or (agents-mcp-show-agent (emacs-mcp-activity-pane activity)
                                   (emacs-mcp-activity-agent activity))
            (user-error "Herdr no longer has this agent"))
      (user-error "The Herdr integration is not loaded"))))

(defun emacs-mcp-activity-visit ()
  "Visit the selected agent's last target, or show its terminal.

Use `a' to always show the terminal instead."
  (interactive)
  (let* ((activity (emacs-mcp--activity-at-point))
         (target (emacs-mcp-activity-target activity)))
    (if (and target (file-exists-p target))
        (pop-to-buffer (find-file-noselect target))
      (emacs-mcp-activity-show-agent))))

(defun emacs-mcp--activity-target (arguments root)
  (cond ((gethash "url" arguments) (gethash "url" arguments))
        ((when-let* ((path (gethash "path" arguments)))
           (if (and root (not (file-name-absolute-p path)))
               (expand-file-name path root)
             path)))))

(defun emacs-mcp--record-activity (arguments tool state &optional result)
  "Record one MCP STATE transition, keeping one dashboard row per agent."
  (let* ((metadata (emacs-mcp--agent-metadata arguments))
         (root (emacs-mcp--workspace-root arguments metadata))
         (id (format "%s" (emacs-mcp--agent-id arguments metadata)))
         (old (gethash id emacs-mcp--activity))
         (diagnostics (and result
                           (if (hash-table-p result)
                               (gethash "diagnostics" result)
                             (alist-get 'diagnostics result)))))
    (puthash id
             (emacs-mcp-activity-create
              :id id
              :agent (or (emacs-mcp--argument "__emacs_mcp_agent_name" arguments metadata)
                         (gethash "__emacs_mcp_agent" arguments) "agent")
              :pane (emacs-mcp--argument "__emacs_mcp_pane" arguments metadata)
              :workspace (alist-get 'workspace metadata)
              :root root :tool tool :state state
              :target (emacs-mcp--activity-target arguments root)
              :diagnostics (if diagnostics (length diagnostics)
                             (and old (emacs-mcp-activity-diagnostics old)))
              :last-seen (format-time-string "%H:%M:%S"))
             emacs-mcp--activity)
    (when-let* ((buffer (get-buffer "*AI activity*"))
                ((get-buffer-window buffer t)))
      (with-current-buffer buffer (emacs-mcp-activity-refresh)))))

(defun emacs-mcp--arguments (encoded)
  (if (string-empty-p encoded)
      (make-hash-table :test #'equal)
    (json-parse-string (decode-coding-string (base64-decode-string encoded) 'utf-8))))

(defun emacs-mcp--active-buffer ()
  (window-buffer (selected-window)))

(defun emacs-mcp--workspace-root (arguments &optional metadata)
  "Return ARGUMENTS's launch workspace, never the selected Emacs workspace.

The MCP stdio bridge injects `__emacs_mcp_workspace_root' from the immutable
environment with which Herdr launched the agent.  Older MCP processes lack
that field and must be restarted: silently using the selected buffer would let
one agent read a different project's files."
  (let ((root (emacs-mcp--argument "__emacs_mcp_workspace_root" arguments metadata)))
    (unless (and (stringp root) (file-name-absolute-p root) (file-directory-p root))
      (user-error "This MCP agent has no launch workspace; restart it from Herdr"))
    (file-name-as-directory (file-truename root))))

(defun emacs-mcp--buffer-data (buffer)
  (with-current-buffer buffer
    `((name . ,(buffer-name))
      (file . ,buffer-file-name)
      (mode . ,(symbol-name major-mode))
      (line . ,(line-number-at-pos))
      (column . ,(current-column)))))

(defun emacs-mcp--buffer-in-workspace-p (buffer root)
  "Whether BUFFER visits a file contained by the MCP agent's ROOT."
  (when-let* ((file (buffer-file-name buffer)))
    (file-in-directory-p (file-truename file) root)))

(defun emacs-mcp--context (arguments)
  (let ((root (emacs-mcp--workspace-root arguments)))
    `((emacs_version . ,emacs-version)
      (workspace_root . ,root)
      ;; Context is scoped to the agent's launch root.  In particular, the
      ;; selected window is not used as a shortcut to another workspace.
      (visible_buffers .
                       ,(vconcat
                         (delq nil
                               (mapcar
                                (lambda (window)
                                  (let ((buffer (window-buffer window)))
                                    (when (emacs-mcp--buffer-in-workspace-p buffer root)
                                      (append `((selected . ,(eq window (selected-window))))
                                              (emacs-mcp--buffer-data buffer)))))
                                (window-list))))))))

(defun emacs-mcp--handoff-context (arguments)
  "Return compact project and editor context for a newly launched agent."
  (let ((root (emacs-mcp--workspace-root arguments)))
    (with-temp-buffer
      (let ((default-directory root)
            (emacs-mcp--request-root root))
        `((workspace_root . ,root)
          (git . ,(emacs-ai-intelligence-git-status (current-buffer) arguments))
          (project . ,(emacs-ai-intelligence-project-outline (current-buffer) arguments))
          (editor . ,(emacs-mcp--context arguments)))))))

(defun emacs-mcp--file-path (arguments)
  (let ((path (gethash "path" arguments))
        (root (emacs-mcp--workspace-root arguments)))
    (unless (and (stringp path) (not (string-empty-p path)))
      (user-error "A non-empty path is required"))
    (setq path (file-truename (expand-file-name path root)))
    (unless (file-in-directory-p path root)
      (user-error "Path is outside this agent's launch workspace"))
    (unless (file-exists-p path)
      (user-error "File does not exist: %s" path))
    path))

(defun emacs-mcp--open-file (arguments)
  (let* ((path (emacs-mcp--file-path arguments))
         (line (max 1 (or (gethash "line" arguments) 1))))
    (find-file-noselect path)
    `((opened . t) (path . ,path) (line . ,line) (displayed . :false))))

(defun emacs-mcp--replace-exactly-once (old new index)
  "Replace the sole occurrence of OLD with NEW, reporting errors for INDEX.
Return the position of the replacement."
  (goto-char (point-min))
  (unless (search-forward old nil t)
    (user-error "Edit %d: old_text was not found" index))
  (let* ((end (point))
         (start (- end (length old))))
    (when (save-excursion
            (goto-char (1+ start))
            (search-forward old nil t))
      (user-error "Edit %d: old_text matches more than once" index))
    (delete-region start end)
    (goto-char start)
    (insert new)
    start))

(defun emacs-mcp--editable-file-buffer (path)
  "Return PATH's visiting buffer after checking for local or disk changes."
  (let ((buffer (get-file-buffer path)))
    (when buffer
      (with-current-buffer buffer
        (when (buffer-modified-p)
          (user-error "Buffer has unsaved changes: %s" path))
        (unless (verify-visited-file-modtime buffer)
          (user-error "File changed on disk since Emacs visited it: %s" path))))
    (setq buffer (or buffer (find-file-noselect path)))
    (with-current-buffer buffer
      (when (buffer-modified-p)
        (user-error "Buffer has unsaved changes: %s" path)))
    buffer))

(defun emacs-mcp--edit-file (arguments)
  "Apply exact, sequential replacements through a live Emacs buffer.
Reject dirty or stale buffers and ambiguous matches before changing anything."
  (let* ((path (emacs-mcp--file-path arguments))
         (edits (gethash "edits" arguments))
         (buffer (emacs-mcp--editable-file-buffer path))
         (first-marker nil)
         (line nil))
    (unless (and (vectorp edits) (> (length edits) 0))
      (user-error "At least one edit is required"))
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (let ((replacement (generate-new-buffer " *Emacs MCP edit*")))
          (unwind-protect
              (progn
                (with-current-buffer replacement
                  (insert (with-current-buffer buffer
                            (buffer-substring-no-properties (point-min) (point-max)))))
                (dotimes (index (length edits))
                  (let* ((edit (aref edits index))
                         (old (and (hash-table-p edit) (gethash "old_text" edit)))
                         (new (and (hash-table-p edit) (gethash "new_text" edit))))
                    (unless (and (stringp old) (not (string-empty-p old)) (stringp new))
                      (user-error "Edit %d needs nonempty old_text and string new_text" (1+ index)))
                    (with-current-buffer replacement
                      (let ((position (emacs-mcp--replace-exactly-once old new (1+ index))))
                        (unless first-marker (setq first-marker (copy-marker position)))))))
                (setq line (with-current-buffer replacement
                             (line-number-at-pos first-marker)))
                (atomic-change-group
                  (if (fboundp 'replace-region-contents)
                      (replace-region-contents (point-min) (point-max) replacement)
                    (with-no-warnings (replace-buffer-contents replacement))))
                (save-buffer))
            (kill-buffer replacement))))
      `((edited . t) (path . ,path) (edits_applied . ,(length edits))
        (line . ,line) (displayed . :false)))))

(defun emacs-mcp--create-file (arguments)
  "Create a file in the launch workspace through an Emacs buffer."
  (let* ((root (emacs-mcp--workspace-root arguments))
         (requested (gethash "path" arguments))
         (content (gethash "content" arguments)))
    (unless (and (stringp requested) (not (string-empty-p requested))
                 (stringp content))
      (user-error "A path and string content are required"))
    (let* ((requested-path (expand-file-name requested root))
           (parent (file-truename (file-name-directory requested-path)))
           (path (expand-file-name (file-name-nondirectory requested-path) parent)))
      (unless (file-in-directory-p parent root)
        (user-error "Path is outside this agent's launch workspace"))
      (when (or (file-exists-p path) (file-symlink-p path) (get-file-buffer path))
        (user-error "File already exists or is visited: %s" path))
      (let ((buffer (find-file-noselect path)))
        (with-current-buffer buffer
          (when (or (buffer-modified-p) (not (zerop (buffer-size))))
            (user-error "New file buffer is not empty: %s" path))
          (insert content)
          (when (string-empty-p content) (set-buffer-modified-p t))
          (save-buffer))
        `((created . t) (path . ,path)
          (displayed . :false))))))

(defun emacs-mcp--read-file (arguments)
  (let* ((path (emacs-mcp--file-path arguments))
         (start (max 1 (or (gethash "start_line" arguments) 1)))
         (end (gethash "end_line" arguments)))
    (with-temp-buffer
      (insert-file-contents path)
      (goto-char (point-min))
      (forward-line (1- start))
      (let ((begin (point)))
        (when end
          (forward-line (max 0 (- end start -1))))
        `((path . ,path)
          (start_line . ,start)
          (text . ,(buffer-substring-no-properties begin (if end (point) (point-max)))))))))

(defun emacs-mcp--browser-buffers ()
  (seq-filter (lambda (buffer)
                (with-current-buffer buffer
                  (derived-mode-p 'eww-mode 'xwidget-webkit-mode)))
              (buffer-list)))

(defun emacs-mcp--browser-data (buffer)
  (with-current-buffer buffer
    `((buffer . ,(buffer-name))
      (mode . ,(symbol-name major-mode))
      (url . ,(and (fboundp 'browser-current-url) (ignore-errors (browser-current-url)))))))

(defun emacs-mcp--browser-context (_arguments)
  `((browsers . ,(vconcat (mapcar #'emacs-mcp--browser-data (emacs-mcp--browser-buffers))))))

(defun emacs-mcp--browser-open (arguments)
  (let ((url (gethash "url" arguments)))
    (unless (string-match-p "\\`https?://" (or url ""))
      (user-error "A HTTP(S) URL is required"))
    (unless (fboundp 'browser-open)
      (user-error "The Emacs browser module is not loaded"))
    (browser-open url)
    `((opened . t) (url . ,url))))

(defun emacs-mcp--browser-buffer (arguments)
  (let* ((name (gethash "buffer" arguments))
         (buffer (or (and name (get-buffer name))
                     (car (emacs-mcp--browser-buffers)))))
    (unless buffer (user-error "No Emacs browser buffer is open"))
    (with-current-buffer buffer
      (unless (derived-mode-p 'eww-mode)
        (user-error "Only EWW pages expose readable text; this is %s" major-mode)))
    buffer))

(defun emacs-mcp--browser-read (arguments)
  (let ((buffer (emacs-mcp--browser-buffer arguments)))
    (with-current-buffer buffer
      `((buffer . ,(buffer-name))
        (url . ,(browser-current-url))
        (text . ,(buffer-substring-no-properties (point-min) (point-max)))))))

(defun emacs-mcp--target-buffer (arguments)
  (if (gethash "path" arguments)
      (find-file-noselect (emacs-mcp--file-path arguments))
    (user-error "A path is required; MCP never uses the selected Emacs buffer")))

(defun emacs-mcp--diagnostics (arguments)
  (with-current-buffer (emacs-mcp--target-buffer arguments)
    `((file . ,buffer-file-name)
      (diagnostics .
                   ,(vconcat (mapcar
                     (lambda (diagnostic)
                       (save-excursion
                         (goto-char (flymake-diagnostic-beg diagnostic))
                         `((line . ,(line-number-at-pos))
                           (column . ,(current-column))
                           (type . ,(symbol-name (flymake-diagnostic-type diagnostic)))
                           (text . ,(flymake-diagnostic-text diagnostic)))))
                     (flymake-diagnostics (point-min) (point-max))))))))

(defun emacs-mcp--symbol-entries (index)
  (cl-mapcan
   (lambda (entry)
     (cond ((equal (car-safe entry) "*Rescan*") nil)
           ((imenu--subalist-p entry) (emacs-mcp--symbol-entries (cdr entry)))
           ((and (consp entry) (markerp (cdr entry)))
            (with-current-buffer (marker-buffer (cdr entry))
              (save-excursion
                (goto-char (cdr entry))
                (list `((name . ,(car entry))
                        (line . ,(line-number-at-pos))
                        (column . ,(current-column)))))))
           ((and (consp entry) (integerp (cdr entry)))
            (save-excursion
              (goto-char (cdr entry))
              (list `((name . ,(car entry))
                      (line . ,(line-number-at-pos))
                      (column . ,(current-column))))))))
   index))

(defun emacs-mcp--symbols (arguments)
  (with-current-buffer (emacs-mcp--target-buffer arguments)
    `((file . ,buffer-file-name)
      (symbols . ,(vconcat (emacs-mcp--symbol-entries (imenu--make-index-alist t)))))))

(defun emacs-mcp--show-worktree-diff (arguments)
  "Show and return the current agent worktree's diff."
  (let ((result (ai-review-worktree-diff arguments)))
    (ai-review-show-worktree-diff)
    result))

(defun emacs-mcp-dispatch (method encoded-arguments)
  "Run the fixed MCP METHOD with base64 JSON ENCODED-ARGUMENTS."
  (let* ((arguments (emacs-mcp--arguments encoded-arguments))
         (tool (concat "emacs_" method)))
    ;; Record before dispatch so an unavailable root is visible in the dashboard.
    ;; `emacs-mcp--record-activity' intentionally tolerates an unbound root.
    (condition-case nil
        (emacs-mcp--record-activity arguments tool "working")
      (error nil))
    (condition-case err
        (let* ((emacs-mcp--request-root (emacs-mcp--workspace-root arguments))
               (default-directory emacs-mcp--request-root)
               (result
                (pcase method
                  ((or "laya_submit" "laya_result" "laya_cancel")
                   (laya-mcp-dispatch method arguments))
                  ("context" (emacs-mcp--context arguments))
                  ("handoff_context" (emacs-mcp--handoff-context arguments))
                  ("open_file" (emacs-mcp--open-file arguments))
                  ("edit_file" (emacs-mcp--edit-file arguments))
                  ("create_file" (emacs-mcp--create-file arguments))
                  ("read_file" (emacs-mcp--read-file arguments))
                  ("browser_context" (emacs-mcp--browser-context arguments))
                  ("browser_open" (emacs-mcp--browser-open arguments))
                  ("browser_read" (emacs-mcp--browser-read arguments))
                  ("diagnostics" (emacs-mcp--diagnostics arguments))
                  ("symbols" (emacs-mcp--symbols arguments))
                  ("selection_context" (emacs-ai-intelligence-selection-context
                                        (emacs-mcp--target-buffer arguments) arguments))
                  ("range_context" (emacs-ai-intelligence-range-context
                                    (emacs-mcp--target-buffer arguments) arguments))
                  ("project_outline" (emacs-ai-intelligence-project-outline
                                      (emacs-mcp--target-buffer arguments) arguments))
                  ("git_status" (emacs-ai-intelligence-git-status
                                 (emacs-mcp--target-buffer arguments) arguments))
                  ("xref_definitions" (emacs-ai-intelligence-xref-definitions
                                        (emacs-mcp--target-buffer arguments) arguments))
                  ("xref_references" (emacs-ai-intelligence-xref-references
                                       (emacs-mcp--target-buffer arguments) arguments))
                  ("documentation_at_point" (emacs-ai-intelligence-documentation-at-point
                                              (emacs-mcp--target-buffer arguments) arguments))
                  ("browser_page" (emacs-ai-intelligence-eww-context
                                    (emacs-mcp--browser-buffer arguments) arguments))
                  ("show_worktree_diff" (emacs-mcp--show-worktree-diff arguments))
                  ("compilation_context" (ai-review-compilation-context arguments))
                  ("compilation_read" (ai-review-read-compilation arguments))
                  ("compilation_reveal" (ai-review-reveal-compilation arguments))
                  (_ (user-error "Unknown Emacs MCP method: %s" method)))))
          (emacs-mcp--record-activity arguments tool "finished" result)
          (json-serialize result))
      (error
       (condition-case nil
           (emacs-mcp--record-activity arguments tool "failed")
         (error nil))
       (json-serialize `((error . ,(error-message-string err))))))))
