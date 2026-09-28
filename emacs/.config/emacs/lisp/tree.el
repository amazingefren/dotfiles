;;; tree.el --- file tree sidebar  -*- lexical-binding: t -*-

(use-package treemacs
  :commands (treemacs treemacs-select-window treemacs-find-file)
  :custom
  (treemacs-width 32)
  (treemacs-is-never-other-window nil)
  (treemacs-follow-after-init t)
  (treemacs-indentation 1)
  (treemacs-show-hidden-files t)
  (treemacs-git-mode 'simple)               ; not 'deferred: it throws timer errors when the tree is re-rooted
  (treemacs-collapse-dirs 3)
  :config
  (treemacs-follow-mode 1)
  (treemacs-filewatch-mode 1)
  ;; No project-follow-mode: it re-roots the tree to the git root on every buffer switch.
  (treemacs-fringe-indicator-mode 'always))

(use-package treemacs-evil
  :after (treemacs evil))

(use-package treemacs-perspective
  :after (treemacs perspective)
  :config
  (treemacs-set-scope-type 'Perspectives))

(use-package treemacs-magit
  :after (treemacs magit))

(defun tree-toggle ()
  "Toggle the file tree. If it is visible but not focused, focus it."
  (interactive)
  (require 'treemacs)   ; only the entry commands autoload; the helpers below don't
  (pcase (treemacs-current-visibility)
    ('visible (if (eq (selected-window) (treemacs-get-local-window))
                  (delete-window (treemacs-get-local-window))
                (treemacs-select-window)))
    (_ (tree-show-root (workspace-root)))))

(defun tree-show-root (root)
  "Make ROOT the only project in this workspace's tree and show it."
  (let* ((root (directory-file-name (file-truename root)))   ; treemacs stores resolved paths
         (name (file-name-nondirectory root)))
    (treemacs-select-window)   ; creates the tree buffer (and its workspace) if needed
    (dolist (p (treemacs-workspace->projects (treemacs-current-workspace)))
      (unless (string= (treemacs-project->path p) root)
        (treemacs-do-remove-project-from-workspace p 'ignore-last-project-restriction)))
    (unless (treemacs-workspace->projects (treemacs-current-workspace))
      (treemacs-do-add-project-to-workspace root name))))

(leader
  "e" '(tree-toggle :wk "tree")
  "E" '(treemacs-find-file :wk "reveal file in tree"))
