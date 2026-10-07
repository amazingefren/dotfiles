;;; webkit-agent-mcp.el --- MCP methods for webkit-agent pages -*- lexical-binding: t -*-

;; Methods return their value, or ((pending . ID)) for work that finishes
;; later; the browser_result method collects it.  Calls without a page use the
;; calling agent's most recently used page.

(require 'mailcap)
(require 'webkit-agent)

(defconst webkit-agent-mcp--max-wait 120
  "Most seconds a browser_wait may wait.")

(defvar webkit-agent-mcp--last-pages (make-hash-table :test #'equal)
  "Agent (Herdr session and pane) -> ID of the page it used last.")

;;;###autoload
(defun webkit-agent-mcp-dispatch (method arguments)
  "Run browser METHOD with JSON object ARGUMENTS from the MCP bridge.
Return an alist or hash table for JSON, or ((pending . ID)).  Signal
`user-error' for bad arguments and failed requests."
  (pcase method
    ("browser_list"
     `((pages . ,(vconcat (mapcar #'webkit-agent-page-summary (webkit-agent-pages))))))
    ("browser_open" (webkit-agent-mcp--open arguments))
    ("browser_capabilities"
     `((engine . "WebKit")
       (native_screenshot . ,(if (fboundp 'xwidget-webkit-snapshot) t :false))
       (native_sessions . ,(if (fboundp 'xwidget-webkit-session-command) t :false))
       (native_input . ,(if (fboundp 'xwidget-webkit-session-command) t :false))
       (native_downloads . ,(if (fboundp 'xwidget-webkit-session-command) t :false))
       (user_agent . ,(if (fboundp 'xwidget-webkit-set-user-agent) t :false))
       (viewport . ,(if (fboundp 'xwidget-webkit-set-viewport) t :false))
       (viewport_max . 4096)
       (input . "JavaScript events; isTrusted=false")
       (new_windows . :false)
       (device_emulation . :false)))
    ("browser_result" (webkit-agent-mcp--result arguments))
    ("browser_close"
     (let ((page (webkit-agent-mcp--page arguments)))
       (webkit-agent-close page)
       `((closed . ,(webkit-agent-page-id page)))))
    (_
     (let ((page (webkit-agent-mcp--page arguments)))
       (pcase method
         ("browser_cookies"
          (let ((operation (pcase (gethash "action" arguments)
                             ("get" "get_cookies") ("set" "set_cookies")
                             ("clear" "clear_cookies")
                             (_ (user-error "cookies action must be get, set or clear")))))
            (webkit-agent-mcp--start
             page (lambda (on-value on-error)
                    (webkit-agent-session page operation arguments on-value on-error)))))
         ("browser_session"
          (let ((operation (pcase (gethash "action" arguments)
                             ("info" "info") ("clear" "clear_data")
                             (_ (user-error "session action must be info or clear")))))
            (webkit-agent-mcp--start
             page (lambda (on-value on-error)
                    (webkit-agent-session page operation arguments on-value on-error)))))
         ("browser_storage" (webkit-agent-mcp--storage page arguments))
         ("browser_download"
          (let ((action (gethash "action" arguments)))
            (unless (member action '("list" "start" "cancel"))
              (user-error "download action must be list, start or cancel"))
            (when (equal action "start")
              (let ((path (gethash "path" arguments)) (url (gethash "url" arguments)))
                (unless (and (stringp path) (> (length path) 0)
                             (stringp url) (string-match-p "\\`https?://" url))
                  (user-error "download needs an HTTP(S) URL and destination path"))
                (setq path (expand-file-name path))
                (unless (file-directory-p (file-name-directory path))
                  (user-error "Download directory does not exist: %s" (file-name-directory path)))
                (when (file-exists-p path) (user-error "Download destination exists: %s" path))
                (puthash "path" path arguments)))
            (if (equal action "list")
                (webkit-agent-mcp--start
                 page (lambda (on-value on-error)
                        (webkit-agent-call
                         page "info" nil
                         (lambda (_info)
                           (funcall on-value
                                    `((downloads . ,(vconcat (webkit-agent-page-downloads page))))))
                         on-error)))
              (webkit-agent-mcp--start
               page (lambda (on-value on-error)
                      (webkit-agent-session page (if (equal action "start") "download" "cancel_download")
                                            arguments on-value on-error))))))
         ("browser_input" (webkit-agent-mcp--input page arguments))
         ("browser_dialogs"
          (webkit-agent-mcp--call page "dialogs" (webkit-agent-mcp--pick arguments "confirm" "prompt")))
         ("browser_configure"
          (when (and (eq (gethash "user_agent" arguments 'absent) 'absent)
                     (eq (gethash "viewport" arguments 'absent) 'absent))
            (user-error "configure needs user_agent or viewport for page %s" (webkit-agent-page-id page)))
          (webkit-agent-configure page arguments)
          (webkit-agent-mcp--start
           page (lambda (on-value on-error)
                  (if (gethash "user_agent" arguments)
                      (webkit-agent-navigate page "reload" nil on-value on-error)
                    (webkit-agent-call page "info" nil on-value on-error)))))
         ("browser_act" (webkit-agent-mcp--act page arguments))
         ("browser_console"
          (webkit-agent-mcp--call page "console" (webkit-agent-mcp--pick arguments "since" "clear")))
         ("browser_eval"
          (webkit-agent-mcp--start
           page (lambda (on-value on-error)
                  (webkit-agent-call page "evaluate" (webkit-agent-mcp--pick arguments "script")
                                     (lambda (value) (funcall on-value `((value . ,value))))
                                     on-error))))
         ("browser_get"
          (webkit-agent-mcp--call
           page "get" (webkit-agent-mcp--pick arguments "what" "target" "nth" "name" "names" "max_chars")))
         ("browser_navigate"
          (webkit-agent-mcp--start
           page (lambda (on-value on-error)
                  (webkit-agent-navigate page (gethash "action" arguments) (gethash "url" arguments)
                                         on-value on-error))))
         ("browser_screenshot"
          (webkit-agent-mcp--start
           page (lambda (on-value on-error)
                  (webkit-agent-screenshot page (make-temp-file "webkit-agent-" nil ".png")
                                           (lambda (file) (funcall on-value `((image_path . ,file))))
                                           on-error))))
         ("browser_snapshot"
          (webkit-agent-mcp--call
           page "snapshot" (webkit-agent-mcp--pick arguments "interactive" "selector" "max_depth")))
         ("browser_wait" (webkit-agent-mcp--wait page arguments))
         (_ (user-error "Unknown browser method %s" method)))))))

(defun webkit-agent-mcp--open-page (arguments)
  "Creates a page in ARGUMENTS's workspace and returns it.
Signals `user-error' when the caller's workspace cannot be resolved."
  (let* ((pane (gethash "__emacs_mcp_pane" arguments))
         (session (gethash "__emacs_mcp_herdr_session" arguments))
         (root (gethash "__emacs_mcp_workspace_root" arguments))
         (workspace
          (when (bound-and-true-p persp-mode)
            (or (and (fboundp 'agents-mcp-agent-metadata)
                     (alist-get 'workspace (agents-mcp-agent-metadata pane)))
                (and (boundp 'herdr--workspace-sessions)
                     (let (matches)
                       (maphash (lambda (name value)
                                  (when (equal value session) (push name matches)))
                                herdr--workspace-sessions)
                       (when (= (length matches) 1) (car matches))))
                (and root (boundp 'workspace-roots)
                     (let (matches)
                       (maphash (lambda (name directory)
                                  (when (equal (file-truename root)
                                               (file-truename directory))
                                    (push name matches)))
                                workspace-roots)
                       (when (= (length matches) 1) (car matches))))))))
    (when (and (bound-and-true-p persp-mode)
               (or root (and pane (not (equal pane ""))))
               (not (member workspace (persp-names))))
      (user-error "No live workspace for browser caller pane %s, root %s" pane root))
    (let ((previous (and workspace (persp-current-name)))
          (last (and workspace (persp-last)))
          (inhibit-redisplay t))
      (save-current-buffer
        (unwind-protect
            (progn
              (when workspace (persp-switch workspace 'norecord))
              (let ((page (webkit-agent-open
                           (gethash "url" arguments)
                           (eq (gethash "hidden" arguments) t) arguments)))
                (when workspace (persp-add-buffer (webkit-agent-page-buffer page)))
                page))
          (when previous
            (persp-switch previous 'norecord)
            (set-frame-parameter nil 'persp--last last)))))))

(defun webkit-agent-mcp--open (arguments)
  "Open ARGUMENTS's url in a new page, or in its page; return a pending request."
  (let ((url (gethash "url" arguments)))
    (if (gethash "page" arguments)
        (let ((page (webkit-agent-mcp--page arguments)))
          (when (gethash "profile" arguments)
            (user-error "profile is set only when opening a new page"))
          (webkit-agent-configure page arguments)
          (webkit-agent-mcp--start
           page (lambda (on-value on-error)
                  (webkit-agent-navigate page "goto" url on-value on-error))))
      (let ((page (webkit-agent-mcp--open-page arguments)))
        (webkit-agent-mcp--remember page arguments)
        (webkit-agent-mcp--start
         page (lambda (on-value on-error)
                (webkit-agent-wait-for-load page on-value on-error)))))))

(defun webkit-agent-mcp--storage (page arguments)
  "Export, import or clear PAGE's storage using ARGUMENTS.
Return a pending request. Signal `user-error' for an invalid state."
  (let ((action (gethash "action" arguments))
        (state (gethash "state" arguments)))
    (unless (member action '("export" "import" "clear"))
      (user-error "storage action must be export, import or clear"))
    (when (equal action "import")
      (unless (and (hash-table-p state) (stringp (gethash "origin" state))
                   (hash-table-p (gethash "local_storage" state))
                   (hash-table-p (gethash "session_storage" state)))
        (user-error "storage state needs origin, cookies, local_storage and session_storage"))
      (dolist (key '("local_storage" "session_storage"))
        (maphash (lambda (name value)
                   (unless (and (stringp name) (stringp value))
                     (user-error "%s keys and values must be strings" key)))
                 (gethash key state)))
      (webkit-agent--check-cookies (gethash "cookies" state)))
    (webkit-agent-mcp--start
     page
     (lambda (on-value on-error)
       (webkit-agent-call
        page "storage" (let ((check (make-hash-table :test #'equal)))
                         (puthash "action" "export" check)
                         check)
        (lambda (current)
          (cond
           ((equal action "export")
            (webkit-agent-session
             page "get_cookies" (make-hash-table :test #'equal)
             (lambda (result)
               (puthash "cookies" (gethash "cookies" result) current)
               (funcall on-value `((state . ,current)))) on-error))
           ((equal action "clear")
            (webkit-agent-call page "storage" arguments on-value on-error))
           ((not (equal (gethash "origin" current) (gethash "origin" state)))
            (funcall on-error (format "Storage origin %s does not match page origin %s"
                                      (gethash "origin" state) (gethash "origin" current))))
           (t
            (webkit-agent-session
             page "set_cookies" state
             (lambda (_result)
               (webkit-agent-call page "storage" arguments on-value on-error)) on-error))))
        on-error)))))

(defun webkit-agent-mcp--input (page arguments)
  "Send native click, type or fill ARGUMENTS to visible PAGE.
Return a pending request; signal `user-error' for invalid input."
  (let ((action (gethash "action" arguments)))
    (unless (member action '("click" "type" "fill"))
      (user-error "native input action must be click, type or fill"))
    (when (and (member action '("type" "fill")) (not (stringp (gethash "text" arguments))))
      (user-error "native type needs text"))
    (unless (get-buffer-window (webkit-agent-page-buffer page) 'visible)
      (user-error "Page %s is not visible in the current workspace" (webkit-agent-page-id page)))
    (redisplay t)
    (webkit-agent-mcp--start
     page
     (lambda (on-value on-error)
       (let ((send (lambda (input)
                     (if (equal (gethash "action" input) "click")
                         (webkit-agent-session page "native_input" input on-value on-error)
                       (webkit-agent-call
                        page "native_ready" (webkit-agent-mcp--pick input "action")
                        (lambda (_ready) (webkit-agent-session page "native_input" input on-value on-error))
                        on-error)))))
         (if (gethash "target" arguments)
             (webkit-agent-call
              page "native_box" (webkit-agent-mcp--pick arguments "action" "target" "nth")
              (lambda (box)
                (let ((click (make-hash-table :test #'equal)))
                  (puthash "action" "click" click)
                  (puthash "x" (+ (gethash "x" box) (/ (gethash "width" box) 2.0)) click)
                  (puthash "y" (+ (gethash "y" box) (/ (gethash "height" box) 2.0)) click)
                  (webkit-agent-session
                   page "native_input" click
                   (lambda (result) (if (equal action "click") (funcall on-value result)
                                      (funcall send arguments))) on-error))) on-error)
           (funcall send arguments)))))))

(defun webkit-agent-mcp--page (arguments)
  "Return the page named by ARGUMENTS's page, else the caller's last page.
With neither, the only open page is used.  The result becomes the caller's
last page.  Signal `user-error' when no page can be chosen."
  (let* ((requested (gethash "page" arguments))
         (last (gethash (webkit-agent-mcp--owner arguments) webkit-agent-mcp--last-pages))
         (pages (webkit-agent-pages))
         (page (cond
                (requested (webkit-agent-find-page requested))
                ((seq-find (lambda (page) (equal (webkit-agent-page-id page) last)) pages))
                ((not pages) (user-error "No page is open; call emacs_browser_open first"))
                ((null (cdr pages)) (car pages))
                (t (user-error "Several pages are open (%s); pass page"
                               (string-join (mapcar #'webkit-agent-page-id pages) ", "))))))
    (webkit-agent-mcp--remember page arguments)
    page))

(defun webkit-agent-mcp--owner (arguments)
  "Return the calling agent's Herdr session and pane from bridge ARGUMENTS."
  (list (gethash "__emacs_mcp_herdr_session" arguments "")
        (gethash "__emacs_mcp_pane" arguments "")))

(defun webkit-agent-mcp--remember (page arguments)
  "Make PAGE the last page of the agent calling with ARGUMENTS."
  (puthash (webkit-agent-mcp--owner arguments) (webkit-agent-page-id page)
           webkit-agent-mcp--last-pages))

(defun webkit-agent-mcp--start (page function)
  "Start a request that FUNCTION completes and return ((pending . ID)).
FUNCTION is called as for `webkit-agent-request'.  A hash table or alist value
is tagged with PAGE's ID."
  `((pending . ,(webkit-agent-request
                 (lambda (on-value on-error)
                   (funcall function
                            (lambda (value) (funcall on-value (webkit-agent-mcp--tag page value)))
                            on-error))))))

(defun webkit-agent-mcp--tag (page value)
  "Return VALUE with PAGE's ID added when VALUE is a JSON object."
  (cond ((hash-table-p value) (puthash "page" (webkit-agent-page-id page) value) value)
        ((and (consp value) (consp (car value))) (cons `(page . ,(webkit-agent-page-id page)) value))
        (t `((page . ,(webkit-agent-page-id page)) (value . ,value)))))

(defun webkit-agent-mcp--result (arguments)
  "Return the outcome of ARGUMENTS's request, or ((pending . ID)) while it runs.
Signal `user-error' with the failure message of a failed request."
  (let* ((id (gethash "request" arguments))
         (outcome (webkit-agent-request-take id)))
    (pcase (car outcome)
      ('pending `((pending . ,id)))
      ('done (cdr outcome))
      ('failed (user-error "%s" (cdr outcome))))))

(defun webkit-agent-mcp--pick (arguments &rest keys)
  "Return a hash table of the KEYS present in ARGUMENTS."
  (let ((picked (make-hash-table :test #'equal)))
    (dolist (key keys)
      (let ((value (gethash key arguments 'webkit-agent-mcp--absent)))
        (unless (eq value 'webkit-agent-mcp--absent)
          (puthash key value picked))))
    picked))

(defun webkit-agent-mcp--call (page method arguments)
  "Start runtime METHOD with ARGUMENTS in PAGE as a request."
  (webkit-agent-mcp--start
   page (lambda (on-value on-error)
          (webkit-agent-call page method arguments on-value on-error))))

(defun webkit-agent-mcp--act (page arguments)
  "Start the act request ARGUMENTS describes in PAGE.
With snapshot true, an interactive snapshot taken after any resulting load
is added to the result."
  (let ((act-arguments (webkit-agent-mcp--pick arguments "action" "target" "nth" "text" "key"
                                               "values" "dx" "dy")))
    (when (equal (gethash "action" arguments) "upload")
      (puthash "files" (webkit-agent-mcp--files (gethash "files" arguments)) act-arguments))
    (webkit-agent-mcp--start
     page
     (lambda (on-value on-error)
       (webkit-agent-call
        page "act" act-arguments
        (lambda (result)
          (if (eq (gethash "snapshot" arguments) t)
              (webkit-agent-mcp--snapshot-after page result on-value on-error)
            (funcall on-value result)))
        on-error)))))

(defun webkit-agent-mcp--files (paths)
  "Return upload descriptors for file PATHS, relative to the agent's workspace."
  (unless (and (vectorp paths) (> (length paths) 0))
    (user-error "upload needs files: a non-empty array of paths"))
  (vconcat
   (mapcar (lambda (path)
             (let ((file (expand-file-name path)))
               (unless (file-readable-p file)
                 (user-error "Cannot read upload file %s" file))
               `((base64 . ,(with-temp-buffer
                              (set-buffer-multibyte nil)
                              (insert-file-contents-literally file)
                              (base64-encode-region (point-min) (point-max) t)
                              (buffer-string)))
                 (name . ,(file-name-nondirectory file))
                 (type . ,(or (mailcap-file-name-to-mime-type file) "application/octet-stream")))))
           paths)))

(defun webkit-agent-mcp--snapshot-after (page result on-value on-error)
  "Add an interactive snapshot of PAGE to act RESULT once PAGE settles.
Call ON-VALUE with RESULT or ON-ERROR with a message."
  (run-at-time
   0.15 nil
   (lambda ()
     (let ((snapshot
            (lambda (_info)
              (webkit-agent-call
               page "snapshot" '((interactive . t))
               (lambda (snapshot)
                 (puthash "snapshot" (gethash "snapshot" snapshot) result)
                 (puthash "truncated" (gethash "truncated" snapshot) result)
                 (puthash "url" (gethash "url" snapshot) result)
                 (funcall on-value result))
               on-error))))
       (if (webkit-agent-page-loading page)
           (webkit-agent-wait-for-load page snapshot on-error)
         (funcall snapshot nil))))))

(defun webkit-agent-mcp--wait (page arguments)
  "Start a request waiting for the condition in ARGUMENTS in PAGE.
A pending load finishes first.  timeout_ms defaults to 10 seconds."
  (let* ((timeout-ms (gethash "timeout_ms" arguments 10000))
         (timeout (min webkit-agent-mcp--max-wait (/ timeout-ms 1000.0)))
         (condition (webkit-agent-mcp--pick arguments "target" "state" "text" "url_contains"
                                            "function" "load_state")))
    (webkit-agent-mcp--start
     page
     (lambda (on-value on-error)
       (let ((wait (lambda (_info)
                     (webkit-agent-wait page condition timeout
                                        (lambda (detail) (funcall on-value `((met . t) (detail . ,detail))))
                                        on-error))))
         (if (webkit-agent-page-loading page)
             (webkit-agent-wait-for-load page wait on-error)
           (funcall wait nil)))))))

(provide 'webkit-agent-mcp)
;;; webkit-agent-mcp.el ends here
