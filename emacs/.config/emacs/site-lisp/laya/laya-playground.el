;;; laya-playground.el --- Editable experiments for LAYA -*- lexical-binding: t -*-

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; A JSON workbench for the asynchronous `laya' API.  Experiments are data;
;; opening or replaying one never evaluates Lisp or submits an API request.

;;; Code:
(require 'laya)
(require 'js)
(require 'json)
(require 'subr-x)

(defvar-local laya-playground--job nil)
(defvar-local laya-playground--snapshot nil)
(defvar-local laya-playground--result-buffer nil)

(defun laya-playground--bind-quit-keys (&optional editable)
  "Bind quit keys in the current LAYA buffer.
When EDITABLE is non-nil, leave `q' available as text outside Evil states."
  (local-set-key (kbd "C-c C-q") #'quit-window)
  (unless editable
    (local-set-key (kbd "q") #'quit-window))
  (when (fboundp 'evil-local-set-key)
    (evil-local-set-key 'normal (kbd "q") #'quit-window)
    (evil-local-set-key 'motion (kbd "q") #'quit-window)))

(defun laya-playground--json (value)
  "Pretty-print JSON VALUE with distinct false, null and empty containers."
  (with-temp-buffer
    (insert (json-serialize value :null-object :null :false-object :false))
    (json-pretty-print-buffer)
    (buffer-string)))

(defun laya-playground--read ()
  "Read the request in the current playground."
  (let ((request (json-parse-string (buffer-substring-no-properties (point-min) (point-max))
                                  :object-type 'hash-table :array-type 'array
                                  :null-object :null :false-object :false)))
    (unless (hash-table-p request) (user-error "The request must be a JSON object"))
    request))

(defun laya-playground--validate-options (request)
  "Validate optional backend fields in REQUEST before submitting it."
  (let* ((missing (make-symbol "missing"))
         (backend (gethash "backend" request missing)))
    (unless (or (eq backend missing)
                (and (stringp backend) (member backend '("mlx" "jev"))))
      (user-error "backend must be \"mlx\" or \"jev\"; omit it to use mlx"))
    (dolist (field '("model" "revision"))
      (let ((value (gethash field request missing)))
        (unless (or (eq value missing)
                    (and (stringp value) (not (string-empty-p value))))
          (user-error "%s must be a nonempty string; omit it to use the default" field))))
    (let ((value (gethash "allow_truncation" request missing)))
      (unless (or (eq value missing) (eq value t) (eq value :false))
        (user-error "allow_truncation must be true or false")))
    (when (and (equal backend "jev")
               (not (eq (gethash "revision" request missing) missing)))
      (user-error "revision is only supported by the local MLX backend; use a Jev model ID"))))

(defun laya-playground--job-running-p (id)
  "Return non-nil when ID is still queued or running.
An ID pruned from the retained job table is treated as completed."
  (and id
       (condition-case nil
           (member (gethash "status" (laya-result id)) '("queued" "running"))
         (error nil))))

(defun laya-playground--new (request &optional snapshot)
  "Open editable REQUEST and optionally display saved SNAPSHOT."
  (let ((buffer (generate-new-buffer "*LAYA playground*")))
    (with-current-buffer buffer
      (laya-playground-mode)
      (insert (laya-playground--json request) "\n")
      (goto-char (point-min))
      (setq laya-playground--snapshot snapshot)
      (set-buffer-modified-p nil))
    (pop-to-buffer buffer)
    (when snapshot (laya-playground--display buffer snapshot))
    buffer))

;;;###autoload
(defun laya-playground ()
  "Open a new LAYA experiment.  No worker or model starts until Run."
  (interactive)
  (laya-playground--new
   (json-parse-string
    "{\"backend\":\"mlx\",\"state\":\"Replace this with your own state.\",\"questions\":{\"check\":{\"type\":\"noul\",\"instructions\":\"Does the state ask a question?\"}},\"allow_truncation\":false}"
    :null-object :null :false-object :false)))

;;;###autoload
(defun laya-playground-region (start end)
  "Open a playground using the region from START to END as state."
  (interactive "r")
  (let ((state (buffer-substring-no-properties start end)))
    (laya-playground)
    (let ((request (laya-playground--read)))
      (puthash "state" state request)
      (erase-buffer)
      (insert (laya-playground--json request) "\n")
      (goto-char (point-min)))))

(defun laya-playground--completed (buffer snapshot)
  "Record SNAPSHOT in originating BUFFER without changing keyboard focus."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      ;; A saved callback from an older run must not replace a newer result.
      (when (equal (gethash "id" snapshot) laya-playground--job)
        (setq laya-playground--snapshot snapshot)
        (setq header-line-format
              (format " LAYA: %s  |  C-c C-c run  C-c C-k cancel  C-c C-s save  C-c C-o open"
                      (gethash "status" snapshot)))
        (laya-playground--display buffer snapshot)))))

(defun laya-playground-run ()
  "Submit the current JSON request asynchronously."
  (interactive)
  (when (laya-playground--job-running-p laya-playground--job)
    (user-error "This experiment is still running; cancel it or open another playground"))
  (let* ((request (laya-playground--read))
         (missing (make-symbol "missing"))
         (state (gethash "state" request missing))
         (buffer (current-buffer)))
    (laya-playground--validate-options request)
    (when (eq state missing) (user-error "The request needs a state field"))
    (setq laya-playground--job
          (laya-submit state (gethash "questions" request)
                       :backend (gethash "backend" request "mlx")
                       :model (gethash "model" request)
                       :revision (gethash "revision" request)
                       :allow-truncation (eq (gethash "allow_truncation" request) t)
                       :callback (lambda (snapshot)
                                   (laya-playground--completed buffer snapshot))))
    (setq laya-playground--snapshot nil
          header-line-format " LAYA: pending  |  C-c C-k cancel  |  Results appear asynchronously")
    (message "LAYA submitted %s" laya-playground--job)))

(defun laya-playground-cancel ()
  "Cancel this playground's request without stopping other experiments."
  (interactive)
  (unless laya-playground--job (user-error "No request to cancel"))
  (laya-playground--completed (current-buffer) (laya-cancel laya-playground--job)))

(defun laya-playground--display (source snapshot)
  "Show SNAPSHOT for SOURCE in a reusable result buffer."
  (let ((result-buffer
         (with-current-buffer source
           (unless (buffer-live-p laya-playground--result-buffer)
             (setq laya-playground--result-buffer
                   (generate-new-buffer "*LAYA result*")))
           laya-playground--result-buffer)))
    (with-current-buffer result-buffer
      (let ((inhibit-read-only t)
            (result (gethash "result" snapshot)))
        (erase-buffer)
        (insert (format "LAYA experiment — %s\n\n" (gethash "status" snapshot)))
        (insert "Noul = P(true). Score = expected rubric index (starting at 0).\n")
        (insert "Confidence describes the distribution; it does not guarantee correctness.\n\n")
        (insert "Current editable request\n\n")
        (when (buffer-live-p source)
          (insert (with-current-buffer source (buffer-substring-no-properties
                                               (point-min) (point-max))) "\n"))
        (when (gethash "request" snapshot)
          (insert "Request used for this run\n\n")
          (insert (laya-playground--json (gethash "request" snapshot)) "\n\n"))
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
        (insert (laya-playground--json snapshot) "\n")
        (goto-char (point-min))
        (laya-playground-result-mode)))
    (display-buffer result-buffer)))

(defun laya-playground-show-result ()
  "Display the last result or current request status."
  (interactive)
  (let ((snapshot (or laya-playground--snapshot
                      (and laya-playground--job (laya-result laya-playground--job)))))
    (unless snapshot (user-error "Run an experiment first"))
    (laya-playground--display (current-buffer) snapshot)))

(defun laya-playground-save-experiment (file)
  "Save the editable request and last run separately to FILE as plain JSON."
  (interactive "FSave experiment: ")
  (let* ((request (laya-playground--read))
         (record (make-hash-table :test #'equal))
         (exists (file-exists-p file)))
    (when (and exists
               (not (yes-or-no-p (format "Overwrite %s? " (abbreviate-file-name file)))))
      (user-error "LAYA experiment was not saved"))
    (puthash "format" "laya-experiment-v1" record)
    (puthash "request" request record)
    (when laya-playground--snapshot
      ;; Store the completed request independently, since defaults may have
      ;; been filled in and the editable input may now differ from that run.
      (puthash "previous_run" laya-playground--snapshot record))
    (with-temp-buffer
      (insert (laya-playground--json record) "\n")
      (write-region (point-min) (point-max) file nil nil nil (unless exists 'excl)))
    (message "Saved LAYA request and previous run to %s" file)))

;;;###autoload
(defun laya-playground-open-experiment (file)
  "Open saved experiment FILE for editing.  Does not run the request."
  (interactive "fOpen LAYA experiment: ")
  (let* ((record (with-temp-buffer
                   (insert-file-contents file)
                   (json-parse-buffer :object-type 'hash-table :array-type 'array
                                      :null-object :null :false-object :false))))
    (unless (and (hash-table-p record)
                 (equal (gethash "format" record) "laya-experiment-v1")
                 (hash-table-p (gethash "request" record)))
      (user-error "Not a LAYA experiment file"))
    (laya-playground--new (gethash "request" record) (gethash "previous_run" record))))

(defvar laya-playground-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'laya-playground-run)
    (define-key map (kbd "C-c C-k") #'laya-playground-cancel)
    (define-key map (kbd "C-c C-r") #'laya-playground-show-result)
    (define-key map (kbd "C-c C-q") #'quit-window)
    (define-key map (kbd "C-c C-s") #'laya-playground-save-experiment)
    (define-key map (kbd "C-c C-o") #'laya-playground-open-experiment)
    map))

(define-derived-mode laya-playground-mode js-json-mode "LAYA"
  "Edit arbitrary state and typed questions for the LAYA harness."
  (laya-playground--bind-quit-keys t)
  (setq-local header-line-format
              " LAYA: edit JSON  |  q quit in Evil normal/motion  C-c C-q quit  C-c C-c run  C-c C-k cancel"))

(define-derived-mode laya-playground-result-mode special-mode "LAYA-Result"
  "Read-only LAYA result buffer."
  (laya-playground--bind-quit-keys))

(provide 'laya-playground)
;;; laya-playground.el ends here
