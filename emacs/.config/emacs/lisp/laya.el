;;; laya.el --- Lazy LAYA harness registration -*- lexical-binding: t -*-

;; These declarations register commands only.  Python and model loading begin
;; when a request is submitted, independently of Emacs startup and Herdr.
(use-package laya
  :load-path "site-lisp/laya"
  :ensure nil
  :commands (laya-submit laya-result laya-cancel laya-start laya-status
                         laya-stop laya-restart laya-warm))

(use-package laya-playground
  :load-path "site-lisp/laya"
  :ensure nil
  :commands (laya-playground laya-playground-region laya-playground-open-experiment))

(use-package laya-review
  :load-path "site-lisp/laya"
  :ensure nil
  :commands (laya-review laya-review-branch laya-review-focused-diff laya-review-submit-hunk))

;; eplot draws the review's risk chart.  It is not on an archive yet.
(use-package eplot
  :vc (:url "https://github.com/larsmagne/eplot" :rev :newest)
  :defer t)

;; SPC g R reviews the diff on screen (magit/diff buffer) or uncommitted
;; changes; SPC u SPC g R picks staged, branch, or a range instead.
(leader
  "gR" '(laya-review :wk "LAYA review diff")
  "gV" '(laya-review-branch :wk "LAYA review branch"))

(use-package laya-mcp
  :load-path "site-lisp/laya"
  :ensure nil
  :commands (laya-mcp-dispatch))

(use-package laya-bootstrap
  :load-path "site-lisp/laya"
  :ensure nil
  :commands (laya-bootstrap laya-bootstrap-jev))

;;; laya.el ends here
