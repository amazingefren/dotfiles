;;; laya-mcp.el --- Scoped agent access to LAYA -*- lexical-binding: t -*-

;;; Commentary:
;; Called only by the fixed Emacs MCP dispatcher.  Owner identity is injected
;; by the stdio bridge, never accepted from public tool parameters.

;;; Code:
(require 'laya)
(require 'subr-x)

(defun laya-mcp--owner (arguments)
  "Return the immutable agent scope injected into ARGUMENTS by the bridge.
Public `owner' or workspace fields in ARGUMENTS are ignored."
  (let ((root (gethash "__emacs_mcp_workspace_root" arguments)))
    (unless (and (stringp root) (file-name-absolute-p root) (file-directory-p root))
      (user-error "LAYA requires the agent's launch workspace"))
    (list (file-name-as-directory (file-truename root))
          (gethash "__emacs_mcp_herdr_session" arguments "")
          (gethash "__emacs_mcp_pane" arguments "")
          (gethash "__emacs_mcp_agent_name" arguments ""))))

(defun laya-mcp--validate-options (arguments)
  "Validate optional backend settings in a public submit ARGUMENTS object."
  (let* ((missing (make-symbol "missing"))
         (backend (gethash "backend" arguments missing)))
    (unless (or (eq backend missing)
                (and (stringp backend) (member backend '("mlx" "jev"))))
      (user-error "backend must be \"mlx\" or \"jev\"; omit it to use mlx"))
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
(defun laya-mcp-dispatch (method arguments)
  "Handle typed decision METHOD with launch-scoped ARGUMENTS.
Submitting returns a job ID promptly.  Call result later to retrieve answers."
  (let ((owner (laya-mcp--owner arguments)))
    (pcase method
      ("laya_submit"
       (let ((missing (make-symbol "missing")))
         (laya-mcp--validate-options arguments)
         (when (eq (gethash "state" arguments missing) missing)
           (user-error "state is required"))
         (let ((id (laya-submit
                    (gethash "state" arguments) (gethash "questions" arguments)
                    :backend (gethash "backend" arguments "mlx")
                    :model (gethash "model" arguments)
                    :revision (gethash "revision" arguments)
                    :allow-truncation (eq (gethash "allow_truncation" arguments) t)
                    :owner owner)))
           (laya-result id owner))))
      ("laya_result" (laya-result (gethash "id" arguments) owner))
      ("laya_cancel" (laya-cancel (gethash "id" arguments) owner))
      (_ (user-error "Unknown LAYA method")))))

(provide 'laya-mcp)
;;; laya-mcp.el ends here
