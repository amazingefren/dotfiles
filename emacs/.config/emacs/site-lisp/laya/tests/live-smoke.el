;;; live-smoke.el --- Opt-in real local inference check -*- lexical-binding: t -*-

;; Run only after bootstrap.  Uses MLX, never Jev.  Does not load the user's init
;; or connect to a running Emacs instance.  May download the default checkpoint
;; if it is absent from the configured cache.
(require 'cl-lib)
(require 'json)
(let* ((package (expand-file-name ".." (file-name-directory load-file-name)))
       (emacs-dir (file-name-as-directory (expand-file-name "../.." package))))
  (setq user-emacs-directory emacs-dir)
  (add-to-list 'load-path package)
  (require 'laya)
  (require 'laya-mcp)
  (require 'laya-playground)
  (load (expand-file-name "lisp/mcp.el" emacs-dir) nil t))

(defun laya-live--wait (id &optional owner)
  (let ((deadline (+ (float-time) 300)) snapshot)
    (while (and (< (float-time) deadline)
                (member (gethash "status" (setq snapshot (laya-result id owner)))
                        '("queued" "running")))
      (accept-process-output nil 0.05))
    (unless (equal (gethash "status" snapshot) "succeeded")
      (error "Local inference failed: %S" snapshot))
    snapshot))

(unwind-protect
    (let* ((state "Could you explain this error? I need help understanding it.")
           (questions
            (json-parse-string
             "{\"intent\":{\"type\":\"choice\",\"instructions\":\"What is requested?\",\"criteria\":{\"explanation\":\"Explain something\",\"change\":\"Change something\"}},\"question\":{\"type\":\"noul\",\"instructions\":\"Does the text ask a question?\"},\"urgency\":{\"type\":\"score\",\"instructions\":\"How urgent is the request?\",\"criteria\":[\"No deadline\",\"Soon\",\"Immediately\"]}}"))
           (first (laya-live--wait (laya-submit state questions)))
           (second (laya-live--wait (laya-submit state questions)))
           (result (gethash "result" second))
           (answers (gethash "answers" result)))
      (cl-assert (equal (gethash "backend" result) "mlx"))
      (cl-assert (equal (gethash "type" (gethash "intent" answers)) "choice"))
      (cl-assert (numberp (gethash "noul" (gethash "question" answers))))
      (cl-assert (numberp (gethash "score" (gethash "urgency" answers))))
      (cl-assert (hash-table-p (gethash "context" result)))
      (princ (format "Local MLX: cold %.2f ms, warm %.2f ms, checkpoint %s, revision %s\n"
                     (gethash "timing_ms" (gethash "result" first))
                     (gethash "timing_ms" result) (gethash "checkpoint" result)
                     (gethash "revision" result)))
      ;; Exercise the exact Emacs side of the MCP wire with injected identity.
      (let* ((arguments
              (laya--object "state" state "questions" questions
                            "__emacs_mcp_workspace_root" user-emacs-directory
                            "__emacs_mcp_herdr_session" "laya-smoke"
                            "__emacs_mcp_pane" "smoke-pane"
                            "__emacs_mcp_agent_name" "smoke-agent"))
             (encoded (base64-encode-string
                       (encode-coding-string (json-serialize arguments) 'utf-8) t))
             (submitted (json-parse-string (emacs-mcp-dispatch "laya_submit" encoded)))
             (id (gethash "id" submitted))
             (owner (laya-mcp--owner arguments)))
        (cl-assert id)
        (laya-live--wait id owner)
        (puthash "id" id arguments)
        (setq encoded (base64-encode-string
                       (encode-coding-string (json-serialize arguments) 'utf-8) t))
        (cl-assert (equal "succeeded"
                          (gethash "status" (json-parse-string
                                             (emacs-mcp-dispatch "laya_result" encoded)))))
        (princ "MCP submit/result: passed\n"))
      ;; Show a real result through the playground and inspect its buffer.
      (with-temp-buffer
        (laya-playground-mode)
        (laya-playground--display (current-buffer) second)
        (with-current-buffer laya-playground--result-buffer
          (goto-char (point-min))
          (search-forward "Run result and runtime metadata\n\n")
          (let ((rendered (json-parse-buffer :null-object :null :false-object :false)))
            (cl-assert (equal (gethash "id" rendered) (gethash "id" second)))
            (cl-assert (equal (json-serialize (gethash "answers" (gethash "result" rendered)))
                              (json-serialize answers))))))
      (princ "Playground result rendering: passed\n"))
  (laya-stop))

;;; live-smoke.el ends here
