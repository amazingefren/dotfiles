;;; rubric-lint.el --- Ask the backend to judge the rubric's questions -*- lexical-binding: t -*-

;; emacs --batch -l tests/rubric-lint.el [RUBRIC]
;; Uses the rubric's backend.  The state sent is the rubric's own question
;; text, never repository code.
(let* ((package (expand-file-name ".." (file-name-directory load-file-name)))
       (emacs-dir (file-name-as-directory (expand-file-name "../.." package))))
  (setq user-emacs-directory emacs-dir)
  (add-to-list 'load-path package)
  (require 'decisions-review))

(let ((decisions-review-rubric-file (or (car command-line-args-left) decisions-review-rubric-file))
      (decisions-review-concurrency 8)
      report)
  (decisions-review-lint-rubric (lambda (text) (setq report text)))
  (let ((deadline (+ (float-time) 600)))
    (while (and (null report) (< (float-time) deadline)) (accept-process-output nil 0.05)))
  (decisions-stop)
  (princ (or report "Decisions rubric lint timed out\n")))

;;; rubric-lint.el ends here
