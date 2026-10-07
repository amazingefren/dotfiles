;;; decisions-mcp.el --- Scoped agent access to Decisions -*- lexical-binding: t -*-

(require 'decisions)
(require 'subr-x)

(defun decisions-mcp--owner (arguments)
  "Return the immutable agent scope injected into ARGUMENTS by the bridge.
Public `owner' or workspace fields in ARGUMENTS are ignored."
  (let ((root (gethash "__emacs_mcp_workspace_root" arguments)))
    (unless (and (stringp root) (file-name-absolute-p root) (file-directory-p root))
      (user-error "Decisions requires the agent's launch workspace"))
    (list (file-name-as-directory (file-truename root))
          (gethash "__emacs_mcp_herdr_session" arguments "")
          (gethash "__emacs_mcp_pane" arguments "")
          (gethash "__emacs_mcp_agent_name" arguments ""))))

(defun decisions-mcp--validate-options (arguments)
  "Validate optional backend settings in a public submit ARGUMENTS object."
  (let* ((missing (make-symbol "missing"))
         (backend (gethash "backend" arguments missing)))
    (unless (or (eq backend missing)
                (and (stringp backend) (member backend '("mlx" "laya" "jev"))))
      (user-error "backend must be \"mlx\", \"laya\", or \"jev\"; omit it to use mlx"))
    (dolist (field '("model" "revision"))
      (let ((value (gethash field arguments missing)))
        (unless (or (eq value missing)
                    (and (stringp value) (not (string-empty-p value))))
          (user-error "%s must be a nonempty string; omit it to use the default" field))))
    (let ((value (gethash "allow_truncation" arguments missing)))
      (unless (or (eq value missing) (eq value t) (eq value :false))
        (user-error "allow_truncation must be true or false")))
    (when (and (equal backend "jev")
               (not (eq (gethash "revision" arguments missing) missing)))
      (user-error "revision is only supported by the local MLX backend; use a Jev model ID"))))

;;;###autoload
(defun decisions-mcp-dispatch (method arguments)
  "Handle typed decision METHOD with launch-scoped ARGUMENTS.
Submitting returns a job ID promptly.  Call result later to retrieve answers."
  (let ((owner (decisions-mcp--owner arguments)))
    (pcase method
      ("decisions_submit"
       (let ((missing (make-symbol "missing")))
         (decisions-mcp--validate-options arguments)
         (when (eq (gethash "state" arguments missing) missing)
           (user-error "state is required"))
         (let ((id (decisions-submit
                    (gethash "state" arguments) (gethash "questions" arguments)
                    :backend (gethash "backend" arguments "mlx")
                    :model (gethash "model" arguments)
                    :revision (gethash "revision" arguments)
                    :allow-truncation (eq (gethash "allow_truncation" arguments) t)
                    :owner owner)))
           (decisions-result id owner))))
      ("decisions_result" (decisions-result (gethash "id" arguments) owner))
      ("decisions_cancel" (decisions-cancel (gethash "id" arguments) owner))
      (_ (user-error "Unknown Decisions method")))))

(provide 'decisions-mcp)
;;; decisions-mcp.el ends here
