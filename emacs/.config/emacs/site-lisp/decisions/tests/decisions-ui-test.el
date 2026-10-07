;;; decisions-ui-test.el --- Tests for Decisions playground and MCP UI -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(add-to-list 'load-path (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))
(require 'decisions-playground)
(require 'decisions-mcp)

(defmacro decisions-ui-test--isolated (&rest body)
  `(let ((decisions--jobs (make-hash-table :test #'equal))
         (decisions--completed nil) (decisions--queue nil) (decisions--active nil)
         (decisions--process nil) (decisions--ready nil) (decisions--partial "")
         (decisions--serial 0) (decisions--startup-timer nil) (decisions--idle-timer nil)
         (decisions-ui-test--executed nil))
     ,@body))

(defun decisions-ui-test--object (&rest pairs)
  (let ((object (make-hash-table :test #'equal)))
    (while pairs (puthash (pop pairs) (pop pairs) object))
    object))

(defun decisions-ui-test--parse (json)
  (json-parse-string json :object-type 'hash-table :array-type 'array
                     :null-object :null :false-object :false))

(defun decisions-ui-test--set-request (buffer request)
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (decisions-playground--json request) "\n")
      (goto-char (point-min)))))

(defun decisions-ui-test--kill-buffers ()
  (dolist (buffer (buffer-list))
    (when (string-match-p "\\`\\*Decisions \\(playground\\|result\\)\\*" (buffer-name buffer))
      (kill-buffer buffer))))

(ert-deftest decisions-playground-command-does-not-start-worker ()
  (decisions-ui-test--isolated
   (let ((buffer nil))
     (unwind-protect
         (cl-letf (((symbol-function 'decisions-start)
                    (lambda () (error "opening the playground must not start a worker"))))
           (setq buffer (call-interactively #'decisions-playground))
           (should (buffer-live-p buffer))
           (should-not decisions--process)
           (should (hash-table-p (with-current-buffer buffer (decisions-playground--read))))
           (should-not decisions-playground--job))
       (decisions-ui-test--kill-buffers)))))

(ert-deftest decisions-playground-forwards-json-values-without-coercion ()
  (decisions-ui-test--isolated
   (let* ((request (decisions-ui-test--parse
                    "{\"backend\":\"mlx\",\"state\":{\"false\":false,\"null\":null,\"empty_array\":[],\"empty_object\":{}},\"questions\":{\"check\":{\"type\":\"noul\",\"instructions\":\"\"}},\"allow_truncation\":false}"))
          (buffer nil) captured-state captured-questions captured-options)
     (unwind-protect
         (cl-letf (((symbol-function 'decisions-submit)
                    (lambda (state questions &rest options)
                      (setq captured-state state
                            captured-questions questions
                            captured-options options)
                      "stub-job"))
                   ((symbol-function 'decisions-start)
                    (lambda () (error "stubbed submission must not start a worker"))))
           (setq buffer (decisions-playground--new request))
           (with-current-buffer buffer (decisions-playground-run))
           (should (eq (gethash "false" captured-state) :false))
           (should (eq (gethash "null" captured-state) :null))
           (should (equal (gethash "empty_array" captured-state) []))
           (should (hash-table-p (gethash "empty_object" captured-state)))
           (should (equal (gethash "instructions" (gethash "check" captured-questions)) ""))
           (should (eq (plist-get captured-options :allow-truncation) nil))
           (should-not decisions--process))
       (decisions-ui-test--kill-buffers)))))

(ert-deftest decisions-playground-rejects-invalid-optional-values-helpfully ()
  (decisions-ui-test--isolated
   (let ((bad-requests
          '("{\"state\":\"x\",\"questions\":{},\"backend\":null}"
            "{\"state\":\"x\",\"questions\":{},\"backend\":4}"
            "{\"state\":\"x\",\"questions\":{},\"model\":null}"
            "{\"state\":\"x\",\"questions\":{},\"revision\":null}"
            "{\"state\":\"x\",\"questions\":{},\"allow_truncation\":\"false\"}"
            "{\"state\":\"x\",\"questions\":{},\"allow_truncation\":null}")))
     (dolist (json bad-requests)
       (let ((buffer (decisions-playground--new (decisions-ui-test--parse json))))
         (unwind-protect
             (cl-letf (((symbol-function 'decisions-submit)
                        (lambda (&rest _) (error "invalid input reached decisions-submit"))))
               (with-current-buffer buffer
                 (should-error (decisions-playground-run) :type 'user-error)))
           (when (buffer-live-p buffer) (kill-buffer buffer))))))))

(ert-deftest decisions-playground-expired-job-does-not-block-a-new-run ()
  (decisions-ui-test--isolated
   (let ((buffer nil) (submitted 0))
     (unwind-protect
         (cl-letf (((symbol-function 'decisions-result)
                    (lambda (&rest _) (error "Unknown Decisions job")))
                   ((symbol-function 'decisions-submit)
                    (lambda (&rest _) (cl-incf submitted) "fresh-job")))
           (setq buffer (decisions-playground--new
                         (decisions-ui-test--parse "{\"state\":\"x\",\"questions\":{}}")))
           (with-current-buffer buffer
             (setq decisions-playground--job "pruned-job")
             (decisions-playground-run))
           (should (= submitted 1))
           (should (equal (buffer-local-value 'decisions-playground--job buffer) "fresh-job")))
       (decisions-ui-test--kill-buffers)))))

(ert-deftest decisions-playground-async-callback-cannot-replace-newer-run ()
  (decisions-ui-test--isolated
   (let ((buffer nil) (callbacks (make-hash-table :test #'equal)) (serial 0))
     (unwind-protect
         (cl-letf (((symbol-function 'decisions-submit)
                    (lambda (_state _questions &rest options)
                      (let ((id (format "job-%d" (cl-incf serial))))
                        (puthash id (plist-get options :callback) callbacks)
                        id)))
                   ((symbol-function 'decisions-result)
                    (lambda (&rest _) (decisions-ui-test--object "status" "succeeded")))
                   ((symbol-function 'decisions-playground--display) #'ignore))
           (setq buffer (decisions-playground--new
                         (decisions-ui-test--parse "{\"state\":\"first\",\"questions\":{}}")))
           (with-current-buffer buffer
             (decisions-playground-run)
             (decisions-ui-test--set-request buffer
                                        (decisions-ui-test--parse
                                         "{\"state\":\"second\",\"questions\":{}}"))
             (decisions-playground-run))
           (funcall (gethash "job-1" callbacks)
                    (decisions-ui-test--object "id" "job-1" "status" "succeeded"))
           (should-not (buffer-local-value 'decisions-playground--snapshot buffer))
           (funcall (gethash "job-2" callbacks)
                    (decisions-ui-test--object "id" "job-2" "status" "succeeded"))
           (should (equal (gethash "id" (buffer-local-value 'decisions-playground--snapshot buffer))
                          "job-2")))
       (decisions-ui-test--kill-buffers)))))

(ert-deftest decisions-playground-saves-and-opens-input-and-prior-run-separately ()
  (decisions-ui-test--isolated
   (let* ((original (decisions-ui-test--parse
                    "{\"state\":\"original-state\",\"questions\":{\"q\":{\"type\":\"noul\",\"instructions\":\"(setq decisions-ui-test--executed t)\"}}}"))
          (edited (decisions-ui-test--parse "{\"state\":\"edited-state\",\"questions\":{}}"))
          (snapshot (decisions-ui-test--object "id" "completed-1" "status" "succeeded"
                                          "request" original
                                          "result" (decisions-ui-test--object "answers" (decisions-ui-test--object))))
          (file (make-temp-name (expand-file-name "decisions-ui-" temporary-file-directory)))
          (source nil) opened)
     (unwind-protect
         (cl-letf (((symbol-function 'decisions-start)
                    (lambda () (error "opening or saving must not start a worker")))
                   ((symbol-function 'decisions-submit)
                    (lambda (&rest _) (error "opening or saving must not submit a request"))))
           (setq source (decisions-playground--new original))
           (with-current-buffer source
             (setq decisions-playground--job "completed-1")
             (decisions-playground--completed source snapshot))
           (decisions-ui-test--set-request source edited)
           (decisions-playground-save-experiment file)
           ;; Replacing an existing file requires confirmation, then overwrites it.
           (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
             (decisions-ui-test--set-request
              source (decisions-ui-test--parse "{\"state\":\"edited-again\",\"questions\":{}}"))
             (decisions-playground-save-experiment file))
           (setq opened (decisions-playground-open-experiment file))
           (should (equal (gethash "state" (with-current-buffer opened
                                              (decisions-playground--read))) "edited-again"))
           (should (equal (gethash "id" (buffer-local-value 'decisions-playground--snapshot opened))
                          "completed-1"))
           (let ((result-buffer (buffer-local-value 'decisions-playground--result-buffer opened)))
             (with-current-buffer result-buffer
               (let ((display (buffer-string)))
                 (should (string-match-p "Current editable request" display))
                 (should (string-match-p "Request used for this run" display))
                 (should (string-match-p "edited-again" display))
                 (should (string-match-p "original-state" display)))))
           (should-not decisions-ui-test--executed)
           (should-not decisions--process))
       (when (file-exists-p file) (delete-file file))
       (decisions-ui-test--kill-buffers)))))

(ert-deftest decisions-mcp-owner-comes-from-injected-scope-not-public-owner ()
  (decisions-ui-test--isolated
   (let* ((root (file-name-as-directory (file-truename temporary-file-directory)))
          (arguments (decisions-ui-test--object
                      "state" "state" "questions" (make-hash-table :test #'equal)
                      "owner" '("agent-supplied-owner")
                      "__emacs_mcp_workspace_root" root
                      "__emacs_mcp_herdr_session" "trusted-session"
                      "__emacs_mcp_pane" "trusted-pane"
                      "__emacs_mcp_agent_name" "trusted-agent"))
          (expected (list root "trusted-session" "trusted-pane" "trusted-agent"))
          submitted-owner result-owner)
     (cl-letf (((symbol-function 'decisions-submit)
                (lambda (&rest options)
                  (setq submitted-owner (plist-get options :owner))
                  "job-id"))
               ((symbol-function 'decisions-result)
                (lambda (_id &optional owner)
                  (setq result-owner owner)
                  (decisions-ui-test--object "id" "job-id"))))
       (decisions-mcp-dispatch "decisions_submit" arguments)
       (should (equal submitted-owner expected))
       (puthash "id" "job-id" arguments)
       (decisions-mcp-dispatch "decisions_result" arguments)
       (should (equal result-owner expected))
       (should-not decisions--process)))))

(ert-deftest decisions-mcp-rejects-null-options-and-nonboolean-truncation ()
  (decisions-ui-test--isolated
   (let* ((root (file-name-as-directory (file-truename temporary-file-directory)))
          (arguments (decisions-ui-test--object
                      "state" "state" "questions" (make-hash-table :test #'equal)
                      "__emacs_mcp_workspace_root" root)))
     (cl-letf (((symbol-function 'decisions-submit)
                (lambda (&rest _) (error "invalid public arguments reached decisions-submit"))))
       (dolist (pair '(("backend" . :null) ("model" . :null) ("revision" . :null)
                       ("allow_truncation" . "false")))
         (puthash (car pair) (cdr pair) arguments)
         (should-error (decisions-mcp-dispatch "decisions_submit" arguments) :type 'user-error)
         (remhash (car pair) arguments))))))

(provide 'decisions-ui-test)
;;; decisions-ui-test.el ends here
