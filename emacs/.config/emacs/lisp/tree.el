;;; tree.el --- file tree sidebar and file manager  -*- lexical-binding: t -*-

;; The nongnu build keeps extensions in a subfolder off load-path; MELPA's doesn't.
(use-package dirvish
  :pin melpa
  :demand t
  :custom
  (dired-listing-switches "-Al")
  (dirvish-attributes '(nerd-icons subtree-state tree-vc-state file-size))
  (dirvish-side-attributes '(nerd-icons subtree-state tree-vc-state))
  (dirvish-side-window-parameters '((no-delete-other-windows . t)))
  :config
  (require 'dirvish-vc)                     ; collects git state; loads only for its own attributes
  (add-hook 'dirvish-find-entry-hook #'tree--display-file)
  (dirvish-override-dired-mode 1)
  (dirvish-side-follow-mode 1)
  (with-eval-after-load 'evil
    (evil-define-key 'normal dirvish-mode-map
      (kbd "TAB") #'dirvish-subtree-toggle
      "q"         #'dirvish-quit
      "<"         #'tree-up
      ">"         #'tree-down
      "?"         #'dirvish-dispatch)))

(dirvish-define-attribute tree-vc-state
  "The version control state as the file name's color."
  :when (and (symbolp (dirvish-prop :vc-backend)) (not (dirvish-prop :remote)))
  (let ((ov (make-overlay f-beg f-end)))
    (when-let* ((state (dirvish-attribute-cache f-name :vc-state))
                (face (alist-get state dirvish-vc-state-face-alist)))
      (overlay-put ov 'face face))
    `(ov . ,ov)))

(defvar tree--trail nil
  "Deepest directory `tree-up' left, for `tree-down' to return to.")

(defun tree-down ()
  "Show the next directory down toward the one `tree-up' left.
Without such a directory below this one, show the directory at point.
Signals a `user-error' when point is not on a directory."
  (interactive)
  (let ((here default-directory))
    (if (and tree--trail
             (file-in-directory-p tree--trail here)
             (not (file-equal-p tree--trail here)))
        (let ((next-step (car (split-string (file-relative-name tree--trail here) "/"))))
          (dired-goto-file (expand-file-name next-step here))
          (dired-find-file))
      (unless (file-directory-p (dired-get-filename nil t))
        (user-error "Not on a directory"))
      (dired-find-file))))

(defun tree-show-root (root)
  "Show ROOT in the file tree when the tree is visible."
  (when-let* ((win (dirvish-side--session-visible-p)))
    (with-selected-window win
      (dirvish--find-entry 'find-alternate-file root))))

(defun tree-toggle ()
  "Toggle the file tree, opening it at the workspace root.
Focuses the tree when it is visible but not selected; closes it when selected."
  (interactive)
  (dirvish-side (workspace-root)))

(defun tree-up ()
  "Show the parent directory, remembering this one for `tree-down'."
  (interactive)
  (unless (and tree--trail (file-in-directory-p tree--trail default-directory))
    (setq tree--trail default-directory))
  (dired-up-directory))

(defun tree--display-file (entry find-fn)
  "Show file ENTRY from the tree in the window `display-buffer' picks.
Handles only files FIND-FN would open in the tree's own window.
Returns the file's buffer, or nil to leave ENTRY to dirvish."
  (when-let* ((session (dirvish-curr))
              ((eq (dv-type session) 'side))
              ((memq find-fn '(find-file find-alternate-file)))
              ((not (file-directory-p entry))))
    (pop-to-buffer (find-file-noselect entry))))

(leader
  "e" '(tree-toggle :wk "tree")
  "E" '(dirvish :wk "file manager"))
