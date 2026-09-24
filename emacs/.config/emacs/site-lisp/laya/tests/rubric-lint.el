;;; rubric-lint.el --- Ask the backend to judge the rubric's questions -*- lexical-binding: t -*-

;; emacs --batch -l tests/rubric-lint.el [RUBRIC]
;; Uses the rubric's backend.  The state sent is the rubric's own question
;; text, never repository code.
(let* ((package (expand-file-name ".." (file-name-directory load-file-name)))
       (emacs-dir (file-name-as-directory (expand-file-name "../.." package))))
  (setq user-emacs-directory emacs-dir)
  (add-to-list 'load-path package)
  (require 'laya-review))

(let ((laya-review-rubric-file (or (car command-line-args-left) laya-review-rubric-file))
      (laya-review-concurrency 8)
      report)
  (laya-review-lint-rubric (lambda (text) (setq report text)))
  (let ((deadline (+ (float-time) 600)))
    (while (and (null report) (< (float-time) deadline)) (accept-process-output nil 0.05)))
  (laya-stop)
  (princ (or report "LAYA rubric lint timed out\n")))

;;; rubric-lint.el ends here
