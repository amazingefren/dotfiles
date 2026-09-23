;;; tree.el --- file tree sidebar and file manager  -*- lexical-binding: t -*-

;; Dirvish is dired with icons, git status and previews. It replaces dired
;; everywhere (SPC o o, C-x d, RET on a folder), so every dired key still
;; works, and its side window is the workspace file tree.
;; Icons need the Symbols Nerd Font (brew install --cask font-symbols-only-nerd-font).
(use-package nerd-icons)

(use-package dirvish
  :demand t
  :custom
  (dirvish-attributes '(nerd-icons subtree-state vc-state file-size file-time))
  (dirvish-side-attributes '(nerd-icons subtree-state vc-state))
  (dirvish-side-width 32)
  (insert-directory-program "gls")          ; GNU ls (brew coreutils): macOS ls can't group dirs
  (dired-listing-switches "-alh --group-directories-first")
  (dirvish-quick-access-entries
   '(("h" "~/"          "Home")
     ("d" "~/Downloads/" "Downloads")
     ("o" "~/org/"       "Org")
     ("c" "~/Code/"      "Code")
     ("." "~/.dotfiles/" "Dotfiles")))
  :config
  ;; The GNU ELPA package keeps its extensions in a subfolder, off load-path
  ;; and without autoloads: add the folder and load them all, since the ?
  ;; menu (dirvish-dispatch) links to commands across every extension.
  (let ((ext (expand-file-name "extensions" (file-name-directory (locate-library "dirvish")))))
    (add-to-list 'load-path ext)
    (dolist (file (directory-files ext nil "\\.el\\'"))
      (require (intern (file-name-base file)))))
  (require 'dirvish-extras)
  (require 'dirvish-fd)
  ;; The ? menu names dirvish-fd-jump, which this version doesn't define.
  (unless (fboundp 'dirvish-fd-jump) (defalias 'dirvish-fd-jump #'dirvish-fd))
  (dirvish-override-dired-mode 1)
  (dirvish-side-follow-mode 1)              ; highlight the file you're editing
  (evil-define-key 'normal dirvish-mode-map
    (kbd "TAB") #'dirvish-subtree-toggle    ; expand a folder in place, like a tree
    "q"         #'dirvish-quit
    "a"         #'dirvish-quick-access      ; jump to Home, Downloads, Org...
    "?"         #'dirvish-dispatch          ; menu of everything dirvish can do
    "s"         #'dirvish-quicksort
    "P"         #'dirvish-layout-toggle))   ; full-screen with preview pane

(defun tree-toggle ()
  "Toggle the file tree at the workspace root.
If it is visible but not focused, focus it; if focused, close it."
  (interactive)
  (dirvish-side (and (not (dirvish-side--session-visible-p)) (workspace-root))))

(defun tree-show-root (root)
  "Show ROOT in the file tree, if the tree is visible."
  (when-let* ((win (dirvish-side--session-visible-p)))
    (with-selected-window win
      (dirvish--find-entry 'find-alternate-file root))))

;;; Keybindings

(leader
  "e" '(tree-toggle :wk "tree")
  "E" '(dirvish :wk "file manager"))
