;;; laya-ui-test.el --- Tests for LAYA playground and MCP UI -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(add-to-list 'load-path (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))
(require 'laya-playground)
(require 'laya-mcp)

(defmacro laya-ui-test--isolated (&rest body)
  `(let ((laya--jobs (make-hash-table :test #'equal))
         (laya--completed nil) (laya--queue nil) (laya--active nil)
         (laya--process nil) (laya--ready nil) (laya--partial "")
         (laya--serial 0) (laya--startup-timer nil) (laya--idle-timer nil)
         (laya-ui-test--executed nil))
     ,@body))

(defun laya-ui-test--object (&rest pairs)
  (let ((object (make-hash-table :test #'equal)))
    (while pairs (puthash (pop pairs) (pop pairs) object))
    object))

(defun laya-ui-test--parse (json)
  (json-parse-string json :object-type 'hash-table :array-type 'array
                     :null-object :null :false-object :false))

(defun laya-ui-test--set-request (buffer request)
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (laya-playground--json request) "\n")
      (goto-char (point-min)))))

(defun laya-ui-test--kill-buffers ()
  (dolist (buffer (buffer-list))
    (when (string-match-p "\\`\\*LAYA \\(playground\\|result\\)\\*" (buffer-name buffer))
      (kill-buffer buffer))))

(ert-deftest laya-playground-command-does-not-start-worker ()
  (laya-ui-test--isolated
   (let ((buffer nil))
     (unwind-protect
         (cl-letf (((symbol-function 'laya-start)
                    (lambda () (error "opening the playground must not start a worker"))))
           (setq buffer (call-interactively #'laya-playground))
           (should (buffer-live-p buffer))
           (should-not laya--process)
           (should (hash-table-p (with-current-buffer buffer (laya-playground--read))))
           (should-not laya-playground--job))
       (laya-ui-test--kill-buffers)))))

(ert-deftest laya-playground-forwards-json-values-without-coercion ()
  (laya-ui-test--isolated
   (let* ((request (laya-ui-test--parse
                    "{\"backend\":\"mlx\",\"state\":{\"false\":false,\"null\":null,\"empty_array\":[],\"empty_object\":{}},\"questions\":{\"check\":{\"type\":\"noul\",\"instructions\":\"\"}},\"allow_truncation\":false}"))
          (buffer nil) captured-state captured-questions captured-options)
     (unwind-protect
         (cl-letf (((symbol-function 'laya-submit)
                    (lambda (state questions &rest options)
                      (setq captured-state state
                            captured-questions questions
                            captured-options options)
                      "stub-job"))
                   ((symbol-function 'laya-start)
                    (lambda () (error "stubbed submission must not start a worker"))))
           (setq buffer (laya-playground--new request))
           (with-current-buffer buffer (laya-playground-run))
           (should (eq (gethash "false" captured-state) :false))
           (should (eq (gethash "null" captured-state) :null))
           (should (equal (gethash "empty_array" captured-state) []))
           (should (hash-table-p (gethash "empty_object" captured-state)))
           (should (equal (gethash "instructions" (gethash "check" captured-questions)) ""))
           (should (eq (plist-get captured-options :allow-truncation) nil))
           (should-not laya--process))
       (laya-ui-test--kill-buffers)))))

(ert-deftest laya-playground-rejects-invalid-optional-values-helpfully ()
  (laya-ui-test--isolated
   (let ((bad-requests
          '("{\"state\":\"x\",\"questions\":{},\"backend\":null}"
            "{\"state\":\"x\",\"questions\":{},\"backend\":4}"
            "{\"state\":\"x\",\"questions\":{},\"model\":null}"
            "{\"state\":\"x\",\"questions\":{},\"revision\":null}"
            "{\"state\":\"x\",\"questions\":{},\"allow_truncation\":\"false\"}"
            "{\"state\":\"x\",\"questions\":{},\"allow_truncation\":null}")))
     (dolist (json bad-requests)
       (let ((buffer (laya-playground--new (laya-ui-test--parse json))))
         (unwind-protect
             (cl-letf (((symbol-function 'laya-submit)
                        (lambda (&rest _) (error "invalid input reached laya-submit"))))
               (with-current-buffer buffer
                 (should-error (laya-playground-run) :type 'user-error)))
           (when (buffer-live-p buffer) (kill-buffer buffer))))))))

(ert-deftest laya-playground-expired-job-does-not-block-a-new-run ()
  (laya-ui-test--isolated
   (let ((buffer nil) (submitted 0))
     (unwind-protect
         (cl-letf (((symbol-function 'laya-result)
                    (lambda (&rest _) (error "Unknown Laya job")))
                   ((symbol-function 'laya-submit)
                    (lambda (&rest _) (cl-incf submitted) "fresh-job")))
           (setq buffer (laya-playground--new
                         (laya-ui-test--parse "{\"state\":\"x\",\"questions\":{}}")))
           (with-current-buffer buffer
             (setq laya-playground--job "pruned-job")
             (laya-playground-run))
           (should (= submitted 1))
           (should (equal (buffer-local-value 'laya-playground--job buffer) "fresh-job")))
       (laya-ui-test--kill-buffers)))))

(ert-deftest laya-playground-async-callback-cannot-replace-newer-run ()
  (laya-ui-test--isolated
   (let ((buffer nil) (callbacks (make-hash-table :test #'equal)) (serial 0))
     (unwind-protect
         (cl-letf (((symbol-function 'laya-submit)
                    (lambda (_state _questions &rest options)
                      (let ((id (format "job-%d" (cl-incf serial))))
                        (puthash id (plist-get options :callback) callbacks)
                        id)))
                   ((symbol-function 'laya-result)
                    (lambda (&rest _) (laya-ui-test--object "status" "succeeded")))
                   ((symbol-function 'laya-playground--display) #'ignore))
           (setq buffer (laya-playground--new
                         (laya-ui-test--parse "{\"state\":\"first\",\"questions\":{}}")))
           (with-current-buffer buffer
             (laya-playground-run)
             (laya-ui-test--set-request buffer
                                        (laya-ui-test--parse
                                         "{\"state\":\"second\",\"questions\":{}}"))
             (laya-playground-run))
           (funcall (gethash "job-1" callbacks)
                    (laya-ui-test--object "id" "job-1" "status" "succeeded"))
           (should-not (buffer-local-value 'laya-playground--snapshot buffer))
           (funcall (gethash "job-2" callbacks)
                    (laya-ui-test--object "id" "job-2" "status" "succeeded"))
           (should (equal (gethash "id" (buffer-local-value 'laya-playground--snapshot buffer))
                          "job-2")))
       (laya-ui-test--kill-buffers)))))

(ert-deftest laya-playground-saves-and-opens-input-and-prior-run-separately ()
  (laya-ui-test--isolated
   (let* ((original (laya-ui-test--parse
                    "{\"state\":\"original-state\",\"questions\":{\"q\":{\"type\":\"noul\",\"instructions\":\"(setq laya-ui-test--executed t)\"}}}"))
          (edited (laya-ui-test--parse "{\"state\":\"edited-state\",\"questions\":{}}"))
          (snapshot (laya-ui-test--object "id" "completed-1" "status" "succeeded"
                                          "request" original
                                          "result" (laya-ui-test--object "answers" (laya-ui-test--object))))
          (file (make-temp-name (expand-file-name "laya-ui-" temporary-file-directory)))
          (source nil) opened)
     (unwind-protect
         (cl-letf (((symbol-function 'laya-start)
                    (lambda () (error "opening or saving must not start a worker")))
                   ((symbol-function 'laya-submit)
                    (lambda (&rest _) (error "opening or saving must not submit a request"))))
           (setq source (laya-playground--new original))
           (with-current-buffer source
             (setq laya-playground--job "completed-1")
             (laya-playground--completed source snapshot))
           (laya-ui-test--set-request source edited)
           (laya-playground-save-experiment file)
           ;; Replacing an existing file requires confirmation, then overwrites it.
           (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
             (laya-ui-test--set-request
              source (laya-ui-test--parse "{\"state\":\"edited-again\",\"questions\":{}}"))
             (laya-playground-save-experiment file))
           (setq opened (laya-playground-open-experiment file))
           (should (equal (gethash "state" (with-current-buffer opened
                                              (laya-playground--read))) "edited-again"))
           (should (equal (gethash "id" (buffer-local-value 'laya-playground--snapshot opened))
                          "completed-1"))
           (let ((result-buffer (buffer-local-value 'laya-playground--result-buffer opened)))
             (with-current-buffer result-buffer
               (let ((display (buffer-string)))
                 (should (string-match-p "Current editable request" display))
                 (should (string-match-p "Request used for this run" display))
                 (should (string-match-p "edited-again" display))
                 (should (string-match-p "original-state" display)))))
           (should-not laya-ui-test--executed)
           (should-not laya--process))
       (when (file-exists-p file) (delete-file file))
       (laya-ui-test--kill-buffers)))))

(ert-deftest laya-mcp-owner-comes-from-injected-scope-not-public-owner ()
  (laya-ui-test--isolated
   (let* ((root (file-name-as-directory (file-truename temporary-file-directory)))
          (arguments (laya-ui-test--object
                      "state" "state" "questions" (make-hash-table :test #'equal)
                      "owner" '("agent-supplied-owner")
                      "__emacs_mcp_workspace_root" root
                      "__emacs_mcp_herdr_session" "trusted-session"
                      "__emacs_mcp_pane" "trusted-pane"
                      "__emacs_mcp_agent_name" "trusted-agent"))
          (expected (list root "trusted-session" "trusted-pane" "trusted-agent"))
          submitted-owner result-owner)
     (cl-letf (((symbol-function 'laya-submit)
                (lambda (&rest options)
                  (setq submitted-owner (plist-get options :owner))
                  "job-id"))
               ((symbol-function 'laya-result)
                (lambda (_id &optional owner)
                  (setq result-owner owner)
                  (laya-ui-test--object "id" "job-id"))))
       (laya-mcp-dispatch "laya_submit" arguments)
       (should (equal submitted-owner expected))
       (puthash "id" "job-id" arguments)
       (laya-mcp-dispatch "laya_result" arguments)
       (should (equal result-owner expected))
       (should-not laya--process)))))

(ert-deftest laya-mcp-rejects-null-options-and-nonboolean-truncation ()
  (laya-ui-test--isolated
   (let* ((root (file-name-as-directory (file-truename temporary-file-directory)))
          (arguments (laya-ui-test--object
                      "state" "state" "questions" (make-hash-table :test #'equal)
                      "__emacs_mcp_workspace_root" root)))
     (cl-letf (((symbol-function 'laya-submit)
                (lambda (&rest _) (error "invalid public arguments reached laya-submit"))))
       (dolist (pair '(("backend" . :null) ("model" . :null) ("revision" . :null)
                       ("allow_truncation" . "false")))
         (puthash (car pair) (cdr pair) arguments)
         (should-error (laya-mcp-dispatch "laya_submit" arguments) :type 'user-error)
         (remhash (car pair) arguments))))))

(provide 'laya-ui-test)
;;; laya-ui-test.el ends here
