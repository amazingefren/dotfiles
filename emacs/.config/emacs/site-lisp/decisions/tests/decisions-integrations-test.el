;;; decisions-integrations-test.el --- Advisor lifecycle tests -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name)))
(require 'decisions-integrations)

(ert-deftest decisions-integrations-replaced-and-killed-jobs-discard-callbacks ()
  (let (callbacks cancelled shown)
    (cl-letf (((symbol-function 'decisions-submit)
               (lambda (_state _questions &rest options)
                 (push (plist-get options :callback) callbacks)
                 (format "job-%d" (length callbacks))))
              ((symbol-function 'decisions-cancel)
               (lambda (id &optional _owner) (push id cancelled)))
              ((symbol-function 'decisions-integrations--display)
               (lambda (_source snapshot) (push snapshot shown))))
      (let ((source (generate-new-buffer " *advisor lifecycle*")))
        (unwind-protect
            (with-current-buffer source
              (decisions-integrations--advise "first" (make-hash-table) (lambda () t))
              (decisions-integrations--advise "second" (make-hash-table) (lambda () t))
              (funcall (cadr callbacks) 'old)
              (should-not shown)
              (should (equal cancelled '("job-1")))
              (kill-buffer source)
              (funcall (car callbacks) 'late)
              (should-not shown)
              (should (equal cancelled '("job-2" "job-1"))))
          (when (buffer-live-p source) (kill-buffer source)))))))

(ert-deftest decisions-org-advisor-reads-agenda-source-and-discards-edits ()
  (let (callback captured-state shown)
    (cl-letf (((symbol-function 'decisions-submit)
               (lambda (state _questions &rest options)
                 (setq captured-state state callback (plist-get options :callback))
                 "org-job"))
              ((symbol-function 'decisions-cancel) (lambda (&rest _)))
              ((symbol-function 'decisions-integrations--display)
               (lambda (_source snapshot) (setq shown snapshot))))
      (with-temp-buffer
        (org-mode)
        (insert "* TODO Call dentist\nConfirm opening hours.\n* TODO Other\n")
        (goto-char (point-min))
        (let ((heading (point-marker)) (source (current-buffer)))
          (with-temp-buffer
            (setq major-mode 'org-agenda-mode)
            (insert (propertize "Call dentist" 'org-hd-marker heading))
            (goto-char (point-min))
            (decisions-org-advise)
            (should (string-match-p "Call dentist" captured-state))
            (should-not (string-match-p "Other" captured-state))
            (with-current-buffer source (goto-char (point-max)) (insert "changed"))
            (funcall callback 'result)
            (should-not shown)))))))

(ert-deftest decisions-integrations-result-shows-distribution-without-copying-source ()
  (with-temp-buffer
    (insert "Private unrelated buffer text")
    (let ((source (current-buffer))
          (snapshot (decisions--object
                     "result" (decisions--object
                               "answers" (decisions--object
                                          "reading" (decisions--object
                                                     "choice" "save"
                                                     "probabilities" (decisions--object "save" 0.8 "skip" 0.2)
                                                     "type" "choice")))
                     "status" "done")))
      (unwind-protect
          (progn
            (decisions-integrations--display source snapshot)
            (with-current-buffer decisions-playground--result-buffer
              (should buffer-read-only)
              (should (string-match-p "save" (buffer-string)))
              (should (string-match-p "80.0%" (buffer-string)))
              (should-not (string-match-p "Private unrelated" (buffer-string)))))
        (when (buffer-live-p decisions-playground--result-buffer)
          (kill-buffer decisions-playground--result-buffer))))))

(ert-deftest decisions-integrations-failure-displays-actionable-error ()
  (with-temp-buffer
    (let ((snapshot (decisions--object
                     "error" (decisions--object "message" "Model missing at /tmp/clef")
                     "status" "failed")))
      (unwind-protect
          (progn
            (decisions-integrations--display (current-buffer) snapshot)
            (with-current-buffer decisions-playground--result-buffer
              (should (string-match-p "Error: Model missing at /tmp/clef" (buffer-string)))))
        (when (buffer-live-p decisions-playground--result-buffer)
          (kill-buffer decisions-playground--result-buffer))))))
