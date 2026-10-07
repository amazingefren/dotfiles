;;; review-eval.el --- Score the review rubric against its labeled cases -*- lexical-binding: t -*-

;; emacs --batch -l tests/review-eval.el [RUBRIC]
;; Uses the rubric's backend.
(let* ((package (expand-file-name ".." (file-name-directory load-file-name)))
       (emacs-dir (file-name-as-directory (expand-file-name "../.." package))))
  (setq user-emacs-directory emacs-dir)
  (add-to-list 'load-path package)
  (require 'decisions-review))

(let ((decisions-review-rubric-file (or (car command-line-args-left) decisions-review-rubric-file))
      (decisions-review-concurrency 8)
      report)
  (decisions-review-eval (lambda (text) (setq report text)))
  (let ((deadline (+ (float-time) 900)))
    (while (and (null report) (< (float-time) deadline)) (accept-process-output nil 0.05)))
  (decisions-stop)
  (princ (or report "Decisions review eval timed out\n")))

;;; review-eval.el ends here
