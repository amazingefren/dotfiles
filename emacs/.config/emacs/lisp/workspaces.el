;;; workspaces.el --- project perspectives and tab-bar workspace UI  -*- lexical-binding: t -*-

(use-package perspective
  :demand t
  :hook (persp-killed . (lambda () (remhash (persp-name (persp-curr)) workspace-roots)))
  :custom
  (persp-initial-frame-name "home")        ; the perspective Emacs starts in (laid out by home.el)
  (persp-mode-prefix-key (kbd "C-c w"))    ; its own key prefix; we use SPC TAB instead
  (persp-show-modestring nil)              ; the tab bar shows perspectives, not the modeline
  (persp-sort 'created)                    ; creation order (newest first; `workspace-names' flips it)
  (persp-suppress-no-prefix-key-warning t)
  :config
  (persp-mode 1))

;; Show the current perspective's buffers in SPC b b. Press b then SPC in the
;; picker to see every buffer instead.
(with-eval-after-load 'consult
  (consult-customize consult-source-buffer :hidden t :default nil)
  (add-to-list 'consult-buffer-sources 'persp-consult-source))

;;; Tab bar: perspectives + agent status --------------------------------------

(defun workspace-names ()
  "Perspective names, oldest first, so home is 1 and numbers never shift."
  (reverse (persp-names)))

(defvar workspace-status-function nil
  "Function from a workspace name to a status string for its tab, or nil.
herdr-mode sets it to draw the agent counts.")

(defun workspace-tab-bar-format ()
  "Tab bar items: one per perspective, numbered, with the agent counts."
  (let ((i 0))
    (mapcar
     (lambda (name)
       (setq i (1+ i))
       (let* ((current (equal name (persp-current-name)))
              (face (if current 'tab-bar-tab 'tab-bar-tab-inactive))
              (glyph (if workspace-status-function (funcall workspace-status-function name) "")))
         ;; " 2 measuringu-utils ●1 ◆1 ": dim number, name, then the agent
         ;; counts after it so the number never reads as part of the status.
         `(,(intern name) menu-item
           ,(let ((label (concat (propertize (format " %d " i) 'face (list 'shadow face))
                                 (propertize name 'face face)
                                 (if (string-blank-p glyph) "" (concat "  " glyph))
                                 (propertize " " 'face face))))
              ;; Paint the tab background under the whole label, counts included,
              ;; so it reads as one pill; the count colors stay on top.
              (add-face-text-property 0 (length label) face t label)
              label)
           ,(lambda () (interactive) (persp-switch name))
           :help ,(format "Switch to %s" name))))
     (workspace-names))))

(use-package tab-bar
  :ensure nil
  :custom
  (tab-bar-show t)
  (tab-bar-format '(workspace-tab-bar-format))   ; the bar is drawn entirely from perspectives
  :config
  (tab-bar-mode 1)
  (add-hook 'persp-switch-hook (lambda () (force-mode-line-update t))))

;;; Workspace root

(defvar workspace-roots (make-hash-table :test #'equal)
  "Perspective name -> the folder it was opened on.")

(defun workspace-root ()
  "Root directory of the current workspace.
The folder it was opened on; else the project root; else the buffer's directory."
  (or (gethash (persp-current-name) workspace-roots)
      (when-let* ((project (project-current))) (project-root project))
      default-directory))

(defun workspace-set-root (dir)
  "Change the current workspace's root to DIR, like cd for the whole workspace.
SPC f f, SPC f g, new shells, agent sessions, and the tree follow it."
  (interactive (list (read-directory-name "Workspace root: " (workspace-root) nil t)))
  (let ((dir (file-name-as-directory (file-truename dir))))
    (puthash (persp-current-name) dir workspace-roots)
    (setq default-directory dir)
    (when (and (fboundp 'treemacs-current-visibility) (eq (treemacs-current-visibility) 'visible))
      (save-selected-window (tree-show-root dir)))
    (message "Workspace root: %s" (abbreviate-file-name dir))))

;;; Open a project (or any folder) in its own perspective -------------------

(defun workspace-open-project (dir)
  "Open DIR in its own perspective, creating it if needed.
A project (git repo, or a folder with a .project file) gets the file picker;
a plain folder gets dired. Used by SPC f p and SPC TAB n."
  (interactive (list (project-prompt-project-dir)))
  (let* ((dir (file-name-as-directory (file-truename dir)))   ; resolve symlinks, like find-file does
         (name (file-name-nondirectory (directory-file-name dir)))
         (existed (member name (persp-names))))
    (persp-switch name)
    (unless existed
      (puthash name dir workspace-roots)   ; remembered for `workspace-root'
      (setq default-directory dir)         ; the perspective's scratch buffer starts here
      (if (let ((project-find-functions '(project-try-vc))) (project-current nil dir))
          (let ((default-directory dir)) (project-find-file))
        (dired dir)))))

;;; Keybindings

;; s-1 .. s-9 jump straight to a perspective; s-[ s-] cycle.
(dotimes (n 9)
  (let ((i (1+ n)))
    (global-set-key (kbd (format "s-%d" i))
                    (lambda () (interactive)
                      (when-let* ((name (nth (1- i) (workspace-names))))
                        (persp-switch name))))))
(global-set-key (kbd "s-[") #'persp-prev)
(global-set-key (kbd "s-]") #'persp-next)

(leader
  "TAB"     '(:ignore t :wk "workspace")
  "TAB TAB" '(persp-switch :wk "switch")
  "TAB l"   '(persp-switch-last :wk "last")
  "TAB n"   '(workspace-open-project :wk "open project/folder")
  "TAB d"   '(persp-kill :wk "close")
  "TAB r"   '(persp-rename :wk "rename")
  "TAB c"   '(workspace-set-root :wk "change root (cd)")
  "TAB b"   '(persp-remove-buffer :wk "remove buffer from workspace")
  "TAB a"   '(persp-add-buffer :wk "add buffer to workspace")
  "fp"      '(workspace-open-project :wk "project"))
