;;; laya-bootstrap.el --- Bootstrap LAYA's private runtime -*- lexical-binding: t -*-

(require 'compile)

(defconst laya-bootstrap--package-directory
  (file-name-directory (or load-file-name (locate-library "laya-bootstrap")))
  "Directory containing LAYA's bootstrap script.")

(defun laya-bootstrap--worker-running-p ()
  "Return non-nil when the LAYA worker is currently running."
  (and (boundp 'laya--process)
       (processp laya--process)
       (process-live-p laya--process)))

(defun laya-bootstrap--compilation-running-p ()
  "Return non-nil when another LAYA bootstrap is active."
  (when-let* ((buffer (get-buffer "*LAYA bootstrap*"))
              (process (get-buffer-process buffer)))
    (process-live-p process)))

(defun laya-bootstrap--run (options)
  "Start the shell bootstrap with OPTIONS and return its compilation buffer."
  (when (laya-bootstrap--worker-running-p)
    (user-error "Stop the LAYA worker with M-x laya-stop before bootstrapping"))
  (when (laya-bootstrap--compilation-running-p)
    (user-error "A LAYA bootstrap is already running"))
  (let* ((script (expand-file-name "bootstrap.sh" laya-bootstrap--package-directory))
         (runtime-directory (expand-file-name "etc/laya" user-emacs-directory))
         (bash (or (executable-find "bash")
                   (user-error "Bash is required to run the LAYA bootstrap"))))
    (unless (file-executable-p script)
      (user-error "LAYA bootstrap script is missing or not executable: %s" script))
    (compilation-start
     (mapconcat #'shell-quote-argument
                (append (list bash script "--runtime-dir" runtime-directory) options)
                " ")
     'compilation-mode
     (lambda (_mode) "*LAYA bootstrap*"))))

;;;###autoload
(defun laya-bootstrap (&optional no-model)
  "Install LAYA's pinned MLX dependencies and default model.
With a prefix argument, install dependencies without downloading the model."
  (interactive "P")
  (laya-bootstrap--run (if no-model '("--no-model") nil)))

;;;###autoload
(defun laya-bootstrap-jev ()
  "Create the portable LAYA runtime without MLX dependencies or a model."
  (interactive)
  (laya-bootstrap--run '("--jev-only")))

(provide 'laya-bootstrap)
;;; laya-bootstrap.el ends here
