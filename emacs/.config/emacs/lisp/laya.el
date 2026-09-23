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

(use-package laya-mcp
  :load-path "site-lisp/laya"
  :ensure nil
  :commands (laya-mcp-dispatch))

(use-package laya-bootstrap
  :load-path "site-lisp/laya"
  :ensure nil
  :commands (laya-bootstrap laya-bootstrap-jev))

;;; laya.el ends here
