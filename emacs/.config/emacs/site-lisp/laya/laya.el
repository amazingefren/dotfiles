;;; laya.el --- Lazy typed decisions from Emacs  -*- lexical-binding: t; -*-

;; The wire protocol is JSON lines.  The worker is the sole owner of model
;; state; merely loading this library does not start Python or load weights.

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'auth-source)

(defgroup laya nil "Typed decisions in Emacs." :group 'applications)
(defcustom laya-python nil
  "Python executable for the Laya worker, or nil for its bootstrapped venv."
  :type '(choice (const nil) file))
(defcustom laya-mlx-model "aac6fef/laya-mlx" "Default local checkpoint." :type 'string)
(defcustom laya-jev-model "jev-1.13.0" "Default remote model." :type 'string)
(defcustom laya-jev-key-function #'laya--default-jev-key
  "Function returning a TypeSafe API key only when a Jev job runs."
  :type 'function)
(defcustom laya-max-queue 64 "Maximum pending requests." :type 'integer)
(defcustom laya-max-request-bytes 1000000 "Maximum UTF-8 request size." :type 'integer)
(defcustom laya-retained-jobs 100 "Maximum completed jobs retained in memory." :type 'integer)
(defcustom laya-request-timeout 300 "Seconds allowed for one worker operation." :type 'number)
(defcustom laya-start-timeout 30 "Seconds allowed for worker readiness." :type 'number)
(defcustom laya-idle-seconds 600 "Seconds of inactivity before stopping the worker; nil disables." :type '(choice (const nil) number))
(defcustom laya-diagnostic-limit 20000 "Maximum characters kept from worker stderr." :type 'integer)

(cl-defstruct (laya--job (:constructor laya--make-job))
  id owner op request callback status result error created-at finished-at timer callback-sent)

(defvar laya--jobs (make-hash-table :test #'equal))
(defvar laya--completed nil)
(defvar laya--queue nil)
(defvar laya--active nil)
(defvar laya--process nil)
(defvar laya--stderr-process nil)
(defvar laya--ready nil)
(defvar laya--partial "")
(defvar laya--startup-timer nil)
(defvar laya--idle-timer nil)
(defvar laya--serial 0)
(defvar laya--stderr-buffer " *laya worker stderr*")
(defconst laya--directory
  (file-name-directory (or load-file-name (locate-library "laya")))
  "Directory containing this package and its Python worker.")

(defun laya--python ()
  (let ((python (or laya-python
                    (expand-file-name "etc/laya/venv/bin/python"
                                      user-emacs-directory))))
    (setq python (cond ((file-name-absolute-p python) python)
                       ((file-executable-p python) (expand-file-name python))
                       (t (or (executable-find python) python))))
    (unless (file-executable-p python)
      (error "LAYA Python is unavailable: %s. Run M-x laya-bootstrap" python))
    python))

(defun laya--worker-file ()
  (expand-file-name "worker.py" laya--directory))

(defun laya--default-jev-key ()
  (or (getenv "TYPESAFE_API_KEY")
      (when-let* ((entry (car (auth-source-search :host "api.typesafe.ai"
                                                  :max 1 :require '(:secret))))
                  (secret (plist-get entry :secret)))
        (if (functionp secret) (funcall secret) secret))))

(defun laya--json-copy (object)
  (json-parse-string (json-serialize object :null-object :null :false-object :false)
                     :object-type 'hash-table :array-type 'array
                     :null-object :null :false-object :false))

(defun laya--object (&rest pairs)
  (let ((object (make-hash-table :test #'equal)))
    (while pairs (puthash (pop pairs) (pop pairs) object))
    object))

(defun laya--now () (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun laya--snapshot (job)
  (let* ((request (laya--job-request job))
         (snapshot (laya--object
                    "id" (laya--job-id job)
                    "status" (laya--job-status job)
                    "request" (laya--json-copy request)
                    "result" (if (laya--job-result job)
                                 (laya--json-copy (laya--job-result job)) :null)
                    "error" (if (laya--job-error job)
                                (laya--json-copy (laya--job-error job)) :null)
                    "created_at" (laya--job-created-at job)
                    "finished_at" (or (laya--job-finished-at job) :null)
                    "backend" (gethash "backend" request)
                    "model" (gethash "model" request))))
    snapshot))

(defun laya--lookup (id owner)
  (let ((job (gethash id laya--jobs)))
    (unless (and job (equal owner (laya--job-owner job)))
      (error "Unknown Laya job"))
    job))

(defun laya-result (id &optional owner)
  "Return a JSON-compatible snapshot of ID, accessible to OWNER."
  (laya--snapshot (laya--lookup id owner)))

(defun laya--callback-later (job)
  (when (and (laya--job-callback job) (not (laya--job-callback-sent job)))
    (setf (laya--job-callback-sent job) t)
    (let ((callback (laya--job-callback job)) (snapshot (laya--snapshot job)))
      (run-at-time 0 nil
                   (lambda ()
                     (condition-case err (funcall callback snapshot)
                       (error (message "Laya callback: %s" (error-message-string err)))))))))

(defun laya--prune ()
  (while (> (length laya--completed) (max 0 laya-retained-jobs))
    (remhash (car laya--completed) laya--jobs)
    (setq laya--completed (cdr laya--completed))))

(defun laya--finish (job status &optional result error-object)
  (unless (member (laya--job-status job) '("succeeded" "failed" "cancelled"))
    ;; A running cancellation is logical: the worker still occupies the one
    ;; request slot.  Keep its deadline until a reply or worker termination.
    (unless (and (equal status "cancelled") (eq job laya--active))
      (laya--clear-job-timer job))
    (setf (laya--job-status job) status
          (laya--job-result job) result
          (laya--job-error job) error-object
          (laya--job-finished-at job) (laya--now))
    (setq laya--completed (append laya--completed (list (laya--job-id job))))
    (laya--callback-later job)
    (laya--prune)))

(defun laya--clear-job-timer (job)
  (when (laya--job-timer job) (cancel-timer (laya--job-timer job)))
  (setf (laya--job-timer job) nil))

(defun laya--error (code message &optional details)
  (let ((value (laya--object "code" code "message" message)))
    (when details (puthash "details" details value)) value))

(defun laya--write (object)
  (unless (process-live-p laya--process) (error "Laya worker is not running"))
  (process-send-string laya--process
                       (concat (json-serialize object :null-object :null
                                               :false-object :false) "\n")))

(defun laya--cancel-idle ()
  (when laya--idle-timer (cancel-timer laya--idle-timer) (setq laya--idle-timer nil)))

(defun laya--schedule-idle ()
  (laya--cancel-idle)
  (when (and laya-idle-seconds (null laya--active) (null laya--queue)
             (process-live-p laya--process))
    (setq laya--idle-timer
          (run-at-time laya-idle-seconds nil
                       (lambda () (when (and (null laya--active) (null laya--queue))
                                    (laya-stop)))))))

(defun laya--dispatch-next ()
  (when (and laya--ready (null laya--active) laya--queue)
    (laya--cancel-idle)
    (let ((job (pop laya--queue)))
      (setq laya--active job)
      (condition-case err
          (progn
            (when (equal (gethash "backend" (laya--job-request job)) "jev")
              (let ((key (funcall laya-jev-key-function)))
                (unless (and (stringp key) (not (string-empty-p key)))
                  (error "No TypeSafe API key configured"))
                (laya--write (laya--object "op" "configure" "jev_api_key" key))))
            (setf (laya--job-status job) "running")
            (let ((wire (laya--json-copy (laya--job-request job))))
              (puthash "id" (laya--job-id job) wire)
              (puthash "op" (or (laya--job-op job) "evaluate") wire)
              (laya--write wire))
            (setf (laya--job-timer job)
                  (run-at-time laya-request-timeout nil #'laya--timeout
                               (laya--job-id job))))
        (error
         (laya--finish job "failed" nil
                       (laya--error "dispatch" (error-message-string err)))
         (setq laya--active nil)
         (laya--dispatch-next))))))

(defun laya--timeout (id)
  (when (and laya--active (equal id (laya--job-id laya--active)))
    (laya--finish laya--active "failed" nil
                  (laya--error "timeout" "Laya worker request timed out"))
    (laya--worker-failed "Laya worker stopped after a timeout")))

(defun laya--handle-line (line)
  (condition-case err
      (let* ((message (json-parse-string line :object-type 'hash-table
                                         :array-type 'array :null-object :null
                                         :false-object :false))
             (_ (unless (hash-table-p message)
                  (error "Worker response must be an object")))
             (event (gethash "event" message))
             (id (gethash "id" message)))
        (cond
         ((equal event "ready")
          (unless (= (or (gethash "protocol" message) -1) 1)
            (error "Unsupported Laya worker protocol"))
          (setq laya--ready t)
          (when laya--startup-timer
            (cancel-timer laya--startup-timer) (setq laya--startup-timer nil))
          (laya--dispatch-next)
          (laya--schedule-idle))
         ((and laya--active (equal id (laya--job-id laya--active)))
          (let* ((job laya--active)
                 (ok (gethash "ok" message))
                 (result (gethash "result" message))
                 (failure (gethash "error" message)))
            (cond
             ((eq ok t)
              (unless (and (hash-table-p result)
                           (or (not (equal (laya--job-op job) nil))
                               (hash-table-p (gethash "answers" result))))
                (error "Worker success is missing a result or answers")))
             ((eq ok :false)
              (unless (and (hash-table-p failure)
                           (stringp (gethash "code" failure))
                           (stringp (gethash "message" failure)))
                (error "Worker failure is missing error details")))
             (t (error "Worker reply has no valid ok field")))
            (laya--clear-job-timer job)
            (setq laya--active nil)
            (if (eq ok t)
                (laya--finish job "succeeded" result)
              (laya--finish job "failed" nil failure))
            (laya--dispatch-next)
            (laya--schedule-idle)))
         ((or id (gethash "ok" message))
          (error "Worker reply has an unexpected request id"))))
    (error (laya--worker-failed (format "Invalid worker response: %s"
                                        (error-message-string err))))))

(defun laya--filter (process chunk)
  (when (eq process laya--process)
    (setq laya--partial (concat laya--partial chunk))
    (let (position)
      (while (and (eq process laya--process)
                  (setq position (string-match "\n" laya--partial)))
        (let ((line (substring laya--partial 0 position)))
          (setq laya--partial (substring laya--partial (1+ position)))
          (when (> (string-bytes line) laya-max-request-bytes)
            (laya--worker-failed "Worker output line exceeded size limit"))
          (when (and (eq process laya--process) (not (string-empty-p line)))
            (laya--handle-line line)))))
    (when (> (string-bytes laya--partial) laya-max-request-bytes)
      (laya--worker-failed "Worker output line exceeded size limit"))))

(defun laya--worker-failed (message)
  (when laya--startup-timer
    (cancel-timer laya--startup-timer) (setq laya--startup-timer nil))
  (laya--cancel-idle)
  (let ((process laya--process))
    (setq laya--process nil laya--ready nil laya--partial "")
    (when (process-live-p process) (delete-process process)))
  (when (process-live-p laya--stderr-process)
    (delete-process laya--stderr-process))
  (setq laya--stderr-process nil)
  (when laya--active
    (laya--clear-job-timer laya--active)
    (laya--finish laya--active "failed" nil (laya--error "worker" message))
    (setq laya--active nil))
  (dolist (job laya--queue)
    (laya--finish job "failed" nil (laya--error "worker" message)))
  (setq laya--queue nil))

(defun laya--sentinel (process _event)
  (when (and (eq process laya--process) (not (process-live-p process)))
    (laya--worker-failed "Laya worker exited")))

(defun laya--stderr-filter (process chunk)
  (when-let* (((eq process laya--stderr-process))
              (buffer (get-buffer-create laya--stderr-buffer)))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert chunk)
      (when (> (buffer-size) laya-diagnostic-limit)
        (delete-region (point-min) (- (point-max) laya-diagnostic-limit))))))

(defun laya-start ()
  "Start the worker process without loading a model."
  (interactive)
  (unless (process-live-p laya--process)
    (let ((worker (laya--worker-file))
          (python (laya--python)))
      (unless (file-readable-p worker) (error "Laya worker missing: %s" worker))
      (let ((process-environment (copy-sequence process-environment)))
        (setenv "PYTHONDONTWRITEBYTECODE" "1")
        (setenv "HF_HOME" (expand-file-name "etc/laya/huggingface" user-emacs-directory))
        (setq laya--partial "" laya--ready nil)
        (setq laya--stderr-process
              (make-pipe-process :name "laya-worker-stderr" :noquery t
                                 :buffer nil :filter #'laya--stderr-filter))
        (setq laya--process
              (make-process :name "laya-worker" :command (list python worker)
                            :connection-type 'pipe :coding 'utf-8-unix :noquery t
                            :buffer nil :stderr laya--stderr-process
                            :filter #'laya--filter :sentinel #'laya--sentinel))
        (setq laya--startup-timer
              (run-at-time laya-start-timeout nil
                           (lambda () (unless laya--ready
                                        (laya--worker-failed "Laya worker startup timed out"))))))))
  (laya-status))

(defun laya-status ()
  "Return process and queue status; interactively display a summary."
  (interactive)
  (let ((status (laya--object "process" (if (process-live-p laya--process)
                                            (if laya--ready "ready" "starting") "stopped")
                              "queued" (length laya--queue)
                              "active" (or (and laya--active (laya--job-id laya--active)) :null))))
    (when (called-interactively-p 'interactive)
      (message "Laya: %s, %s queued" (gethash "process" status)
               (gethash "queued" status)))
    status))

(defun laya-stop ()
  "Stop the worker and fail outstanding jobs."
  (interactive)
  (laya--worker-failed "Laya worker stopped")
  (laya-status))

(add-hook 'kill-emacs-hook #'laya-stop)

(defun laya-restart ()
  "Restart the worker without preloading a model."
  (interactive)
  (laya-stop)
  (laya-start))

(defun laya-warm (&optional backend model)
  "Explicitly load BACKEND's MODEL.  This may download weights."
  (interactive)
  (let ((backend (or backend "mlx")))
    (unless (equal backend "mlx") (error "Only local MLX models can be warmed"))
    (let* ((id (format "laya-%d-%d" (time-convert nil 'integer)
                       (cl-incf laya--serial)))
           (request (laya--object "backend" "mlx"
                                  "model" (or model laya-mlx-model)))
           (job (laya--make-job :id id :op "warm" :request request
                                  :status "queued" :created-at (laya--now))))
      (when (>= (+ (length laya--queue) (if laya--active 1 0)) laya-max-queue)
        (error "Laya queue is full"))
      (puthash id job laya--jobs)
      (setq laya--queue (append laya--queue (list job)))
      (condition-case err (laya-start)
        (error (laya--worker-failed (error-message-string err))))
      (laya--dispatch-next)
      id)))

(cl-defun laya-submit (state questions &key backend model revision
                            allow-truncation callback owner)
  "Queue typed QUESTIONS over STATE and return a job id.
CALLBACK receives one completed snapshot on a later timer tick.  OWNER must
match exactly on subsequent result and cancellation calls."
  (let* ((backend (if (symbolp backend) (symbol-name (or backend 'mlx))
                    (or backend "mlx")))
         (model (or model (pcase backend
                            ("mlx" laya-mlx-model)
                            ("jev" laya-jev-model)
                            (_ (error "Unknown Laya backend: %s" backend)))))
         (request (laya--object "state" state "questions" questions
                                "backend" backend "model" model
                                "allow_truncation" (if allow-truncation t :false)))
         (id (format "laya-%d-%d" (time-convert nil 'integer)
                     (cl-incf laya--serial))))
    (unless (member backend '("mlx" "jev")) (error "Unknown Laya backend"))
    (unless (and (stringp model) (not (string-empty-p model))) (error "Invalid model"))
    (unless (hash-table-p questions) (error "Questions must be a JSON object/hash table"))
    (when revision (puthash "revision" revision request))
    (setq request (laya--json-copy request))
    (when (> (string-bytes (json-serialize request :null-object :null :false-object :false))
             laya-max-request-bytes)
      (error "Laya request exceeds size limit"))
    (when (>= (+ (length laya--queue) (if laya--active 1 0)) laya-max-queue)
      (error "Laya queue is full"))
    (let ((job (laya--make-job :id id :owner owner :request request
                                :callback callback :status "queued"
                                :created-at (laya--now))))
      (puthash id job laya--jobs)
      (setq laya--queue (append laya--queue (list job)))
      (condition-case err (laya-start)
        (error (laya--worker-failed (error-message-string err))))
      (laya--dispatch-next)
      id)))

(defun laya-cancel (id &optional owner)
  "Cancel ID if queued; discard a running job's eventual result."
  (let ((job (laya--lookup id owner)))
    (cond
     ((equal (laya--job-status job) "queued")
      (setq laya--queue (delq job laya--queue))
      (laya--finish job "cancelled")
      (laya--schedule-idle))
     ((equal (laya--job-status job) "running")
      (laya--finish job "cancelled")))
    (laya--snapshot job)))

(provide 'laya)
;;; laya.el ends here
