;;; git.el --- magit and gutter diffs  -*- lexical-binding: t -*-

(use-package magit
  :commands (magit-status magit-blame-addition magit-log-current
             magit-log-buffer-file magit-diff-working-tree
             magit-diff-range magit-branch-checkout)
  :custom
  (magit-display-buffer-function #'magit-display-buffer-same-window-except-diff-v1)
  ;; (dir . depth)
  (magit-repository-directories '(("~/Code" . 2) ("~/.dotfiles" . 0)))
  (magit-repolist-columns '(("Name" 25 magit-repolist-column-ident nil)
                            ("Branch" 20 magit-repolist-column-branch nil)
                            ("Dirty" 5 magit-repolist-column-flag nil)
                            ("↓" 3 magit-repolist-column-unpulled-from-upstream ((:right-align t)))
                            ("↑" 3 magit-repolist-column-unpushed-to-upstream ((:right-align t)))
                            ("Path" 40 magit-repolist-column-path nil)))
  :config
  (defun magit-diff-merge-base ()
    "Diff the working tree against the merge base with the main branch."
    (interactive)
    (magit-diff-range (format "%s...HEAD" (or (magit-main-branch) "main")))))

(use-package forge
  :after magit
  :custom
  (forge-owned-accounts '(("amazingefren")))
  :config
  (defun git-github-username (orig host &optional forge)
    (if (memq forge '(nil github)) "amazingefren" (funcall orig host forge)))
  (defun git-github-token (orig host username package &optional nocreate forge)
    (if (and (memq forge '(nil github)) (equal host "api.github.com"))
        (op-secret 'github-forge-token)
      (funcall orig host username package nocreate forge)))
  (advice-add 'ghub--username :around #'git-github-username)
  (advice-add 'ghub--token :around #'git-github-token))

(use-package diff-hl
  :hook ((magit-pre-refresh  . diff-hl-magit-pre-refresh)
         (magit-post-refresh . diff-hl-magit-post-refresh))
  :custom
  (diff-hl-show-hunk-function #'diff-hl-show-hunk-inline-popup)
  ;; Each on-the-fly diff blocks input ~30ms (async mode longer).
  (diff-hl-flydiff-delay 2)
  :init
  (global-diff-hl-mode 1)
  :config
  (diff-hl-flydiff-mode 1)
  (require 'diff-hl-show-hunk)  ; not autoloaded
  (require 'diff-hl-show-hunk-inline)
  (global-diff-hl-show-hunk-mouse-mode 1))

(leader
  "g"  '(:ignore t :wk "git")
  "gg" '(magit-status :wk "status (this file's repo)")
  "gG" '(magit-list-repositories :wk "all repos")
  "gb" '(magit-blame-addition :wk "blame")
  "gl" '(magit-log-current :wk "log")
  "gf" '(magit-log-buffer-file :wk "file log")
  "gd" '(magit-diff-working-tree :wk "diff uncommitted")
  "gm" '(magit-diff-merge-base :wk "diff merge base")
  "gr" '(magit-diff-range :wk "diff range")
  "gB" '(magit-branch-checkout :wk "branch")
  "gp" '(forge-list-pullreqs :wk "pull requests")
  "gi" '(forge-list-issues :wk "issues")
  "go" '(diff-hl-show-hunk :wk "show hunk diff (inline)")
  "gh" '(diff-hl-next-hunk :wk "next hunk")
  "gH" '(diff-hl-previous-hunk :wk "prev hunk")
  "gs" '(diff-hl-stage-current-hunk :wk "stage hunk"))
