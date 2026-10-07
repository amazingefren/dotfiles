;;; decisions.el --- Lazy typed decisions from Emacs  -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'auth-source)

(defgroup decisions nil "Typed decisions in Emacs." :group 'applications)
(defcustom decisions-python nil
  "Python executable for the Decisions worker, or nil for its bootstrapped venv."
  :type '(choice (const nil) file))
(defcustom decisions-mlx-model "mlx-community/clef-flash-8bit" "Default local checkpoint." :type 'string)
(defcustom decisions-laya-model "aac6fef/laya-mlx" "Local Laya checkpoint." :type 'string)
(defcustom decisions-jev-model "jev-1.13.0" "Default remote model." :type 'string)
(defcustom decisions-default-backend "mlx"
  "Backend for requests that name none: \"mlx\" and \"laya\" run locally, \"jev\" calls TypeSafe."
  :type '(choice (const "mlx") (const "laya") (const "jev")))
(defcustom decisions-jev-key-function #'decisions--default-jev-key
  "Function returning a TypeSafe API key only when a Jev job runs."
  :type 'function)
(defcustom decisions-max-queue 64 "Maximum pending requests." :type 'integer)
(defcustom decisions-jev-concurrency 10
  "Maximum Jev requests in flight at once.  Local backends run one request at a time.
TypeSafe's limit is 80 requests per second; a request takes about 150 ms."
  :type 'natnum)
(defcustom decisions-max-request-bytes 1000000 "Maximum UTF-8 request size." :type 'integer)
(defcustom decisions-retained-jobs 100 "Maximum completed jobs retained in memory." :type 'integer)
(defcustom decisions-request-timeout 300 "Seconds allowed for one worker operation." :type 'number)
(defcustom decisions-start-timeout 30 "Seconds allowed for worker readiness." :type 'number)
(defcustom decisions-idle-seconds 600 "Seconds of inactivity before stopping the worker; nil disables." :type '(choice (const nil) number))
(defcustom decisions-diagnostic-limit 20000 "Maximum characters kept from worker stderr." :type 'integer)

(cl-defstruct (decisions--job (:constructor decisions--make-job))
  "Stores one owned request, its completion callback, deadline, and result."
  id owner op request callback status result error created-at finished-at timer callback-sent)

(defvar decisions--jobs (make-hash-table :test #'equal))
(defvar decisions--completed nil)
(defvar decisions--queue nil)
(defvar decisions--active nil
  "Jobs sent to the worker and not yet answered, newest first.")
(defvar decisions--process nil)
(defvar decisions--stderr-process nil)
(defvar decisions--ready nil)
(defvar decisions--partial "")
(defvar decisions--startup-timer nil)
(defvar decisions--idle-timer nil)
(defvar decisions--serial 0)
(defvar decisions--stderr-buffer " *decisions worker stderr*")
(defconst decisions--directory
  (file-name-directory (or load-file-name (locate-library "decisions")))
  "Directory containing this package and its Python worker.")

(defun decisions--python ()
  "Returns the configured executable path; raises when it is unavailable."
  (let ((python (or decisions-python
                    (expand-file-name "etc/decisions/venv/bin/python"
                                      user-emacs-directory))))
    (setq python (cond ((file-name-absolute-p python) python)
                       ((file-executable-p python) (expand-file-name python))
                       (t (or (executable-find python) python))))
    (unless (file-executable-p python)
      (error "Decisions Python is unavailable: %s. Run M-x decisions-bootstrap" python))
    python))

(defun decisions--worker-file ()
  "Returns the absolute Python worker path."
  (expand-file-name "worker.py" decisions--directory))

(defun decisions--default-jev-key ()
  "Returns the configured TypeSafe secret, or nil when none exists."
  (or (getenv "TYPESAFE_API_KEY")
      (when-let* ((entry (car (auth-source-search :host "api.typesafe.ai"
                                                  :max 1 :require '(:secret))))
                  (secret (plist-get entry :secret)))
        (if (functionp secret) (funcall secret) secret))))

(defun decisions--json-copy (object)
  "Returns a detached JSON copy of OBJECT; raises for invalid JSON values."
  (json-parse-string (json-serialize object :null-object :null :false-object :false)
                     :object-type 'hash-table :array-type 'array
                     :null-object :null :false-object :false))

(defun decisions--object (&rest pairs)
  "Returns a JSON object from alternating key/value PAIRS."
  (let ((object (make-hash-table :test #'equal)))
    (while pairs (puthash (pop pairs) (pop pairs) object))
    object))

(defun decisions--now () (format-time-string "%Y-%m-%dT%H:%M:%S%z"))
  "Returns the current local timestamp with its UTC offset."

(defun decisions--snapshot (job)
  "Returns a detached JSON snapshot of JOB."
  (let* ((request (decisions--job-request job))
         (snapshot (decisions--object
                    "id" (decisions--job-id job)
                    "status" (decisions--job-status job)
                    "request" (decisions--json-copy request)
                    "result" (if (decisions--job-result job)
                                 (decisions--json-copy (decisions--job-result job)) :null)
                    "error" (if (decisions--job-error job)
                                (decisions--json-copy (decisions--job-error job)) :null)
                    "created_at" (decisions--job-created-at job)
                    "finished_at" (or (decisions--job-finished-at job) :null)
                    "backend" (gethash "backend" request)
                    "model" (gethash "model" request))))
    snapshot))

(defun decisions--lookup (id owner)
  "Returns ID for OWNER; raises when the job is absent or inaccessible."
  (let ((job (gethash id decisions--jobs)))
    (unless (and job (equal owner (decisions--job-owner job)))
      (error "Unknown Decisions job: %s" id))
    job))

(defun decisions-result (id &optional owner)
  "Return a JSON-compatible snapshot of ID, accessible to OWNER."
  (decisions--snapshot (decisions--lookup id owner)))

(defun decisions--callback-later (job)
  "Schedules JOB's completion callback once with a detached snapshot."
  (when (and (decisions--job-callback job) (not (decisions--job-callback-sent job)))
    (setf (decisions--job-callback-sent job) t)
    (let ((callback (decisions--job-callback job)) (snapshot (decisions--snapshot job)))
      (run-at-time 0 nil
                   (lambda ()
                     (condition-case err (funcall callback snapshot)
                       (error (message "Decisions callback: %s" (error-message-string err)))))))))

(defun decisions--prune ()
  "Removes completed jobs beyond the configured retention limit."
  (while (> (length decisions--completed) (max 0 decisions-retained-jobs))
    (remhash (car decisions--completed) decisions--jobs)
    (setq decisions--completed (cdr decisions--completed))))

(defun decisions--finish (job status &optional result error-object)
  "Records JOB's terminal STATUS with RESULT or ERROR-OBJECT once."
  (unless (member (decisions--job-status job) '("succeeded" "failed" "cancelled"))
    ;; A cancelled active job still holds a worker request slot.
    (unless (and (equal status "cancelled") (memq job decisions--active))
      (decisions--clear-job-timer job))
    (setf (decisions--job-status job) status
          (decisions--job-result job) result
          (decisions--job-error job) error-object
          (decisions--job-finished-at job) (decisions--now))
    (setq decisions--completed (append decisions--completed (list (decisions--job-id job))))
    (decisions--callback-later job)
    (decisions--prune)))

(defun decisions--clear-job-timer (job)
  "Cancels JOB's deadline and clears its timer."
  (when (decisions--job-timer job) (cancel-timer (decisions--job-timer job)))
  (setf (decisions--job-timer job) nil))

(defun decisions--error (code message &optional details)
  "Returns a JSON error with CODE, MESSAGE, and optional DETAILS."
  (let ((value (decisions--object "code" code "message" message)))
    (when details (puthash "details" details value)) value))

(defun decisions--write (object)
  "Sends OBJECT as one JSON line; raises when the worker is unavailable."
  (unless (process-live-p decisions--process) (error "Decisions worker is not running"))
  (process-send-string decisions--process
                       (concat (json-serialize object :null-object :null
                                               :false-object :false) "\n")))

(defun decisions--cancel-idle ()
  "Cancels and clears the worker's idle timer."
  (when decisions--idle-timer (cancel-timer decisions--idle-timer) (setq decisions--idle-timer nil)))

(defun decisions--schedule-idle ()
  "Schedules idle shutdown for an unused worker when enabled."
  (decisions--cancel-idle)
  (when (and decisions-idle-seconds (null decisions--active) (null decisions--queue)
             (process-live-p decisions--process))
    (setq decisions--idle-timer
          (run-at-time decisions-idle-seconds nil
                       (lambda () (when (and (null decisions--active) (null decisions--queue))
                                    (decisions-stop)))))))

(defun decisions--dispatch-next ()
  "Sends queued jobs to a ready worker while it has capacity and records dispatch errors.
Jev jobs share the worker up to `decisions-jev-concurrency'; any other job runs alone."
  (while (and decisions--ready decisions--queue (decisions--can-dispatch-p (car decisions--queue)))
    (decisions--cancel-idle)
    (let ((job (pop decisions--queue))
          (settled nil))
      (push job decisions--active)
      (unwind-protect
       (condition-case err
          (progn
            (when (decisions--jev-job-p job)
              (let ((key (funcall decisions-jev-key-function)))
                (unless (and (stringp key) (not (string-empty-p key)))
                  (error "No TypeSafe API key configured"))
                (decisions--write (decisions--object "op" "configure" "jev_api_key" key))))
            (setf (decisions--job-status job) "running")
            (let ((wire (decisions--json-copy (decisions--job-request job))))
              (puthash "id" (decisions--job-id job) wire)
              (puthash "op" (or (decisions--job-op job) "evaluate") wire)
              (decisions--write wire))
            (setf (decisions--job-timer job)
                  (run-at-time decisions-request-timeout nil #'decisions--timeout
                               (decisions--job-id job)))
            (setq settled t))
        (error
         (setq decisions--active (delq job decisions--active)
               settled t)
         (decisions--finish job "failed" nil
                       (decisions--error "dispatch" (error-message-string err)))))
       ;; A quit, such as C-g at a key prompt, returns the job to the queue's head.
       (unless settled
         (setq decisions--active (delq job decisions--active))
         (setf (decisions--job-status job) "queued")
         (push job decisions--queue))))))

(defun decisions--can-dispatch-p (job)
  "Returns non-nil when JOB may start alongside the active jobs."
  (if (decisions--jev-job-p job)
      (and (seq-every-p #'decisions--jev-job-p decisions--active)
           (< (length decisions--active) (max 1 decisions-jev-concurrency)))
    (null decisions--active)))

(defun decisions--jev-job-p (job)
  "Returns non-nil when JOB evaluates on the Jev backend."
  (and (null (decisions--job-op job))
       (equal (gethash "backend" (decisions--job-request job)) "jev")))

(defun decisions--timeout (id)
  "Fails active ID and stops its worker when its deadline expires."
  (when-let* ((job (decisions--active-job id)))
    (decisions--finish job "failed" nil
                  (decisions--error "timeout" "Decisions worker request timed out"))
    (decisions--worker-failed "Decisions worker stopped after a timeout")))

(defun decisions--active-job (id)
  "Returns the active job with ID, or nil."
  (seq-find (lambda (job) (equal id (decisions--job-id job))) decisions--active))

(defun decisions--handle-line (line)
  "Handles one JSON LINE; fails the worker on invalid protocol replies."
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
            (error "Unsupported Decisions worker protocol"))
          (setq decisions--ready t)
          (when decisions--startup-timer
            (cancel-timer decisions--startup-timer) (setq decisions--startup-timer nil))
          (decisions--dispatch-next)
          (decisions--schedule-idle))
         ((decisions--active-job id)
          (let* ((job (decisions--active-job id))
                 (ok (gethash "ok" message))
                 (result (gethash "result" message))
                 (failure (gethash "error" message)))
            (cond
             ((eq ok t)
              (unless (and (hash-table-p result)
                           (or (not (equal (decisions--job-op job) nil))
                               (hash-table-p (gethash "answers" result))))
                (error "Worker success is missing a result or answers")))
             ((eq ok :false)
              (unless (and (hash-table-p failure)
                           (stringp (gethash "code" failure))
                           (stringp (gethash "message" failure)))
                (error "Worker failure is missing error details")))
             (t (error "Worker reply has no valid ok field")))
            (decisions--clear-job-timer job)
            (setq decisions--active (delq job decisions--active))
            (if (eq ok t)
                (decisions--finish job "succeeded" result)
              (decisions--finish job "failed" nil failure))
            (decisions--dispatch-next)
            (decisions--schedule-idle)))
         ((or id (gethash "ok" message))
          (error "Worker reply has an unexpected request id"))))
    (error (decisions--worker-failed (format "Invalid worker response: %s"
                                        (error-message-string err))))))

(defun decisions--filter (process chunk)
  "Frames PROCESS output CHUNK and rejects oversized JSON lines."
  (when (eq process decisions--process)
    (setq decisions--partial (concat decisions--partial chunk))
    (let (position)
      (while (and (eq process decisions--process)
                  (setq position (string-match "\n" decisions--partial)))
        (let ((line (substring decisions--partial 0 position)))
          (setq decisions--partial (substring decisions--partial (1+ position)))
          (when (> (string-bytes line) decisions-max-request-bytes)
            (decisions--worker-failed "Worker output line exceeded size limit"))
          (when (and (eq process decisions--process) (not (string-empty-p line)))
            (decisions--handle-line line)))))
    (when (> (string-bytes decisions--partial) decisions-max-request-bytes)
      (decisions--worker-failed "Worker output line exceeded size limit"))))

(defun decisions--worker-failed (message)
  "Stops the worker and fails outstanding jobs with MESSAGE."
  (when decisions--startup-timer
    (cancel-timer decisions--startup-timer) (setq decisions--startup-timer nil))
  (decisions--cancel-idle)
  (let ((process decisions--process))
    (setq decisions--process nil decisions--ready nil decisions--partial "")
    (when (process-live-p process) (delete-process process)))
  (when (process-live-p decisions--stderr-process)
    (delete-process decisions--stderr-process))
  (setq decisions--stderr-process nil)
  (dolist (job decisions--active)
    (decisions--clear-job-timer job)
    (decisions--finish job "failed" nil (decisions--error "worker" message)))
  (setq decisions--active nil)
  (dolist (job decisions--queue)
    (decisions--finish job "failed" nil (decisions--error "worker" message)))
  (setq decisions--queue nil))

(defun decisions--sentinel (process _event)
  "Fails jobs when PROCESS exits; ignores its event text."
  (when (and (eq process decisions--process) (not (process-live-p process)))
    (decisions--worker-failed "Decisions worker exited")))

(defun decisions--stderr-filter (process chunk)
  "Appends PROCESS diagnostic CHUNK within the configured size limit."
  (when-let* (((eq process decisions--stderr-process))
              (buffer (get-buffer-create decisions--stderr-buffer)))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert chunk)
      (when (> (buffer-size) decisions-diagnostic-limit)
        (delete-region (point-min) (- (point-max) decisions-diagnostic-limit))))))

(defun decisions-start ()
  "Start the worker process without loading a model."
  (interactive)
  (unless (process-live-p decisions--process)
    (let ((worker (decisions--worker-file))
          (python (decisions--python)))
      (unless (file-readable-p worker) (error "Decisions worker missing: %s" worker))
      (let ((process-environment (copy-sequence process-environment)))
        (setenv "PYTHONDONTWRITEBYTECODE" "1")
        (setenv "HF_HOME" (expand-file-name "etc/decisions/huggingface" user-emacs-directory))
        (setq decisions--partial "" decisions--ready nil)
        (setq decisions--stderr-process
              (make-pipe-process :name "decisions-worker-stderr" :noquery t
                                 :buffer nil :filter #'decisions--stderr-filter))
        (setq decisions--process
              (make-process :name "decisions-worker" :command (list python worker)
                            :connection-type 'pipe :coding 'utf-8-unix :noquery t
                            :buffer nil :stderr decisions--stderr-process
                            :filter #'decisions--filter :sentinel #'decisions--sentinel))
        (setq decisions--startup-timer
              (run-at-time decisions-start-timeout nil
                           (lambda () (unless decisions--ready
                                        (decisions--worker-failed "Decisions worker startup timed out"))))))))
  (decisions-status))

(defun decisions-status ()
  "Return process and queue status; interactively display a summary."
  (interactive)
  (let ((status (decisions--object "process" (if (process-live-p decisions--process)
                                            (if decisions--ready "ready" "starting") "stopped")
                              "queued" (length decisions--queue)
                              "active" (vconcat (mapcar #'decisions--job-id (reverse decisions--active))))))
    (when (called-interactively-p 'interactive)
      (message "Decisions: %s, %s queued" (gethash "process" status)
               (gethash "queued" status)))
    status))

(defun decisions-stop ()
  "Stop the worker and fail outstanding jobs."
  (interactive)
  (decisions--worker-failed "Decisions worker stopped")
  (decisions-status))

(add-hook 'kill-emacs-hook #'decisions-stop)

(defun decisions-restart ()
  "Restart the worker without preloading a model."
  (interactive)
  (decisions-stop)
  (decisions-start))

(defun decisions-warm (&optional backend model)
  "Queues local BACKEND's MODEL and returns its job ID.
Raises for remote backends or a full queue.  May download model weights."
  (interactive)
  (let ((backend (or backend decisions-default-backend)))
    (unless (member backend '("mlx" "laya")) (error "Cannot warm remote backend: %s" backend))
    (let* ((id (format "decisions-%d-%d" (time-convert nil 'integer)
                       (cl-incf decisions--serial)))
           (request (decisions--object "backend" backend
                                  "model" (or model (if (equal backend "laya")
                                                        decisions-laya-model
                                                      decisions-mlx-model))))
           (job (decisions--make-job :id id :op "warm" :request request
                                  :status "queued" :created-at (decisions--now))))
      (when (>= (+ (length decisions--queue) (length decisions--active)) decisions-max-queue)
        (error "Decisions queue is full"))
      (puthash id job decisions--jobs)
      (setq decisions--queue (append decisions--queue (list job)))
      (condition-case err (decisions-start)
        (error (decisions--worker-failed (error-message-string err))))
      (decisions--dispatch-next)
      id)))

(defun decisions--model (backend)
  "Returns the configured model for BACKEND.
Signals an error for an unknown BACKEND."
  (pcase backend
    ("mlx" decisions-mlx-model)
    ("laya" decisions-laya-model)
    ("jev" decisions-jev-model)
    (_ (error "Unknown Decisions backend: %s" backend))))

(cl-defun decisions-submit (state questions &key backend model revision
                            allow-truncation callback owner)
  "Queue typed QUESTIONS over STATE and return a job id.
CALLBACK receives one completed snapshot on a later timer tick.  OWNER must
match exactly on subsequent result and cancellation calls."
  (let* ((backend (cond ((null backend) decisions-default-backend)
                        ((symbolp backend) (symbol-name backend))
                        (t backend)))
         (model (or model (decisions--model backend)))
         (request (decisions--object "state" state "questions" questions
                                "backend" backend "model" model
                                "allow_truncation" (if allow-truncation t :false)))
         (id (format "decisions-%d-%d" (time-convert nil 'integer)
                     (cl-incf decisions--serial))))
    (unless (member backend '("mlx" "laya" "jev")) (error "Unknown Decisions backend: %s" backend))
    (unless (and (stringp model) (not (string-empty-p model))) (error "Invalid Decisions model: %S" model))
    (unless (hash-table-p questions) (error "Questions must be a JSON object/hash table"))
    (when revision (puthash "revision" revision request))
    (setq request (decisions--json-copy request))
    (when (> (string-bytes (json-serialize request :null-object :null :false-object :false))
             decisions-max-request-bytes)
      (error "Decisions request exceeds size limit"))
    (when (>= (+ (length decisions--queue) (length decisions--active)) decisions-max-queue)
      (error "Decisions queue is full"))
    (let ((job (decisions--make-job :id id :owner owner :request request
                                :callback callback :status "queued"
                                :created-at (decisions--now))))
      (puthash id job decisions--jobs)
      (setq decisions--queue (append decisions--queue (list job)))
      (condition-case err (decisions-start)
        (error (decisions--worker-failed (error-message-string err))))
      (decisions--dispatch-next)
      id)))

(defun decisions-cancel (id &optional owner)
  "Cancel ID if queued; discard a running job's eventual result."
  (let ((job (decisions--lookup id owner)))
    (cond
     ((equal (decisions--job-status job) "queued")
      (setq decisions--queue (delq job decisions--queue))
      (decisions--finish job "cancelled")
      (decisions--schedule-idle))
     ((equal (decisions--job-status job) "running")
      (decisions--finish job "cancelled")))
    (decisions--snapshot job)))

(provide 'decisions)
;;; decisions.el ends here
