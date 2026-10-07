;;; decisions-test.el --- Tests for decisions.el  -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(add-to-list 'load-path (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))
(require 'decisions)

(defmacro decisions-test--isolated (&rest body)
  `(let ((decisions--jobs (make-hash-table :test #'equal))
         (decisions--completed nil) (decisions--queue nil) (decisions--active nil)
         (decisions--process nil) (decisions--ready nil) (decisions--partial "")
         (decisions--serial 0) (decisions--startup-timer nil) (decisions--idle-timer nil))
     ,@body))

(defun decisions-test--question ()
  (let ((questions (make-hash-table :test #'equal)))
    (puthash "yes" (decisions--object "type" "noul" "instructions" "Yes?") questions)
    questions))

(ert-deftest decisions-test-require-is-lazy ()
  (decisions-test--isolated
   (should-not decisions--process)
   (should-not decisions--ready)))

(ert-deftest decisions-test-json-framing ()
  (decisions-test--isolated
   (let ((seen nil))
     (cl-letf (((symbol-function 'decisions--dispatch-next)
                (lambda () (push 'dispatch seen)))
               ((symbol-function 'decisions--schedule-idle) #'ignore))
       (decisions--filter nil "{\"event\":\"rea")
       (should-not decisions--ready)
       (decisions--filter nil "dy\",\"protocol\":1}\n{\"event\":\"ready\",\"protocol\":1}\n")
       (should decisions--ready)
       (should (= (length seen) 2))
       (should (equal decisions--partial ""))))))

(ert-deftest decisions-test-queue-cancel-and-owners ()
  (decisions-test--isolated
   (let ((callbacks nil) (owner '("/tmp/project" "session" "pane" "agent")))
     (cl-letf (((symbol-function 'decisions-start) (lambda () nil))
               ((symbol-function 'decisions--dispatch-next) #'ignore))
       (let* ((id (decisions-submit "state" (decisions-test--question)
                               :owner owner :callback (lambda (snapshot)
                                                        (push snapshot callbacks))))
              (job (gethash id decisions--jobs)))
         (should (equal (gethash "status" (decisions-result id owner)) "queued"))
         (should-error (decisions-result id))
         (should-error (decisions-cancel id '("other")))
         (should (equal (gethash "status" (decisions-cancel id owner)) "cancelled"))
         (should-not decisions--queue)
         (should (decisions--job-callback-sent job))
         (decisions--finish job "failed")
         (should (equal (decisions--job-status job) "cancelled"))
         (should-not callbacks))))))

(ert-deftest decisions-test-running-cancel-discards-response ()
  (decisions-test--isolated
   (let ((callback-count 0))
     (cl-letf (((symbol-function 'decisions-start) (lambda () nil))
               ((symbol-function 'decisions--dispatch-next) #'ignore))
       (let* ((id (decisions-submit "state" (decisions-test--question)
                               :callback (lambda (_) (cl-incf callback-count))))
              (job (gethash id decisions--jobs)))
         (setq decisions--queue nil decisions--active job)
         (setf (decisions--job-status job) "running")
         (decisions-cancel id)
         (cl-letf (((symbol-function 'decisions--dispatch-next) #'ignore)
                   ((symbol-function 'decisions--schedule-idle) #'ignore))
           (decisions--handle-line (format "{\"id\":\"%s\",\"ok\":true,\"result\":{\"answers\":{}}}" id)))
         (should-not decisions--active)
         (should (equal (gethash "status" (decisions-result id)) "cancelled"))
         (should-not (decisions--job-result job))
         (should (= callback-count 0)))))))

(ert-deftest decisions-test-false-null-and-replay-request ()
  (decisions-test--isolated
   (cl-letf (((symbol-function 'decisions-start) (lambda () nil))
             ((symbol-function 'decisions--dispatch-next) #'ignore))
     (let* ((state (decisions--object "false" :false "null" :null "items" []))
            (id (decisions-submit state (decisions-test--question)))
            (request (gethash "request" (decisions-result id)))
            (replay-state (gethash "state" request)))
       (should (eq (gethash "result" (decisions-result id)) :null))
       (should (eq (gethash "error" (decisions-result id)) :null))
       (should (string-match-p "\"result\":null"
                               (json-serialize (decisions-result id) :null-object :null
                                               :false-object :false)))
       (should (eq (gethash "false" replay-state) :false))
       (should (eq (gethash "null" replay-state) :null))
       (should (equal (gethash "items" replay-state) []))
       (should (eq (gethash "allow_truncation" request) :false))
       (should-not (gethash "id" request))
       (should-not (gethash "op" request))))))

(ert-deftest decisions-test-worker-death-and-timeout ()
  (decisions-test--isolated
   (let* ((first (decisions--make-job :id "one" :status "running"
                                  :request (decisions--object "backend" "mlx" "model" "m")
                                  :created-at (decisions--now)))
          (second (decisions--make-job :id "two" :status "queued"
                                   :request (decisions--object "backend" "mlx" "model" "m")
                                   :created-at (decisions--now))))
     (puthash "one" first decisions--jobs)
     (puthash "two" second decisions--jobs)
     (setq decisions--active first decisions--queue (list second))
     (decisions--timeout "one")
     (should (equal (decisions--job-status first) "failed"))
     (should (equal (gethash "code" (decisions--job-error first)) "timeout"))
     (should (equal (decisions--job-status second) "failed"))
     (should-not decisions--active)
     (should-not decisions--queue))))

(ert-deftest decisions-test-warm-joins-queue ()
  (decisions-test--isolated
   (cl-letf (((symbol-function 'decisions-start) (lambda () nil))
             ((symbol-function 'decisions--dispatch-next) #'ignore))
     (let ((id (decisions-warm)))
       (should (equal (decisions--job-op (gethash id decisions--jobs)) "warm"))
       (should (equal (decisions--job-status (car decisions--queue)) "queued"))))))

(ert-deftest decisions-test-stderr-is-bounded ()
  (let ((decisions-diagnostic-limit 5)
        (decisions--stderr-buffer " *decisions-test-stderr*"))
    (unwind-protect
        (progn
          (decisions--stderr-filter nil "abcdef")
          (should (equal (with-current-buffer decisions--stderr-buffer (buffer-string))
                         "bcdef")))
      (kill-buffer decisions--stderr-buffer))))

(ert-deftest decisions-test-callback-is-delivered-once-later ()
  (decisions-test--isolated
   (let* ((count 0)
          (job (decisions--make-job :id "once" :status "queued"
                                 :request (decisions--object "backend" "mlx" "model" "m")
                                 :created-at (decisions--now)
                                 :callback (lambda (_) (cl-incf count)))))
     (puthash "once" job decisions--jobs)
     (decisions--finish job "cancelled")
     (decisions--finish job "failed")
     (should (= count 0))
     (sleep-for 0.01)
     (should (= count 1)))))

(ert-deftest decisions-test-cancelled-active-keeps-deadline-and-unblocks-on-timeout ()
  (decisions-test--isolated
   (let* ((count 0)
          (first (decisions--make-job :id "running" :status "running"
                                   :request (decisions--object "backend" "mlx" "model" "m")
                                   :created-at (decisions--now)
                                   :callback (lambda (_) (cl-incf count))))
          (second (decisions--make-job :id "waiting" :status "queued"
                                    :request (decisions--object "backend" "mlx" "model" "m")
                                    :created-at (decisions--now))))
     (puthash "running" first decisions--jobs)
     (puthash "waiting" second decisions--jobs)
     (setq decisions--active first decisions--queue (list second))
     (setf (decisions--job-timer first) (run-at-time 60 nil #'ignore))
     (decisions-cancel "running")
     (should (decisions--job-timer first))
     (decisions--timeout "running")
     (should (equal (decisions--job-status first) "cancelled"))
     (should (equal (decisions--job-status second) "failed"))
     (should-not (decisions--job-timer first))
     (should-not decisions--active)
     (sleep-for 0.01)
     (should (= count 1)))))

(ert-deftest decisions-test-stale-process-and-oversized-line ()
  (decisions-test--isolated
   (setq decisions--process 'new)
   (decisions--filter 'old "{\"event\":\"ready\",\"protocol\":1}\n")
   (should-not decisions--ready)
   (should (equal decisions--partial ""))
   (let ((decisions-max-request-bytes 8))
     (decisions--filter 'new "123456789\n")
     (should-not decisions--process))))

(ert-deftest decisions-test-malformed-success-fails-worker ()
  (decisions-test--isolated
   (let ((job (decisions--make-job :id "bad" :status "running"
                               :request (decisions--object "backend" "mlx" "model" "m")
                               :created-at (decisions--now))))
     (puthash "bad" job decisions--jobs)
     (setq decisions--active job)
     (decisions--handle-line "{\"id\":\"bad\",\"ok\":true,\"result\":{}}")
     (should (equal (decisions--job-status job) "failed"))
     (should-not decisions--active))))

(ert-deftest decisions-test-worker-location-is-load-time-constant ()
  (let ((load-file-name "/tmp/unrelated.el"))
    (should (equal (decisions--worker-file)
                   (expand-file-name "worker.py" decisions--directory)))))

(ert-deftest decisions-test-missing-venv-offers-bootstrap ()
  (let ((user-emacs-directory (make-temp-file "decisions-no-venv" t))
        (decisions-python nil))
    (unwind-protect
        (should-error (decisions--python) :type 'error)
      (delete-directory user-emacs-directory))))

(ert-deftest decisions-test-mcp-submit-returns-job-id ()
  (decisions-test--isolated
   (require 'decisions-mcp)
   (load (expand-file-name "../../lisp/mcp.el" decisions--directory) nil t)
   (cl-letf (((symbol-function 'decisions-start) (lambda () nil))
             ((symbol-function 'decisions--dispatch-next) #'ignore))
     (let* ((arguments (decisions--object
                        "state" "A question?" "questions" (decisions-test--question)
                        "__emacs_mcp_workspace_root" default-directory
                        "__emacs_mcp_herdr_session" "s"
                        "__emacs_mcp_pane" "p"
                        "__emacs_mcp_agent_name" "a"))
            (encoded (base64-encode-string (json-serialize arguments) t))
            (submitted (json-parse-string (emacs-mcp-dispatch "decisions_submit" encoded))))
       (should (stringp (gethash "id" submitted)))
       (should (equal (gethash "status" submitted) "queued"))))))

(provide 'decisions-test)
;;; decisions-test.el ends here
