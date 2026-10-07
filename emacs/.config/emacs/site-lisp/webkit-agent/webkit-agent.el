;;; webkit-agent.el --- Scriptable xwidget WebKit pages for agents -*- lexical-binding: t -*-

;; A page is an xwidget-webkit buffer with a short ID such as "p1".  Pages
;; opened elsewhere are adopted when listed.  Work in a page runs through
;; webkit-agent-runtime.js and finishes asynchronously: `webkit-agent-call'
;; and the navigation and wait functions take ON-VALUE and ON-ERROR
;; callbacks, exactly one of which runs.  Requests (`webkit-agent-request')
;; wrap that for callers that poll, such as the MCP bridge.
;;
;; Runtime actions use JavaScript events. Native input uses Cocoa editing and clicks.

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'tab-line)
(require 'xwidget)

(defgroup webkit-agent nil
  "Scriptable xwidget WebKit pages."
  :group 'web
  :prefix "webkit-agent-")

(defcustom webkit-agent-script-timeout 30
  "Seconds a page script may take before its call fails."
  :type 'number)

(defcustom webkit-agent-load-timeout 30
  "Seconds a navigation may take to finish loading before it fails."
  :type 'number)

(defcustom webkit-agent-display-action
  '((display-buffer-reuse-window display-buffer-in-direction)
    (direction . right)
    (window-width . 0.5)
    (inhibit-same-window . t))
  "The `display-buffer' action that shows a page."
  :type 'sexp)

(defconst webkit-agent--runtime-file
  (expand-file-name "webkit-agent-runtime.js"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The page runtime's source file.")

(defconst webkit-agent--poll-interval 0.05
  "Seconds between checks of pending page work.")

(cl-defstruct (webkit-agent-page (:constructor webkit-agent-page--create))
  "An xwidget WebKit buffer under agent control.
LOADING is non-nil between a navigation and its load-finished event.
LOAD-EVENTS counts load-changed events."
  id buffer loading (load-events 0) downloads)

(cl-defstruct (webkit-agent-request (:constructor webkit-agent-request--create))
  "Asynchronous work polled by ID.  STATUS is pending, done or failed."
  id (status 'pending) value finished-at)

(defvar webkit-agent--pages nil
  "Live pages, oldest first.")

(defvar webkit-agent--page-count 0
  "Number of page IDs handed out.")

(defvar webkit-agent--requests (make-hash-table :test #'equal)
  "Request ID -> `webkit-agent-request'.")

(defvar webkit-agent--request-count 0
  "Number of request IDs handed out.")

(defvar webkit-agent--runtime nil
  "Cons of the runtime source and its version hash, read on first use.")

(defvar xwidget-webkit-profile nil
  "Native profile settings as JSON, or nil for the default data store.")

(defvar-local webkit-agent-workspace nil
  "Workspace owning this browser page.")

(defun webkit-agent--setup-buffer (buffer)
  "Installs browser tabs in BUFFER and returns it."
  (with-current-buffer buffer
    (setq-local webkit-agent-workspace
                (or webkit-agent-workspace
                    (and (bound-and-true-p persp-mode) (persp-current-name)))
                tab-line-format '((:eval (webkit-agent--tabs))))
    (local-set-key (kbd "C-c C-t") #'webkit-agent-new-tab))
  buffer)

(defun webkit-agent--dedicate-windows (frame)
  "Dedicates FRAME's browser windows to browser pages."
  (dolist (window (window-list frame 'no-minibuffer))
    (when (eq (buffer-local-value 'major-mode (window-buffer window)) 'xwidget-webkit-mode)
      (set-window-parameter window 'webkit-agent-browser t)
      (set-window-dedicated-p window t))))

(advice-add 'xwidget-webkit--create-new-session-buffer :filter-return #'webkit-agent--setup-buffer)
(add-hook 'window-buffer-change-functions #'webkit-agent--dedicate-windows)

(defun webkit-agent--button (label function)
  "Returns clickable LABEL invoking FUNCTION in the clicked window."
  (let ((map (make-sparse-keymap)))
    (let ((command (lambda (event)
                     (interactive "e")
                     (select-window (posn-window (event-start event)))
                     (funcall function))))
      (define-key map [tab-line down-mouse-1] command)
      (define-key map [tab-line mouse-1] #'ignore))
    (propertize label 'keymap map 'mouse-face 'highlight)))

(defun webkit-agent--tabs ()
  "Returns tabs for pages belonging to the current browser workspace."
  (let ((workspace webkit-agent-workspace))
    (append
     (mapcar
      (lambda (page)
        (let* ((buffer (webkit-agent-page-buffer page))
               (title (or (xwidget-webkit-title (webkit-agent--xwidget page)) "")))
          (webkit-agent--button
           (propertize
            (format " %s " (if (string-empty-p title) (webkit-agent-page-id page) title))
            'face (if (eq buffer (current-buffer)) 'tab-line-tab-current 'tab-line-tab))
           (lambda ()
             (set-window-dedicated-p (selected-window) nil)
             (set-window-buffer (selected-window) buffer)
             (set-window-dedicated-p (selected-window) t)
             (xwidget-webkit-auto-adjust-size (selected-window))))))
      (seq-filter (lambda (page)
                    (equal workspace (buffer-local-value
                                      'webkit-agent-workspace (webkit-agent-page-buffer page))))
                  (webkit-agent-pages)))
     (list (webkit-agent--button " + " #'webkit-agent-new-tab)))))

(defun webkit-agent-new-tab ()
  "Prompts for an empty URL and opens it in a new browser tab."
  (interactive)
  (let ((url (read-string "New tab URL: ")))
    (unless (string-match-p "\\`[A-Za-z]+:" url)
      (setq url (concat "https://" url)))
    (webkit-agent-open url)))

(declare-function xwidget-webkit-set-user-agent "xwidget.c" (xwidget user-agent))
(declare-function xwidget-webkit-set-viewport "xwidget.c" (xwidget width height))
(declare-function xwidget-webkit-snapshot "xwidget.c" (xwidget file callback))
(declare-function xwidget-webkit-session-command "xwidget.c" (xwidget request callback))

(defun webkit-agent-session (page operation arguments on-value on-error)
  "Run native session OPERATION with ARGUMENTS in PAGE.
Call ON-VALUE with the result or ON-ERROR with an error string.
Signal `user-error' for invalid cookies or unavailable native support."
  (unless (fboundp 'xwidget-webkit-session-command)
    (user-error "Native session controls need the sessions patch; rebuild Emacs"))
  (when (equal operation "set_cookies")
    (webkit-agent--check-cookies (gethash "cookies" arguments)))
  (let ((request (copy-hash-table arguments))
        (settled nil)
        timer)
    (puthash "operation" operation request)
    (setq timer (run-at-time
                 webkit-agent-script-timeout nil
                 (lambda ()
                   (unless settled
                     (setq settled t)
                     (when (equal operation "download")
                       (xwidget-webkit-session-command
                        (webkit-agent--xwidget page) "{\"operation\":\"cancel_download\"}" #'ignore))
                     (funcall on-error (format "Page %s native %s timed out"
                                               (webkit-agent-page-id page) operation))))))
    (condition-case err
        (xwidget-webkit-session-command
         (webkit-agent--xwidget page) (json-serialize request)
         (lambda (reply)
           (unless settled
             (setq settled t)
             (cancel-timer timer)
             (let ((parsed (webkit-agent--parse-reply reply)))
               (cond
                ((not parsed) (funcall on-error "Native session returned invalid JSON"))
                ((gethash "error" parsed) (funcall on-error (gethash "error" parsed)))
                (t (funcall on-value (gethash "value" parsed))))))))
      (error
       (setq settled t)
       (cancel-timer timer)
       (funcall on-error (error-message-string err))))))

(defun webkit-agent--check-cookies (cookies)
  "Signal `user-error' unless COOKIES is a vector of valid cookie objects."
  (unless (vectorp cookies) (user-error "cookies must be an array"))
  (seq-doseq (cookie cookies)
    (unless (and (hash-table-p cookie)
                 (seq-every-p (lambda (key) (stringp (gethash key cookie)))
                              '("domain" "name" "path" "value"))
                 (> (length (gethash "domain" cookie)) 0)
                 (> (length (gethash "name" cookie)) 0)
                 (string-prefix-p "/" (gethash "path" cookie))
                 (not (string-match-p "[\r\n\0]"
                                      (mapconcat (lambda (key) (gethash key cookie))
                                                 '("domain" "name" "path" "value") "")))
                 (seq-every-p (lambda (key) (memq (gethash key cookie :false) '(t :false)))
                              '("http_only" "secure"))
                 (member (gethash "same_site" cookie "") '("" "lax" "strict" "none"))
                 (numberp (gethash "expires" cookie -1)))
      (user-error "Invalid cookie: needs domain, name, path, value and valid attributes"))))

(defun webkit-agent-call (page method arguments on-value on-error)
  "Run runtime METHOD with ARGUMENTS in PAGE.
ARGUMENTS is a JSON-serializable object.  ON-VALUE is called with the
method's value parsed from JSON, with :null and :false for null and false.
ON-ERROR is called with a message when the method throws, the page
navigates away from a pending promise, or `webkit-agent-script-timeout'
passes."
  (let* ((settled nil)
         (timer nil)
         (settle (lambda (callback value)
                   (unless settled
                     (setq settled t)
                     (cancel-timer timer)
                     (funcall callback value)))))
    (setq timer (run-at-time
                 webkit-agent-script-timeout nil
                 (lambda ()
                   (funcall settle on-error
                            (format "Page %s did not answer %s within %ss"
                                    (webkit-agent-page-id page) method
                                    webkit-agent-script-timeout)))))
    (condition-case err
        (webkit-agent--execute
         page method arguments
         (lambda (reply)
           (webkit-agent--handle-reply
            page reply
            (lambda (value) (funcall settle on-value value))
            (lambda (message) (funcall settle on-error message))
            (lambda () settled))))
      (error (funcall settle on-error (error-message-string err))))))

(defun webkit-agent-close (page)
  "Kill PAGE's buffer without confirmation, which destroys its WebKit view.
Windows showing it switch to another workspace tab, or close."
  (let ((buffer (webkit-agent-page-buffer page))
        (kill-buffer-query-functions nil))
    (let* ((workspace (buffer-local-value 'webkit-agent-workspace buffer))
           (next (seq-find
                  (lambda (candidate)
                    (and (not (eq candidate page))
                         (equal workspace (buffer-local-value
                                           'webkit-agent-workspace
                                           (webkit-agent-page-buffer candidate)))))
                  (webkit-agent-pages))))
      (if next
          (dolist (window (get-buffer-window-list buffer nil t))
            (set-window-dedicated-p window nil)
            (set-window-buffer window (webkit-agent-page-buffer next))
            (set-window-dedicated-p window t)
            (xwidget-webkit-auto-adjust-size window))
        (quit-windows-on buffer t)))
    (when (buffer-live-p buffer)
      (kill-buffer buffer)))
  (webkit-agent--forget-dead-pages))

(defun webkit-agent-configure (page settings)
  "Apply SETTINGS's user_agent and viewport to PAGE.
Omitted keys keep their current values; JSON null restores native defaults.
Signal `user-error' for invalid settings or missing native support."
  (webkit-agent--check-settings settings)
  (let ((xwidget (webkit-agent--xwidget page))
        (user-agent (gethash "user_agent" settings 'absent))
        (viewport (gethash "viewport" settings 'absent)))
    (unless (eq user-agent 'absent)
      (xwidget-webkit-set-user-agent xwidget (unless (eq user-agent :null) user-agent)))
    (unless (eq viewport 'absent)
      (xwidget-webkit-set-viewport
       xwidget
       (unless (eq viewport :null) (gethash "width" viewport))
       (unless (eq viewport :null) (gethash "height" viewport))))))

(defun webkit-agent-display (page)
  "Show PAGE with `webkit-agent-display-action' without selecting it.
Return the window."
  (let* ((browser-window
          (seq-find (lambda (window) (window-parameter window 'webkit-agent-browser))
                    (window-list nil 'no-minibuffer)))
         (window
          (if browser-window
              (progn
                (set-window-dedicated-p browser-window nil)
                (set-window-buffer browser-window (webkit-agent-page-buffer page))
                browser-window)
            (display-buffer (webkit-agent-page-buffer page) webkit-agent-display-action))))
    (unless window
      (error "Could not display page %s" (webkit-agent-page-id page)))
    (set-window-parameter window 'webkit-agent-browser t)
    (set-window-dedicated-p window t)
    (xwidget-webkit-auto-adjust-size window)
    window))

(defun webkit-agent-find-page (id)
  "Return the live page with ID.  Signal `user-error' when there is none."
  (or (seq-find (lambda (page) (equal (webkit-agent-page-id page) id))
                (webkit-agent-pages))
      (user-error "No page %s; open pages: %s" id
                  (or (string-join (mapcar #'webkit-agent-page-id (webkit-agent-pages)) ", ")
                      "none"))))

(defun webkit-agent-navigate (page action url on-value on-error)
  "Perform navigation ACTION in PAGE and wait for it to load.
ACTION is goto (to URL), back, forward or reload.  ON-VALUE is called with
the page's info after loading; ON-ERROR with a message."
  (let ((xwidget (webkit-agent--xwidget page))
        (offset (pcase action
                  ("goto" (webkit-agent--check-url url) nil)
                  ("back" -1)
                  ("forward" 1)
                  ("reload" 0)
                  (_ (user-error "Unknown navigation %s" action)))))
    (setf (webkit-agent-page-loading page) t)
    (if offset
        (xwidget-webkit-goto-history xwidget offset)
      (xwidget-webkit-goto-uri xwidget url))
    (webkit-agent-wait-for-load page on-value on-error)))

(defun webkit-agent-open (url &optional hidden settings)
  "Open URL in a new page and return the page.
The page is shown with `webkit-agent-display' unless HIDDEN is non-nil.
SETTINGS applies user_agent and viewport before the first request.
Loading continues after this returns; see `webkit-agent-wait-for-load'."
  (unless (featurep 'xwidget-internal)
    (user-error "This Emacs was built without xwidgets"))
  (webkit-agent--check-url url)
  (when settings (webkit-agent--check-settings settings))
  (let* ((profile (and settings (gethash "profile" settings)))
         (xwidget-webkit-profile
          (when profile
            (let* ((name (gethash "name" profile))
                   (digest (secure-hash 'md5 (concat "emacs-webkit-profile:" name)))
                   (native-profile (copy-hash-table profile)))
              (puthash "identifier"
                       (format "%s-%s-%s-%s-%s" (substring digest 0 8) (substring digest 8 12)
                               (substring digest 12 16) (substring digest 16 20) (substring digest 20))
                       native-profile)
              (json-serialize native-profile))))
         (buffer (xwidget-webkit--create-new-session-buffer url))
         (page (webkit-agent--adopt buffer)))
    (when settings (webkit-agent-configure page settings))
    (setf (webkit-agent-page-loading page) t)
    (unless hidden (webkit-agent-display page))
    (xwidget-webkit-goto-uri (webkit-agent--xwidget page) url)
    page))

(defun webkit-agent-page-summary (page)
  "Return an alist describing PAGE for JSON: id, url, title, loading, shown."
  (let ((xwidget (webkit-agent--xwidget page)))
    `((id . ,(webkit-agent-page-id page))
      (loading . ,(if (webkit-agent-page-loading page) t :false))
      (shown . ,(if (get-buffer-window (webkit-agent-page-buffer page) t) t :false))
      (title . ,(or (xwidget-webkit-title xwidget) ""))
      (url . ,(or (xwidget-webkit-uri xwidget) "")))))

(defun webkit-agent-pages ()
  "Return every live page, adopting xwidget WebKit buffers opened elsewhere."
  (webkit-agent--forget-dead-pages)
  (dolist (buffer (buffer-list))
    (when (and (eq (buffer-local-value 'major-mode buffer) 'xwidget-webkit-mode)
               (not (webkit-agent--page-for-buffer buffer))
               (with-current-buffer buffer (xwidget-at (point-min))))
      (webkit-agent--adopt buffer)))
  webkit-agent--pages)

(defun webkit-agent-request (function)
  "Start a request that FUNCTION completes and return the request's ID.
FUNCTION is called with ON-VALUE and ON-ERROR.  The first one called settles
the request; an error FUNCTION signals fails it."
  (webkit-agent--forget-old-requests)
  (let* ((id (format "r%d" (cl-incf webkit-agent--request-count)))
         (request (webkit-agent-request--create :id id))
         (settle (lambda (status value)
                   (when (eq (webkit-agent-request-status request) 'pending)
                     (setf (webkit-agent-request-status request) status
                           (webkit-agent-request-value request) value
                           (webkit-agent-request-finished-at request) (float-time))))))
    (puthash id request webkit-agent--requests)
    (condition-case err
        (funcall function
                 (lambda (value) (funcall settle 'done value))
                 (lambda (message) (funcall settle 'failed message)))
      (error (funcall settle 'failed (error-message-string err))))
    id))

(defun webkit-agent-request-take (id)
  "Return request ID's outcome as (STATUS . VALUE) and forget finished ones.
STATUS is pending, done or failed; a failed VALUE is the error message."
  (let ((request (or (gethash id webkit-agent--requests)
                     (user-error "Unknown or already collected request %s" id))))
    (unless (eq (webkit-agent-request-status request) 'pending)
      (remhash id webkit-agent--requests))
    (cons (webkit-agent-request-status request) (webkit-agent-request-value request))))

(defun webkit-agent-screenshot (page file on-value on-error)
  "Capture PAGE's full viewport to PNG FILE without changing windows.
ON-VALUE receives FILE; ON-ERROR receives a failure message.
Signal `user-error' when native snapshot support is absent."
  (unless (fboundp 'xwidget-webkit-snapshot)
    (user-error "Page %s needs the native snapshot patch; rebuild Emacs"
                (webkit-agent-page-id page)))
  (let* ((timer nil)
        (settled nil)
        (finish (lambda (failure)
                  (unless settled
                    (setq settled t)
                    (when timer (cancel-timer timer))
                    (if failure
                        (progn (when (file-exists-p file) (delete-file file))
                               (funcall on-error failure))
                      (funcall on-value file))))))
    (setq timer (run-at-time webkit-agent-script-timeout nil
                             (lambda ()
                               (funcall finish (format "Snapshot timed out for page %s: %s"
                                                       (webkit-agent-page-id page) file)))))
    (condition-case err
        (xwidget-webkit-snapshot (webkit-agent--xwidget page) (expand-file-name file) finish)
      (error (funcall finish (error-message-string err))))))

(defun webkit-agent-wait (page condition timeout on-value on-error)
  "Poll runtime check CONDITION in PAGE until it holds or TIMEOUT seconds pass.
CONDITION is the object the runtime's check method takes.  Checks that fail
while the page is loading are retried.  ON-VALUE is called with the check's
detail; ON-ERROR with a message."
  (let ((deadline (+ (float-time) timeout))
        (last-detail "not checked"))
    (cl-labels
        ((retry ()
           (if (> (float-time) deadline)
               (funcall on-error (format "Timed out after %ss waiting for %s in page %s; last saw: %s"
                                         timeout (json-serialize condition)
                                         (webkit-agent-page-id page) last-detail))
             (run-at-time 0.1 nil #'check)))
         (check ()
           (if (not (buffer-live-p (webkit-agent-page-buffer page)))
               (funcall on-error (format "Page %s was closed" (webkit-agent-page-id page)))
             (webkit-agent-call
              page "check" condition
              (lambda (result)
                (setq last-detail (gethash "detail" result))
                (if (eq (gethash "met" result) t)
                    (funcall on-value last-detail)
                  (retry)))
              (lambda (message)
                (if (webkit-agent-page-loading page)
                    (retry)
                  (funcall on-error message)))))))
      (check))))

(defun webkit-agent-wait-for-load (page on-value on-error)
  "Call ON-VALUE with PAGE's info once its current navigation finishes.
A navigation that produces no load event within 3 seconds counts as
finished.  ON-ERROR is called with a message after `webkit-agent-load-timeout'."
  (let* ((start (float-time))
         (events (webkit-agent-page-load-events page)))
    (cl-labels
        ((poll ()
           (let ((elapsed (- (float-time) start))
                 (idle (= events (webkit-agent-page-load-events page))))
             (cond
              ((not (buffer-live-p (webkit-agent-page-buffer page)))
               (funcall on-error (format "Page %s was closed" (webkit-agent-page-id page))))
              ((and idle (> elapsed 3))
               (setf (webkit-agent-page-loading page) nil)
               (webkit-agent-call page "info" nil on-value on-error))
              ((not (webkit-agent-page-loading page))
               (webkit-agent-call page "info" nil on-value on-error))
              ((> elapsed webkit-agent-load-timeout)
               (funcall on-error (format "Page %s did not finish loading %s within %ss"
                                         (webkit-agent-page-id page)
                                         (xwidget-webkit-uri (webkit-agent--xwidget page))
                                         webkit-agent-load-timeout)))
              (t (run-at-time webkit-agent--poll-interval nil #'poll))))))
      (run-at-time webkit-agent--poll-interval nil #'poll))))

(defun webkit-agent--execute (page method arguments callback)
  "Send runtime METHOD with ARGUMENTS to PAGE; CALLBACK gets the JSON reply string.
CALLBACK never runs when the script fails to parse or the page goes away."
  (pcase-let ((`(,source . ,version) (webkit-agent--runtime)))
    (xwidget-webkit-execute-script
     (webkit-agent--xwidget page)
     (format "(() => { try { return (%s)(%s).invoke(%s, %s); } catch (error) { return JSON.stringify({error: String(error && error.stack || error)}); } })()"
             source (json-serialize version) (json-serialize method)
             (json-serialize (or arguments (make-hash-table))))
     callback)))

(defun webkit-agent--runtime ()
  "Return (SOURCE . VERSION) of the page runtime, reading it on first use."
  (or webkit-agent--runtime
      (let ((source (with-temp-buffer
                      (insert-file-contents webkit-agent--runtime-file)
                      (string-trim (buffer-string)))))
        (setq webkit-agent--runtime (cons source (secure-hash 'sha1 source))))))

(defun webkit-agent--handle-reply (page reply on-value on-error settled-p)
  "Dispatch PAGE's JSON REPLY string to ON-VALUE or ON-ERROR.
An {async: token} reply is awaited with `webkit-agent--await'."
  (let ((parsed (webkit-agent--parse-reply reply)))
    (when (and parsed (gethash "downloads" parsed))
      (setf (webkit-agent-page-downloads page)
            (append (webkit-agent-page-downloads page) (append (gethash "downloads" parsed) nil))))
    (cond
     ((not parsed)
      (funcall on-error (format "Page %s returned a non-JSON reply: %S" (webkit-agent-page-id page) reply)))
     ((gethash "error" parsed)
      (funcall on-error (gethash "error" parsed)))
     ((gethash "async" parsed)
      (webkit-agent--await page (gethash "async" parsed) on-value on-error settled-p))
     (t (funcall on-value (gethash "value" parsed))))))

(defun webkit-agent--parse-reply (reply)
  "Return REPLY parsed as a JSON object, or nil when it is not one."
  (when (stringp reply)
    (let ((parsed (ignore-errors (json-parse-string reply :null-object :null :false-object :false))))
      (and (hash-table-p parsed) parsed))))

(defun webkit-agent--await (page token on-value on-error settled-p)
  "Poll PAGE for the outcome of the promise behind TOKEN.
Polling stops once SETTLED-P returns non-nil; the outcome goes to
`webkit-agent--handle-reply'."
  (run-at-time
   webkit-agent--poll-interval nil
   (lambda ()
     (unless (funcall settled-p)
       (webkit-agent--execute
        page "take" `((token . ,token))
        (lambda (reply)
          (if (eq (gethash "pending" (or (webkit-agent--parse-reply reply) (make-hash-table))) t)
              (webkit-agent--await page token on-value on-error settled-p)
            (webkit-agent--handle-reply page reply on-value on-error settled-p))))))))

(defun webkit-agent--forget-dead-pages ()
  "Drop pages whose buffers were killed."
  (setq webkit-agent--pages
        (seq-filter (lambda (page) (buffer-live-p (webkit-agent-page-buffer page)))
                    webkit-agent--pages)))

(defun webkit-agent--xwidget (page)
  "Return PAGE's xwidget.  Signal `user-error' when the page is gone."
  (let ((buffer (webkit-agent-page-buffer page)))
    (or (and (buffer-live-p buffer)
             (with-current-buffer buffer (xwidget-at (point-min))))
        (user-error "Page %s was closed" (webkit-agent-page-id page)))))

(defun webkit-agent--check-url (url)
  "Signal `user-error' unless URL is an http, https, file, about or data URL."
  (unless (and (stringp url) (string-match-p "\\`\\(https?\\|file\\|about\\|data\\):" url))
    (user-error "Need an http, https, file, about or data URL, not %S" url)))

(defun webkit-agent--check-settings (settings)
  "Signal `user-error' for invalid SETTINGS or unavailable native APIs."
  (let ((user-agent (gethash "user_agent" settings 'absent))
        (viewport (gethash "viewport" settings 'absent))
        (profile (gethash "profile" settings 'absent)))
    (unless (eq profile 'absent)
      (unless (and (hash-table-p profile)
                   (stringp (gethash "name" profile))
                   (string-match-p "\\`[A-Za-z0-9_-]\\{1,64\\}\\'" (gethash "name" profile))
                   (not (equal (gethash "name" profile) "default"))
                   (memq (gethash "persistent" profile :false) '(t :false)))
        (user-error "profile needs a name (1..64 letters, digits, _ or -; excluding default) and a boolean persistent"))
      (unless (fboundp 'xwidget-webkit-session-command)
        (user-error "profile needs the native sessions patch; rebuild Emacs")))
    (unless (eq user-agent 'absent)
      (unless (or (eq user-agent :null) (and (stringp user-agent) (> (length user-agent) 0)
                                            (not (string-match-p "[\r\n\0]" user-agent))))
        (user-error "user_agent must be null or a non-empty string without control separators"))
      (unless (fboundp 'xwidget-webkit-set-user-agent)
        (user-error "user_agent needs the native user-agent patch; rebuild Emacs")))
    (unless (eq viewport 'absent)
      (unless (or (eq viewport :null)
                  (and (hash-table-p viewport)
                       (seq-every-p (lambda (key)
                                      (let ((dimension (gethash key viewport)))
                                        (and (integerp dimension) (<= 1 dimension 4096))))
                                    '("width" "height"))))
        (user-error "viewport must be null or width and height integers in 1..4096"))
      (unless (fboundp 'xwidget-webkit-set-viewport)
        (user-error "viewport needs the native viewport patch; rebuild Emacs")))))

(defun webkit-agent--adopt (buffer)
  "Register xwidget WebKit BUFFER as a page, track its loads, and return it."
  (let* ((page (webkit-agent-page--create
                :id (format "p%d" (cl-incf webkit-agent--page-count))
                :buffer buffer))
         (xwidget (webkit-agent--xwidget page)))
    (xwidget-put xwidget 'callback #'webkit-agent--callback)
    (with-current-buffer buffer
      (setq-local mode-line-process (format " %s" (webkit-agent-page-id page))))
    (webkit-agent--setup-buffer buffer)
    (setq webkit-agent--pages (append webkit-agent--pages (list page)))
    page))

(defun webkit-agent--callback (xwidget type)
  "Handle XWIDGET's event TYPE as `xwidget-webkit-callback' does, tracking loads.
The runtime is installed when a load commits and again when it finishes, so
console messages are recorded from early in the page's life."
  (if (eq type 'download-callback)
      (when-let* ((page (webkit-agent--page-for-buffer (xwidget-buffer xwidget))))
        (setf (webkit-agent-page-loading page) nil)
        (push `((url . ,(nth 3 last-input-event))
                (mime_type . ,(nth 4 last-input-event))
                (filename . ,(nth 5 last-input-event)))
              (webkit-agent-page-downloads page)))
    (xwidget-webkit-callback xwidget type))
  (when-let* (((eq type 'load-changed))
              (page (webkit-agent--page-for-buffer (xwidget-buffer xwidget)))
              (state (nth 3 last-input-event)))
    (cl-incf (webkit-agent-page-load-events page))
    (setf (webkit-agent-page-loading page) (not (equal state "load-finished")))
    (when (member state '("load-committed" "load-finished"))
      (webkit-agent--execute page "info" nil #'ignore))))

(defun webkit-agent--page-for-buffer (buffer)
  "Return the page shown by BUFFER, or nil."
  (seq-find (lambda (page) (eq (webkit-agent-page-buffer page) buffer)) webkit-agent--pages))

(defun webkit-agent--forget-old-requests ()
  "Drop requests that finished more than five minutes ago without being taken."
  (let ((cutoff (- (float-time) 300)))
    (maphash (lambda (id request)
               (when-let* ((finished (webkit-agent-request-finished-at request))
                           ((< finished cutoff)))
                 (remhash id webkit-agent--requests)))
             webkit-agent--requests)))

(provide 'webkit-agent)
;;; webkit-agent.el ends here
