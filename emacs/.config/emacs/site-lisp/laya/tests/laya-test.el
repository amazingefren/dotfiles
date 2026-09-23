;;; laya-test.el --- Tests for laya.el  -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(add-to-list 'load-path (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))
(require 'laya)

(defmacro laya-test--isolated (&rest body)
  `(let ((laya--jobs (make-hash-table :test #'equal))
         (laya--completed nil) (laya--queue nil) (laya--active nil)
         (laya--process nil) (laya--ready nil) (laya--partial "")
         (laya--serial 0) (laya--startup-timer nil) (laya--idle-timer nil))
     ,@body))

(defun laya-test--question ()
  (let ((questions (make-hash-table :test #'equal)))
    (puthash "yes" (laya--object "type" "noul" "instructions" "Yes?") questions)
    questions))

(ert-deftest laya-test-require-is-lazy ()
  (laya-test--isolated
   (should-not laya--process)
   (should-not laya--ready)))

(ert-deftest laya-test-json-framing ()
  (laya-test--isolated
   (let ((seen nil))
     (cl-letf (((symbol-function 'laya--dispatch-next)
                (lambda () (push 'dispatch seen)))
               ((symbol-function 'laya--schedule-idle) #'ignore))
       (laya--filter nil "{\"event\":\"rea")
       (should-not laya--ready)
       (laya--filter nil "dy\",\"protocol\":1}\n{\"event\":\"ready\",\"protocol\":1}\n")
       (should laya--ready)
       (should (= (length seen) 2))
       (should (equal laya--partial ""))))))

(ert-deftest laya-test-queue-cancel-and-owners ()
  (laya-test--isolated
   (let ((callbacks nil) (owner '("/tmp/project" "session" "pane" "agent")))
     (cl-letf (((symbol-function 'laya-start) (lambda () nil))
               ((symbol-function 'laya--dispatch-next) #'ignore))
       (let* ((id (laya-submit "state" (laya-test--question)
                               :owner owner :callback (lambda (snapshot)
                                                        (push snapshot callbacks))))
              (job (gethash id laya--jobs)))
         (should (equal (gethash "status" (laya-result id owner)) "queued"))
         (should-error (laya-result id))
         (should-error (laya-cancel id '("other")))
         (should (equal (gethash "status" (laya-cancel id owner)) "cancelled"))
         (should-not laya--queue)
         (should (laya--job-callback-sent job))
         (laya--finish job "failed")
         (should (equal (laya--job-status job) "cancelled"))
         (should-not callbacks))))))

(ert-deftest laya-test-running-cancel-discards-response ()
  (laya-test--isolated
   (let ((callback-count 0))
     (cl-letf (((symbol-function 'laya-start) (lambda () nil))
               ((symbol-function 'laya--dispatch-next) #'ignore))
       (let* ((id (laya-submit "state" (laya-test--question)
                               :callback (lambda (_) (cl-incf callback-count))))
              (job (gethash id laya--jobs)))
         (setq laya--queue nil laya--active job)
         (setf (laya--job-status job) "running")
         (laya-cancel id)
         (cl-letf (((symbol-function 'laya--dispatch-next) #'ignore)
                   ((symbol-function 'laya--schedule-idle) #'ignore))
           (laya--handle-line (format "{\"id\":\"%s\",\"ok\":true,\"result\":{\"answers\":{}}}" id)))
         (should-not laya--active)
         (should (equal (gethash "status" (laya-result id)) "cancelled"))
         (should-not (laya--job-result job))
         (should (= callback-count 0)))))))

(ert-deftest laya-test-false-null-and-replay-request ()
  (laya-test--isolated
   (cl-letf (((symbol-function 'laya-start) (lambda () nil))
             ((symbol-function 'laya--dispatch-next) #'ignore))
     (let* ((state (laya--object "false" :false "null" :null "items" []))
            (id (laya-submit state (laya-test--question)))
            (request (gethash "request" (laya-result id)))
            (replay-state (gethash "state" request)))
       (should (eq (gethash "result" (laya-result id)) :null))
       (should (eq (gethash "error" (laya-result id)) :null))
       (should (string-match-p "\"result\":null"
                               (json-serialize (laya-result id) :null-object :null
                                               :false-object :false)))
       (should (eq (gethash "false" replay-state) :false))
       (should (eq (gethash "null" replay-state) :null))
       (should (equal (gethash "items" replay-state) []))
       (should (eq (gethash "allow_truncation" request) :false))
       (should-not (gethash "id" request))
       (should-not (gethash "op" request))))))

(ert-deftest laya-test-worker-death-and-timeout ()
  (laya-test--isolated
   (let* ((first (laya--make-job :id "one" :status "running"
                                  :request (laya--object "backend" "mlx" "model" "m")
                                  :created-at (laya--now)))
          (second (laya--make-job :id "two" :status "queued"
                                   :request (laya--object "backend" "mlx" "model" "m")
                                   :created-at (laya--now))))
     (puthash "one" first laya--jobs)
     (puthash "two" second laya--jobs)
     (setq laya--active first laya--queue (list second))
     (laya--timeout "one")
     (should (equal (laya--job-status first) "failed"))
     (should (equal (gethash "code" (laya--job-error first)) "timeout"))
     (should (equal (laya--job-status second) "failed"))
     (should-not laya--active)
     (should-not laya--queue))))

(ert-deftest laya-test-warm-joins-queue ()
  (laya-test--isolated
   (cl-letf (((symbol-function 'laya-start) (lambda () nil))
             ((symbol-function 'laya--dispatch-next) #'ignore))
     (let ((id (laya-warm)))
       (should (equal (laya--job-op (gethash id laya--jobs)) "warm"))
       (should (equal (laya--job-status (car laya--queue)) "queued"))))))

(ert-deftest laya-test-stderr-is-bounded ()
  (let ((laya-diagnostic-limit 5)
        (laya--stderr-buffer " *laya-test-stderr*"))
    (unwind-protect
        (progn
          (laya--stderr-filter nil "abcdef")
          (should (equal (with-current-buffer laya--stderr-buffer (buffer-string))
                         "bcdef")))
      (kill-buffer laya--stderr-buffer))))

(ert-deftest laya-test-callback-is-delivered-once-later ()
  (laya-test--isolated
   (let* ((count 0)
          (job (laya--make-job :id "once" :status "queued"
                                 :request (laya--object "backend" "mlx" "model" "m")
                                 :created-at (laya--now)
                                 :callback (lambda (_) (cl-incf count)))))
     (puthash "once" job laya--jobs)
     (laya--finish job "cancelled")
     (laya--finish job "failed")
     (should (= count 0))
     (sleep-for 0.01)
     (should (= count 1)))))

(ert-deftest laya-test-cancelled-active-keeps-deadline-and-unblocks-on-timeout ()
  (laya-test--isolated
   (let* ((count 0)
          (first (laya--make-job :id "running" :status "running"
                                   :request (laya--object "backend" "mlx" "model" "m")
                                   :created-at (laya--now)
                                   :callback (lambda (_) (cl-incf count))))
          (second (laya--make-job :id "waiting" :status "queued"
                                    :request (laya--object "backend" "mlx" "model" "m")
                                    :created-at (laya--now))))
     (puthash "running" first laya--jobs)
     (puthash "waiting" second laya--jobs)
     (setq laya--active first laya--queue (list second))
     (setf (laya--job-timer first) (run-at-time 60 nil #'ignore))
     (laya-cancel "running")
     (should (laya--job-timer first))
     (laya--timeout "running")
     (should (equal (laya--job-status first) "cancelled"))
     (should (equal (laya--job-status second) "failed"))
     (should-not (laya--job-timer first))
     (should-not laya--active)
     (sleep-for 0.01)
     (should (= count 1)))))

(ert-deftest laya-test-stale-process-and-oversized-line ()
  (laya-test--isolated
   (setq laya--process 'new)
   (laya--filter 'old "{\"event\":\"ready\",\"protocol\":1}\n")
   (should-not laya--ready)
   (should (equal laya--partial ""))
   (let ((laya-max-request-bytes 8))
     (laya--filter 'new "123456789\n")
     (should-not laya--process))))

(ert-deftest laya-test-malformed-success-fails-worker ()
  (laya-test--isolated
   (let ((job (laya--make-job :id "bad" :status "running"
                               :request (laya--object "backend" "mlx" "model" "m")
                               :created-at (laya--now))))
     (puthash "bad" job laya--jobs)
     (setq laya--active job)
     (laya--handle-line "{\"id\":\"bad\",\"ok\":true,\"result\":{}}")
     (should (equal (laya--job-status job) "failed"))
     (should-not laya--active))))

(ert-deftest laya-test-worker-location-is-load-time-constant ()
  (let ((load-file-name "/tmp/unrelated.el"))
    (should (equal (laya--worker-file)
                   (expand-file-name "worker.py" laya--directory)))))

(ert-deftest laya-test-missing-venv-offers-bootstrap ()
  (let ((user-emacs-directory (make-temp-file "laya-no-venv" t))
        (laya-python nil))
    (unwind-protect
        (should-error (laya--python) :type 'error)
      (delete-directory user-emacs-directory))))

(ert-deftest laya-test-mcp-submit-returns-job-id ()
  (laya-test--isolated
   (require 'laya-mcp)
   (load (expand-file-name "../../lisp/mcp.el" laya--directory) nil t)
   (cl-letf (((symbol-function 'laya-start) (lambda () nil))
             ((symbol-function 'laya--dispatch-next) #'ignore))
     (let* ((arguments (laya--object
                        "state" "A question?" "questions" (laya-test--question)
                        "__emacs_mcp_workspace_root" default-directory
                        "__emacs_mcp_herdr_session" "s"
                        "__emacs_mcp_pane" "p"
                        "__emacs_mcp_agent_name" "a"))
            (encoded (base64-encode-string (json-serialize arguments) t))
            (submitted (json-parse-string (emacs-mcp-dispatch "laya_submit" encoded))))
       (should (stringp (gethash "id" submitted)))
       (should (equal (gethash "status" submitted) "queued"))))))

(provide 'laya-test)
;;; laya-test.el ends here
