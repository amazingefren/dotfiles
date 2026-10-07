;;; decisions-bootstrap.el --- Bootstrap Decisions's private runtime -*- lexical-binding: t -*-

(require 'compile)

(defconst decisions-bootstrap--package-directory
  (file-name-directory (or load-file-name (locate-library "decisions-bootstrap")))
  "Directory containing Decisions's bootstrap script.")

(defun decisions-bootstrap--worker-running-p ()
  "Return non-nil when the Decisions worker is currently running."
  (and (boundp 'decisions--process)
       (processp decisions--process)
       (process-live-p decisions--process)))

(defun decisions-bootstrap--compilation-running-p ()
  "Return non-nil when another Decisions bootstrap is active."
  (when-let* ((buffer (get-buffer "*Decisions bootstrap*"))
              (process (get-buffer-process buffer)))
    (process-live-p process)))

(defun decisions-bootstrap--run (options)
  "Start the shell bootstrap with OPTIONS and return its compilation buffer."
  (when (decisions-bootstrap--worker-running-p)
    (user-error "Stop the Decisions worker with M-x decisions-stop before bootstrapping"))
  (when (decisions-bootstrap--compilation-running-p)
    (user-error "A Decisions bootstrap is already running"))
  (let* ((script (expand-file-name "bootstrap.sh" decisions-bootstrap--package-directory))
         (runtime-directory (expand-file-name "etc/decisions" user-emacs-directory))
         (bash (or (executable-find "bash")
                   (user-error "Bash is required to run the Decisions bootstrap"))))
    (unless (file-executable-p script)
      (user-error "Decisions bootstrap script is missing or not executable: %s" script))
    (compilation-start
     (mapconcat #'shell-quote-argument
                (append (list bash script "--runtime-dir" runtime-directory) options)
                " ")
     'compilation-mode
     (lambda (_mode) "*Decisions bootstrap*"))))

;;;###autoload
(defun decisions-bootstrap (&optional no-model)
  "Install Decisions's pinned MLX dependencies and default model.
With a prefix argument, install dependencies without downloading the model."
  (interactive "P")
  (decisions-bootstrap--run (if no-model '("--no-model") nil)))

;;;###autoload
(defun decisions-bootstrap-jev ()
  "Create the portable Decisions runtime without MLX dependencies or a model."
  (interactive)
  (decisions-bootstrap--run '("--jev-only")))

(provide 'decisions-bootstrap)
;;; decisions-bootstrap.el ends here
