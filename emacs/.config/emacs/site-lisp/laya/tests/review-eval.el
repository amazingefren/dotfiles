;;; review-eval.el --- Score the review rubric against its labeled cases -*- lexical-binding: t -*-

;; emacs --batch -l tests/review-eval.el [RUBRIC]
;; Uses the rubric's backend.
(let* ((package (expand-file-name ".." (file-name-directory load-file-name)))
       (emacs-dir (file-name-as-directory (expand-file-name "../.." package))))
  (setq user-emacs-directory emacs-dir)
  (add-to-list 'load-path package)
  (require 'laya-review))

(let ((laya-review-rubric-file (or (car command-line-args-left) laya-review-rubric-file))
      (laya-review-concurrency 8)
      report)
  (laya-review-eval (lambda (text) (setq report text)))
  (let ((deadline (+ (float-time) 900)))
    (while (and (null report) (< (float-time) deadline)) (accept-process-output nil 0.05)))
  (laya-stop)
  (princ (or report "LAYA review eval timed out\n")))

;;; review-eval.el ends here
