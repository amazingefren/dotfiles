;;; decisions.el --- Lazy Decisions harness registration -*- lexical-binding: t -*-

(use-package decisions
  :load-path "site-lisp/decisions"
  :ensure nil
  :custom (decisions-idle-seconds nil)
  :commands (decisions-submit decisions-result decisions-cancel decisions-start decisions-status
                         decisions-stop decisions-restart decisions-warm))

(use-package decisions-playground
  :load-path "site-lisp/decisions"
  :ensure nil
  :commands (decisions-playground decisions-playground-region decisions-playground-open-experiment))

(use-package decisions-integrations
  :load-path "site-lisp/decisions"
  :ensure nil
  :commands (decisions-org-advise decisions-integrations-cancel))

(use-package decisions-feeds
  :load-path "site-lisp/decisions"
  :ensure nil
  :custom (decisions-feeds-default-filter "@2-weeks-ago -Papers")
  :commands (decisions-feeds-rank))

(use-package decisions-review
  :load-path "site-lisp/decisions"
  :ensure nil
  :commands (decisions-review decisions-review-branch decisions-review-focused-diff decisions-review-submit-hunk))

;; eplot (the review's risk chart) is not on a package archive yet.
(use-package eplot
  :vc (:url "https://github.com/larsmagne/eplot" :rev :newest)
  :defer t)

(leader
  "d" '(:ignore t :wk "decisions")
  "df" '(decisions-feeds-rank :wk "rank feeds")
  "do" '(decisions-org-advise :wk "org advice")
  "dc" '(decisions-integrations-cancel :wk "cancel advice")
  "dp" '(decisions-playground :wk "playground")
  "dr" '(decisions-playground-region :wk "classify region")
  "ds" '(decisions-status :wk "status")
  "dw" '(decisions-warm :wk "warm model")
  "dR" '(decisions-restart :wk "restart worker")
  "dx" '(decisions-stop :wk "stop worker")
  "gR" '(decisions-review :wk "Decisions review diff")
  "gV" '(decisions-review-branch :wk "Decisions review branch"))

(use-package decisions-mcp
  :load-path "site-lisp/decisions"
  :ensure nil
  :commands (decisions-mcp-dispatch))

(use-package decisions-bootstrap
  :load-path "site-lisp/decisions"
  :ensure nil
  :commands (decisions-bootstrap decisions-bootstrap-jev))

;;; decisions.el ends here
