;;; decisions-playground.el --- Editable experiments for Decisions -*- lexical-binding: t -*-

(require 'decisions)
(require 'js)
(require 'json)
(require 'subr-x)

(defvar-local decisions-playground--job nil)
(defvar-local decisions-playground--snapshot nil)
(defvar-local decisions-playground--result-buffer nil)

(defun decisions-playground--bind-quit-keys (&optional editable)
  "Bind quit keys in the current Decisions buffer.
When EDITABLE is non-nil, leave `q' available as text outside Evil states."
  (local-set-key (kbd "C-c C-q") #'quit-window)
  (unless editable
    (local-set-key (kbd "q") #'quit-window))
  (when (fboundp 'evil-local-set-key)
    (evil-local-set-key 'normal (kbd "q") #'quit-window)
    (evil-local-set-key 'motion (kbd "q") #'quit-window)))

(defun decisions-playground--json (value)
  "Pretty-print JSON VALUE with distinct false, null and empty containers."
  (with-temp-buffer
    (insert (json-serialize value :null-object :null :false-object :false))
    (json-pretty-print-buffer)
    (buffer-string)))

(defun decisions-playground--read ()
  "Read the request in the current playground."
  (let ((request (json-parse-string (buffer-substring-no-properties (point-min) (point-max))
                                  :object-type 'hash-table :array-type 'array
                                  :null-object :null :false-object :false)))
    (unless (hash-table-p request) (user-error "The request must be a JSON object"))
    request))

(defun decisions-playground--validate-options (request)
  "Validate optional backend fields in REQUEST before submitting it."
  (let* ((missing (make-symbol "missing"))
         (backend (gethash "backend" request missing)))
    (unless (or (eq backend missing)
                (and (stringp backend) (member backend '("mlx" "laya" "jev"))))
      (user-error "backend must be \"mlx\", \"laya\", or \"jev\"; omit it to use `decisions-default-backend'"))
    (dolist (field '("model" "revision"))
      (let ((value (gethash field request missing)))
        (unless (or (eq value missing)
                    (and (stringp value) (not (string-empty-p value))))
          (user-error "%s must be a nonempty string; omit it to use the default" field))))
    (let ((value (gethash "allow_truncation" request missing)))
      (unless (or (eq value missing) (eq value t) (eq value :false))
        (user-error "allow_truncation must be true or false")))
    (when (and (equal (if (eq backend missing) decisions-default-backend backend) "jev")
               (not (eq (gethash "revision" request missing) missing)))
      (user-error "revision is only supported by the local MLX backend; use a Jev model ID"))))

(defun decisions-playground--job-running-p (id)
  "Return non-nil when ID is still queued or running.
An ID pruned from the retained job table is treated as completed."
  (and id
       (condition-case nil
           (member (gethash "status" (decisions-result id)) '("queued" "running"))
         (error nil))))

(defun decisions-playground--new (request &optional snapshot)
  "Open editable REQUEST and optionally display saved SNAPSHOT."
  (let ((buffer (generate-new-buffer "*Decisions playground*")))
    (with-current-buffer buffer
      (decisions-playground-mode)
      (insert (decisions-playground--json request) "\n")
      (goto-char (point-min))
      (setq decisions-playground--snapshot snapshot)
      (set-buffer-modified-p nil))
    (pop-to-buffer buffer)
    (when snapshot (decisions-playground--display buffer snapshot))
    buffer))

;;;###autoload
(defun decisions-playground ()
  "Open a new Decisions experiment.  No worker or model starts until Run."
  (interactive)
  (decisions-playground--new
   (json-parse-string
    "{\"backend\":\"mlx\",\"state\":\"Replace this with your own state.\",\"questions\":{\"check\":{\"type\":\"noul\",\"instructions\":\"Does the state ask a question?\"}},\"allow_truncation\":false}"
    :null-object :null :false-object :false)))

;;;###autoload
(defun decisions-playground-region (start end)
  "Open a playground using the region from START to END as state."
  (interactive "r")
  (let ((state (buffer-substring-no-properties start end)))
    (decisions-playground)
    (let ((request (decisions-playground--read)))
      (puthash "state" state request)
      (erase-buffer)
      (insert (decisions-playground--json request) "\n")
      (goto-char (point-min)))))

(defun decisions-playground--completed (buffer snapshot)
  "Record SNAPSHOT in originating BUFFER without changing keyboard focus."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (equal (gethash "id" snapshot) decisions-playground--job)
        (setq decisions-playground--snapshot snapshot)
        (setq header-line-format
              (format " Decisions: %s  |  C-c C-c run  C-c C-k cancel  C-c C-s save  C-c C-o open"
                      (gethash "status" snapshot)))
        (decisions-playground--display buffer snapshot)))))

(defun decisions-playground-run ()
  "Submit the current JSON request asynchronously."
  (interactive)
  (when (decisions-playground--job-running-p decisions-playground--job)
    (user-error "This experiment is still running; cancel it or open another playground"))
  (let* ((request (decisions-playground--read))
         (missing (make-symbol "missing"))
         (state (gethash "state" request missing))
         (buffer (current-buffer)))
    (decisions-playground--validate-options request)
    (when (eq state missing) (user-error "The request needs a state field"))
    (setq decisions-playground--job
          (decisions-submit state (gethash "questions" request)
                       :backend (gethash "backend" request decisions-default-backend)
                       :model (gethash "model" request)
                       :revision (gethash "revision" request)
                       :allow-truncation (eq (gethash "allow_truncation" request) t)
                       :callback (lambda (snapshot)
                                   (decisions-playground--completed buffer snapshot))))
    (setq decisions-playground--snapshot nil
          header-line-format " Decisions: pending  |  C-c C-k cancel  |  Results appear asynchronously")
    (message "Decisions submitted %s" decisions-playground--job)))

(defun decisions-playground-cancel ()
  "Cancel this playground's request without stopping other experiments."
  (interactive)
  (unless decisions-playground--job (user-error "No request to cancel"))
  (decisions-playground--completed (current-buffer) (decisions-cancel decisions-playground--job)))

(defun decisions-playground--display (source snapshot)
  "Show SNAPSHOT for SOURCE in a reusable result buffer."
  (let ((result-buffer
         (with-current-buffer source
           (unless (buffer-live-p decisions-playground--result-buffer)
             (setq decisions-playground--result-buffer
                   (generate-new-buffer "*Decisions result*")))
           decisions-playground--result-buffer)))
    (with-current-buffer result-buffer
      (let ((inhibit-read-only t)
            (result (gethash "result" snapshot)))
        (erase-buffer)
        (insert (format "Decisions experiment — %s\n\n" (gethash "status" snapshot)))
        (insert "Noul = P(true). Score = expected rubric index (starting at 0).\n")
        (insert "Confidence describes the distribution; it does not guarantee correctness.\n\n")
        (insert "Current editable request\n\n")
        (when (buffer-live-p source)
          (insert (with-current-buffer source (buffer-substring-no-properties
                                               (point-min) (point-max))) "\n"))
        (when (gethash "request" snapshot)
          (insert "Request used for this run\n\n")
          (insert (decisions-playground--json (gethash "request" snapshot)) "\n\n"))
        (when (hash-table-p result)
          (let ((answers (gethash "answers" result)))
            (when (hash-table-p answers)
              (maphash
               (lambda (name answer)
                 (insert (format "%s [%s]\n" name (gethash "type" answer)))
                 (pcase (gethash "type" answer)
                   ("choice" (insert (format "  choice: %s\n" (gethash "choice" answer))))
                   ("score" (insert (format "  score: %s\n" (gethash "score" answer))))
                   ("noul" (insert (format "  P(true): %s\n" (gethash "noul" answer)))))
                 (when-let* ((probabilities (gethash "probabilities" answer)))
                   (when (hash-table-p probabilities)
                     (maphash (lambda (label probability)
                                (insert (format "  %-24s %s\n" label probability)))
                              probabilities)))
                 (insert "\n"))
               answers))))
        (insert "Run result and runtime metadata\n\n")
        (insert (decisions-playground--json snapshot) "\n")
        (goto-char (point-min))
        (decisions-playground-result-mode)))
    (display-buffer result-buffer)))

(defun decisions-playground-show-result ()
  "Display the last result or current request status."
  (interactive)
  (let ((snapshot (or decisions-playground--snapshot
                      (and decisions-playground--job (decisions-result decisions-playground--job)))))
    (unless snapshot (user-error "Run an experiment first"))
    (decisions-playground--display (current-buffer) snapshot)))

(defun decisions-playground-save-experiment (file)
  "Save the editable request and last run separately to FILE as plain JSON."
  (interactive "FSave experiment: ")
  (let* ((request (decisions-playground--read))
         (record (make-hash-table :test #'equal))
         (exists (file-exists-p file)))
    (when (and exists
               (not (yes-or-no-p (format "Overwrite %s? " (abbreviate-file-name file)))))
      (user-error "Decisions experiment was not saved"))
    (puthash "format" "decisions-experiment-v1" record)
    (puthash "request" request record)
    (when decisions-playground--snapshot
      ;; The run's request may differ from the input, e.g. with defaults filled in.
      (puthash "previous_run" decisions-playground--snapshot record))
    (with-temp-buffer
      (insert (decisions-playground--json record) "\n")
      (write-region (point-min) (point-max) file nil nil nil (unless exists 'excl)))
    (message "Saved Decisions request and previous run to %s" file)))

;;;###autoload
(defun decisions-playground-open-experiment (file)
  "Open saved experiment FILE for editing.  Does not run the request."
  (interactive "fOpen Decisions experiment: ")
  (let* ((record (with-temp-buffer
                   (insert-file-contents file)
                   (json-parse-buffer :object-type 'hash-table :array-type 'array
                                      :null-object :null :false-object :false))))
    (unless (and (hash-table-p record)
                 (equal (gethash "format" record) "decisions-experiment-v1")
                 (hash-table-p (gethash "request" record)))
      (user-error "Not a Decisions experiment file"))
    (decisions-playground--new (gethash "request" record) (gethash "previous_run" record))))

(defvar decisions-playground-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'decisions-playground-run)
    (define-key map (kbd "C-c C-k") #'decisions-playground-cancel)
    (define-key map (kbd "C-c C-r") #'decisions-playground-show-result)
    (define-key map (kbd "C-c C-q") #'quit-window)
    (define-key map (kbd "C-c C-s") #'decisions-playground-save-experiment)
    (define-key map (kbd "C-c C-o") #'decisions-playground-open-experiment)
    map))

(define-derived-mode decisions-playground-mode js-json-mode "Decisions"
  "Edit arbitrary state and typed questions for the Decisions harness."
  (decisions-playground--bind-quit-keys t)
  (setq-local header-line-format
              " Decisions: edit JSON  |  q quit in Evil normal/motion  C-c C-q quit  C-c C-c run  C-c C-k cancel"))

(define-derived-mode decisions-playground-result-mode special-mode "Decisions-Result"
  "Read-only Decisions result buffer."
  (decisions-playground--bind-quit-keys))

(provide 'decisions-playground)
;;; decisions-playground.el ends here
