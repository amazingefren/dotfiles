;;; webkit-agent.el --- Scriptable xwidget WebKit pages for agents -*- lexical-binding: t -*-

;; A page is an xwidget-webkit buffer with a short ID such as "p1".  Pages
;; opened elsewhere are adopted when listed.  Work in a page runs through
;; webkit-agent-runtime.js and finishes asynchronously: `webkit-agent-call'
;; and the navigation and wait functions take ON-VALUE and ON-ERROR
;; callbacks, exactly one of which runs.  Requests (`webkit-agent-request')
;; wrap that for callers that poll, such as the MCP bridge.
;;
;; Input is synthesized in JavaScript, so events have isTrusted false and CSS
;; :hover does not apply.  Screenshots capture the page's window on screen and
;; need Screen Recording permission for Emacs.

(require 'cl-lib)
(require 'json)
(require 'subr-x)
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
  id buffer loading (load-events 0))

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
Windows showing it go back to what they showed before, or close."
  (let ((buffer (webkit-agent-page-buffer page))
        (kill-buffer-query-functions nil))
    (quit-windows-on buffer t)
    (when (buffer-live-p buffer)
      (kill-buffer buffer)))
  (webkit-agent--forget-dead-pages))

(defun webkit-agent-display (page)
  "Show PAGE with `webkit-agent-display-action' without selecting it.
Return the window."
  (let ((window (display-buffer (webkit-agent-page-buffer page) webkit-agent-display-action)))
    (unless window
      (error "Could not display page %s" (webkit-agent-page-id page)))
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

(defun webkit-agent-open (url &optional hidden)
  "Open URL in a new page and return the page.
The page is shown with `webkit-agent-display' unless HIDDEN is non-nil.
Loading continues after this returns; see `webkit-agent-wait-for-load'."
  (unless (featurep 'xwidget-internal)
    (user-error "This Emacs was built without xwidgets"))
  (webkit-agent--check-url url)
  (let* ((buffer (save-window-excursion
                   (xwidget-webkit-new-session url)
                   (current-buffer)))
         (page (webkit-agent--adopt buffer)))
    (setf (webkit-agent-page-loading page) t)
    (unless hidden (webkit-agent-display page))
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
  "Show PAGE and capture its window to PNG FILE.
ON-VALUE is called with FILE; ON-ERROR with a message.  Capturing needs
Screen Recording permission for Emacs and the window unobscured on screen."
  (let ((window (webkit-agent-display page)))
    (redisplay t)
    (run-at-time
     0.3 nil
     (lambda ()
       (condition-case err
           (pcase-let* ((`(,frame-left ,frame-top . ,_)
                         (frame-edges (window-frame window) 'native-edges))
                        (`(,left ,top ,right ,bottom) (window-inside-pixel-edges window))
                        (region (format "-R%d,%d,%d,%d" (+ frame-left left) (+ frame-top top)
                                        (- right left) (- bottom top))))
             (with-temp-buffer
               (unless (zerop (call-process "screencapture" nil t nil "-x" "-t" "png" region file))
                 (error "screencapture failed for page %s: %s; grant Emacs Screen Recording permission in System Settings > Privacy & Security"
                        (webkit-agent-page-id page) (string-trim (buffer-string)))))
             (funcall on-value file))
         (error (funcall on-error (error-message-string err))))))))

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

(defun webkit-agent--adopt (buffer)
  "Register xwidget WebKit BUFFER as a page, track its loads, and return it."
  (let* ((page (webkit-agent-page--create
                :id (format "p%d" (cl-incf webkit-agent--page-count))
                :buffer buffer))
         (xwidget (webkit-agent--xwidget page)))
    (xwidget-put xwidget 'callback #'webkit-agent--callback)
    (with-current-buffer buffer
      (setq-local mode-line-process (format " %s" (webkit-agent-page-id page))))
    (setq webkit-agent--pages (append webkit-agent--pages (list page)))
    page))

(defun webkit-agent--callback (xwidget type)
  "Handle XWIDGET's event TYPE as `xwidget-webkit-callback' does, tracking loads.
The runtime is installed when a load commits and again when it finishes, so
console messages are recorded from early in the page's life."
  (xwidget-webkit-callback xwidget type)
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
