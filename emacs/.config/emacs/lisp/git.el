;;; git.el --- magit and gutter diffs  -*- lexical-binding: t -*-

;; magit: the git UI. SPC g g opens status; from there s stages, u unstages,
;; c c commits, P p pushes, F p pulls, ? shows every key.
(use-package magit
  :commands (magit-status magit-blame-addition magit-log-current
             magit-log-buffer-file magit-diff-working-tree
             magit-diff-range magit-branch-checkout)
  :custom
  ;; Open magit in the current window instead of splitting, except for diffs.
  (magit-display-buffer-function #'magit-display-buffer-same-window-except-diff-v1)
  ;; Where my repos live (dir . depth). SPC g g from a buffer that isn't inside a
  ;; repo (dired on a folder of repos, a shell, the home workspace) picks from these
  ;; instead of asking for a path, and SPC g G lists them all with their state.
  (magit-repository-directories '(("~/Code" . 2) ("~/.dotfiles" . 0)))
  (magit-repolist-columns '(("Name" 25 magit-repolist-column-ident nil)
                            ("Branch" 20 magit-repolist-column-branch nil)
                            ("Dirty" 5 magit-repolist-column-flag nil)
                            ("↓" 3 magit-repolist-column-unpulled-from-upstream ((:right-align t)))
                            ("↑" 3 magit-repolist-column-unpushed-to-upstream ((:right-align t)))
                            ("Path" 40 magit-repolist-column-path nil)))
  :config
  ;; SPC g m: what this branch changed, like diffview merge_base.
  (defun magit-diff-merge-base ()
    "Diff the working tree against the merge base with the main branch."
    (interactive)
    (magit-diff-range (format "%s...HEAD" (or (magit-main-branch) "main")))))

;; forge: GitHub issues and pull requests inside magit. Token comes from
;; ~/.authinfo (machine api.github.com login <user>^forge password <token>).
;; In magit status: ' opens the forge menu; N p creates a PR, N i an issue.
;; SPC g p lists PRs, SPC g i issues, for the repo of the current file.
(use-package forge
  :after magit
  :custom
  (forge-owned-accounts '(("amazingefren"))))

;; diff-hl: changed / added / removed markers in the left fringe (gitsigns).
(use-package diff-hl
  :hook ((magit-pre-refresh  . diff-hl-magit-pre-refresh)   ; keep in sync when
         (magit-post-refresh . diff-hl-magit-post-refresh))  ; magit stages/commits
  :custom
  (diff-hl-show-hunk-function #'diff-hl-show-hunk-inline-popup) ; the diff unfolds under the hunk, in the buffer
  :init
  (global-diff-hl-mode 1)
  :config
  (diff-hl-flydiff-mode 1)      ; update as you type, not only on save
  (require 'diff-hl-show-hunk)  ; the unfold command and its inline popup aren't autoloaded
  (require 'diff-hl-show-hunk-inline)
  (global-diff-hl-show-hunk-mouse-mode 1))  ; click a fringe mark to unfold its diff

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
