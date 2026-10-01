;;; workspaces.el --- project perspectives and tab-bar workspace UI  -*- lexical-binding: t -*-

;; Loaded first so the `let's of `project-find-functions' below bind dynamically.
(require 'project)
(declare-function herdr-workspace-children "herdr")
(declare-function herdr-remember-session "herdr")
(declare-function herdr-ensure-space "herdr")

(use-package perspective
  :demand t
  :hook (persp-killed . (lambda () (remhash (persp-name (persp-curr)) workspace-roots)))
  :custom
  (persp-initial-frame-name "home")        ; laid out by home.el
  (persp-mode-prefix-key (kbd "C-c w"))
  (persp-show-modestring nil)
  (persp-sort 'created)                    ; newest first; `workspace-names' flips it
  (persp-suppress-no-prefix-key-warning t)
  :config
  (persp-mode 1))

;; Menus like forge's stay open across commands and would follow you.
(defun workspace-close-menus ()
  (when (bound-and-true-p transient--prefix)
    (transient--emergency-exit :workspace-switch)))
(add-hook 'persp-before-switch-hook #'workspace-close-menus)

(with-eval-after-load 'consult
  (consult-customize consult-source-buffer :hidden t :default nil)
  (add-to-list 'consult-buffer-sources 'persp-consult-source))

(defvar workspace-order nil
  "Workspace names in the order the tab bar shows them.
New workspaces go at the end, worktrees next to their project; drag a tab,
or SPC TAB < and >, to move one. Home always stays first.")

(defun workspace-names ()
  "Workspace names in tab-bar order: home, then `workspace-order'.
Workspaces not yet in the order are added at the end, oldest first."
  (let* ((live (reverse (persp-names)))
         (order (append (seq-filter (lambda (n) (member n live)) workspace-order)
                        (seq-remove (lambda (n) (member n workspace-order)) live))))
    (setq workspace-order (if (member "home" order) (cons "home" (delete "home" order)) order))))

(defun workspace--project (name)
  "The project part of workspace NAME: \"muiq-web-app\" for \"muiq-web-app@fix\"."
  (car (split-string name "@")))

(defun workspace-move (name to)
  "Move workspace NAME to position TO (0-based) in the tab bar.
Home stays first."
  (let ((names (delete name (copy-sequence (workspace-names)))))
    (unless (equal name "home")
      (setq to (max (if (member "home" names) 1 0) (min to (length names))))
      (setq workspace-order (append (seq-take names to) (list name) (seq-drop names to)))
      (force-mode-line-update t))))

(defcustom workspace-nest-children t
  "Non-nil: the tab bar nests a project's worktrees and sub-workspaces.
Then s-1..9 count projects, and the current project's tab opens up to show
its children (project@name); its s-N again, or s-{ and s-}, moves
between them. nil: every
workspace is its own numbered tab. SPC TAB g toggles."
  :type 'boolean
  :group 'convenience)

(defun workspace--slots ()
  "Top-level tab-bar entries, each a list of workspace names.
Nested, a project and its children share one entry; flat, each is its own."
  (let ((names (workspace-names)))
    (if (not workspace-nest-children)
        (mapcar #'list names)
      (let (slots)
        (dolist (name names)
          (if-let* ((slot (assoc (workspace--project name) slots)))
              (setcdr slot (append (cdr slot) (list name)))
            (push (list (workspace--project name) name) slots)))
        (mapcar #'cdr (nreverse slots))))))

(defun workspace--slot-index (name)
  "Index in `workspace--slots' of the entry holding workspace NAME."
  (seq-position (workspace--slots) name (lambda (slot n) (member n slot))))

(defvar workspace--last-in-project (make-hash-table :test #'equal)
  "Project -> the workspace of that project visited last.")
(add-hook 'persp-switch-hook
          (lambda () (let ((name (persp-current-name)))
                       (puthash (workspace--project name) name workspace--last-in-project))))

(defun workspace--visit-slot (slot)
  "Switch to SLOT's workspace visited last, else its first."
  (let ((last (gethash (workspace--project (car slot)) workspace--last-in-project)))
    (persp-switch (if (member last slot) last (car slot)))))

(defun workspace--move-slot (name by)
  "Move the tab-bar entry holding NAME BY places (left if negative).
The first entry (home) stays put."
  (let* ((slots (workspace--slots))
         (i (workspace--slot-index name))
         (floor (if (member "home" (car slots)) 1 0))
         (slot (nth i slots)))
    (unless (< i floor)
      (let* ((rest (remove slot slots))
             (to (max floor (min (+ i by) (length rest)))))
        (setq workspace-order (apply #'append (append (seq-take rest to) (list slot) (seq-drop rest to))))
        (force-mode-line-update t)))))

(defun workspace-move-left (&optional n)
  "Move the current tab N places left (right if negative).
Nested, the whole project moves with its children."
  (interactive "p")
  (workspace--move-slot (persp-current-name) (- (or n 1))))

(defun workspace-move-right (&optional n)
  "Move the current tab N places right."
  (interactive "p")
  (workspace--move-slot (persp-current-name) (or n 1)))

(defvar-keymap workspace-move-repeat-map
  :doc "After SPC TAB < or >, keep pressing < and > to keep moving."
  :repeat t
  "<" #'workspace-move-left
  ">" #'workspace-move-right)

(defun workspace--place-with-project (name)
  "Move workspace NAME to the end of its project's first run of tabs."
  (let* ((project (workspace--project name))
         (others (remove name (workspace-names)))
         (same (lambda (n) (equal (workspace--project n) project)))
         (i (seq-position others (seq-find same others))))
    (when i
      (while (and (nth (1+ i) others) (funcall same (nth (1+ i) others)))
        (setq i (1+ i)))
      (workspace-move name (1+ i)))))

(defun workspace-next (&optional n)
  "Switch to the tab N places right, wrapping around.
Nested, that is the next project, at the child visited last."
  (interactive "p")
  (let ((slots (workspace--slots)))
    (workspace--visit-slot
     (nth (mod (+ (workspace--slot-index (persp-current-name)) (or n 1)) (length slots)) slots))))

(defun workspace-previous (&optional n)
  "Switch to the tab N places left, wrapping around."
  (interactive "p")
  (workspace-next (- (or n 1))))

(defun workspace-goto (n)
  "Switch to tab N (1-based): a workspace, or nested, a project.
Already in that project, go to its next child instead, wrapping around."
  (when-let* ((slot (nth (1- n) (workspace--slots))))
    (if (and (cdr slot) (member (persp-current-name) slot))
        (workspace-next-child)
      (workspace--visit-slot slot))))

(defun workspace-next-child (&optional n)
  "Switch to the next workspace of the current project, wrapping around."
  (interactive "p")
  (let* ((name (persp-current-name))
         (project (workspace--project name))
         (family (seq-filter (lambda (w) (equal (workspace--project w) project)) (workspace-names))))
    (if (cdr family)
        (persp-switch (nth (mod (+ (seq-position family name) (or n 1)) (length family)) family))
      (message "%s has no worktrees or sub-workspaces (SPC TAB w, SPC TAB s)" project))))

(defun workspace-previous-child (&optional n)
  "Switch to the previous workspace of the current project."
  (interactive "p")
  (workspace-next-child (- (or n 1))))

(defun workspace-toggle-nesting ()
  "Switch the tab bar between nested projects and one tab per workspace."
  (interactive)
  (setq workspace-nest-children (not workspace-nest-children))
  (force-mode-line-update t)
  (message "Workspace bar: %s" (if workspace-nest-children "projects, with children nested" "flat")))

(defun workspace--worktree-p (name)
  "Non-nil when workspace NAME is open on a linked git worktree.
A linked worktree's .git is a file pointing back at the main checkout."
  (when-let* ((root (gethash name workspace-roots)))
    (file-regular-p (expand-file-name ".git" root))))

(defun workspace--base-root (project)
  "PROJECT's main folder: its own workspace's root, else the main git checkout."
  (or (gethash project workspace-roots)
      (let ((root (workspace-root)))
        (condition-case nil (car (car (workspace--worktrees root))) (user-error root)))))

(defun workspace-new-sub (name)
  "Make a sub-workspace of the current project called project@NAME.
It opens on the project's main folder, even from inside a worktree, with its
own layout, buffers, and herdr session."
  (interactive "sSub-workspace name: ")
  (when (string-blank-p name) (user-error "No name given"))
  (let* ((project (workspace--project (persp-current-name)))
         (full (format "%s@%s" project (string-trim name))))
    (when (member full (persp-names)) (user-error "%s already exists" full))
    (workspace-open-project (workspace--base-root project) full)))

(defun workspace--register-in-herdr ()
  "Give the current workspace its herdr space, so it comes back after a restart."
  (when (fboundp 'herdr-ensure-space)
    (condition-case err (herdr-ensure-space)
      (error (message "herdr: %s (the workspace won't come back after a restart)"
                      (error-message-string err))))))

(defvar workspace--renaming nil)
(add-hook 'persp-before-rename-hook (lambda () (setq workspace--renaming (persp-current-name))))
(add-hook 'persp-after-rename-hook
          (lambda ()
            (let ((new (persp-current-name)) (old workspace--renaming))
              (when old
                (setq workspace-order (mapcar (lambda (n) (if (equal n old) new n)) workspace-order))
                (when-let* ((root (gethash old workspace-roots)))
                  (remhash old workspace-roots)
                  (puthash new root workspace-roots))))))

(defvar workspace-status-function nil
  "Function from a workspace name to a status string for its tab, or nil.
herdr-mode sets it to draw the agent counts.")

(defun workspace--tab-item (key label face command help)
  "A tab-bar item for KEY showing LABEL in FACE, running COMMAND on click."
  (let ((label (copy-sequence label)))
    (add-face-text-property 0 (length label) face t label)
    `(,key menu-item ,label ,command :help ,help)))

(defun workspace--status (names)
  "Agent counts for workspace NAMES (a name or a list), with a leading gap."
  (let ((glyph (if workspace-status-function (funcall workspace-status-function names) "")))
    (if (string-blank-p glyph) "" (concat "  " glyph))))

(defun workspace--short (text)
  "TEXT cut to 24 characters for a nested child tab."
  (truncate-string-to-width text 24 nil nil "…"))

(defun workspace--divider (key &optional glyph)
  "A divider, GLYPH or │, in the theme's shadow face.
The tabs' own borders don't show between neighbouring tabs, so this is what
separates them: │ between top-level tabs, a lighter · between children."
  `(,(intern key) menu-item ,(propertize (or glyph "│") 'face '(:inherit (shadow tab-bar))) ignore))

(defun workspace--child-label (child project)
  "Nested tab label for CHILD of PROJECT: base, ⎇ branch, or a sub-workspace's name."
  (if (equal child project) "base"
    (let ((short (workspace--short (substring child (1+ (string-search "@" child))))))
      (if (workspace--worktree-p child) (concat "⎇ " short) short))))

(defun workspace-tab-bar-format ()
  "Tab bar items: one per workspace or, nested, one per project.
Each is numbered and shows its agent counts.  Nested, the current
project's tab opens up into its children; another project's tab shows
how many children it has and counts all of their agents."
  (let ((current (persp-current-name)) (i 0) previous items
        (header 'tab-bar-tab))
    (dolist (slot (workspace--slots))
      (setq i (1+ i))
      (let* ((name (car slot))
             (project (workspace--project name))
             (number (lambda (face) (propertize (format " %d " i) 'face (list 'shadow face)))))
        (cond
         ((and (null (cdr slot)) (or (not workspace-nest-children) (equal name project)))
          (let* ((face (if (equal name current) 'tab-bar-tab 'tab-bar-tab-inactive))
                 (grouped (and previous (string-match-p "@" name)
                               (equal project (workspace--project previous))))
                 (shown (if grouped (substring name (string-search "@" name)) name)))
            (push (workspace--tab-item
                   (intern name)
                   (concat (if grouped (propertize (format "%d " i) 'face (list 'shadow face)) (funcall number face))
                           (propertize shown 'face face) (workspace--status name) " ")
                   face (lambda () (interactive) (persp-switch name))
                   (format "Switch to %s; drag to move" name))
                  items)))
         ((member current slot)
          (push (workspace--tab-item
                 (intern (concat "project:" project))
                 (concat (propertize (format " %d " i) 'face (list 'shadow header))
                         (propertize (concat project " ›") 'face header) " ")
                 header
                 (lambda () (interactive) (workspace-next-child))
                 (format "%s: click or s-%d for the next child, drag to move the project" project i))
                items)
          (dolist (child slot)
            (let ((face (if (equal child current) 'tab-bar-tab 'tab-bar-tab-inactive)))
              (unless (eq child (car slot))
                (push (workspace--divider (concat "sep:" child) "·") items))
              (push (workspace--tab-item
                     (intern child)
                     (concat " "
                             (propertize (workspace--child-label child project) 'face face)
                             (workspace--status child) " ")
                     face (lambda () (interactive) (persp-switch child))
                     (format "Switch to %s" child))
                    items))))
         (t
          (let ((extra (seq-count (lambda (n) (not (equal n project))) slot)))
            (push (workspace--tab-item
                   (intern (concat "project:" project))
                   (concat (funcall number 'tab-bar-tab-inactive)
                           (propertize project 'face 'tab-bar-tab-inactive)
                           (propertize (format " +%d" extra) 'face (list 'shadow 'tab-bar-tab-inactive))
                           (workspace--status slot) " ")
                   'tab-bar-tab-inactive
                   (let ((slot slot)) (lambda () (interactive) (workspace--visit-slot slot)))
                   (format "Switch to %s; drag to move" project))
                  items))))
        (setq previous (car (last slot)))
        (push (workspace--divider (format "gap:%d" i)) items)))
    (nreverse (cdr items))))

;; tab-bar's own mouse commands act on its tabs, which are hidden.
(defun workspace--at (posn)
  "The tab at POSN: (NAME . PROJECT-P), or nil.
NAME is a workspace, or for a nested project tab, its last-visited child."
  (when-let* ((key (car (tab-bar--event-to-item posn)))
              (key (symbol-name key)))
    (if (string-prefix-p "project:" key)
        (when-let* ((slot (nth (workspace--slot-index-of-project (substring key 8)) (workspace--slots))))
          (let ((last (gethash (workspace--project (car slot)) workspace--last-in-project)))
            (cons (if (member last slot) last (car slot)) t)))
      (and (member key (workspace-names)) (cons key nil)))))

(defun workspace--slot-index-of-project (project)
  (seq-position (workspace--slots) project
                (lambda (slot p) (equal (workspace--project (car slot)) p))))

(defun workspace-mouse-move (event)
  "Drag a tab onto another to move it there.
Nested, dragging a project moves it with its children; dragging a child
onto a sibling reorders the children."
  (interactive "e")
  (setq tab-bar--dragging-in-progress nil)
  (let ((from (workspace--at (event-start event)))
        (to (workspace--at (event-end event))))
    (when (and from to (not (equal (car from) (car to))))
      (let ((fi (workspace--slot-index (car from)))
            (ti (workspace--slot-index (car to))))
        (if (and (= fi ti) (not (cdr from)))
            (workspace-move (car from) (seq-position (workspace-names) (car to)))
          (workspace--move-slot (car from) (- ti fi)))))))

(defun workspace-mouse-menu (event)
  "Right-click menu for a workspace tab."
  (interactive "e")
  (when-let* ((at (workspace--at (event-start event)))
              (name (car at)))
    (let ((menu (make-sparse-keymap (propertize name 'hide t))))
      (define-key-after menu [left]
        `(menu-item "Move left" (lambda () (interactive) (workspace--move-slot ,name -1))))
      (define-key-after menu [right]
        `(menu-item "Move right" (lambda () (interactive) (workspace--move-slot ,name 1))))
      (unless workspace-nest-children
        (define-key-after menu [group]
          `(menu-item "Move next to its project" (lambda () (interactive) (workspace--place-with-project ,name)))))
      (define-key-after menu [nest]
        `(menu-item ,(if workspace-nest-children "Show every workspace as a tab" "Nest children under projects")
                    workspace-toggle-nesting))
      (unless (cdr at)
        (define-key-after menu [close]
          `(menu-item ,(format "Close %s" name) (lambda () (interactive) (persp-kill ,name)))))
      (popup-menu menu event))))

(use-package tab-bar
  :ensure nil
  :custom
  (tab-bar-show t)
  (tab-bar-format '(workspace-tab-bar-format))
  :config
  (tab-bar-mode 1)
  (keymap-set tab-bar-map "<drag-mouse-1>" #'workspace-mouse-move)
  (keymap-set tab-bar-map "<down-mouse-3>" #'workspace-mouse-menu)
  (keymap-set tab-bar-map "<mouse-4>" #'workspace-previous)
  (keymap-set tab-bar-map "<mouse-5>" #'workspace-next)
  (keymap-set tab-bar-map "<wheel-up>" #'workspace-previous)
  (keymap-set tab-bar-map "<wheel-down>" #'workspace-next)
  (add-hook 'persp-switch-hook (lambda () (force-mode-line-update t))))

;; evil binds gt/gT to the hidden tab-bar tabs.
(use-package tab-line
  :ensure nil
  :config
  ;; tab-line uses this face only for the shown buffer in the selected window, so
  ;; the split you are in stands out, in the theme's own accent color.
  (custom-set-faces
   '(tab-line-tab-current ((t :inherit (bold font-lock-keyword-face tab-line-tab) :overline t))))
  (global-tab-line-mode 1)
  (with-eval-after-load 'evil
    (evil-define-key 'motion 'global
      "gt" #'tab-line-switch-to-next-tab
      "gT" #'tab-line-switch-to-prev-tab)))

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
    (tree-show-root dir)
    (message "Workspace root: %s" (abbreviate-file-name dir))))

(defun workspace-open-project (dir &optional name)
  "Open DIR in its own perspective, creating it if needed.
The perspective is called NAME, or after DIR's folder.
A project (git repo, or a folder with a .project file) gets the file picker;
a plain folder gets dired. Used by SPC f p and SPC TAB n."
  (interactive (list (project-prompt-project-dir)))
  (let* ((dir (file-name-as-directory (file-truename dir)))
         (name (or name (file-name-nondirectory (directory-file-name dir))))
         (existed (member name (persp-names))))
    (persp-switch name)
    (unless existed
      (puthash name dir workspace-roots)
      (setq default-directory dir)
      ;; Before the file picker, so C-g there still leaves this done.
      (if (string-search "@" name)
          (progn (workspace--place-with-project name)
                 (workspace--register-in-herdr))
        (workspace-restore-children name dir))
      (if (let ((project-find-functions '(project-try-vc))) (project-current nil dir))
          (let ((default-directory dir)) (project-find-file))
        (dired dir)))))

(defun workspace--children-on-disk (project dir)
  "PROJECT's children as (NAME . ROOT): git worktrees, then herdr spaces.
A worktree counts when it sits next to the main checkout, as SPC TAB w
makes them, so tool-made ones elsewhere (e.g. inside the repo) stay out.
A herdr space counts when it is labelled PROJECT@NAME and its folder exists."
  (let (children)
    (when (let ((project-find-functions '(project-try-vc))) (project-current nil dir))
      (let* ((trees (ignore-errors (workspace--worktrees dir)))
             (parent (file-name-directory (directory-file-name (car (car trees))))))
        (pcase-dolist (`(,path . ,branch) (cdr trees))
          (when (and branch (file-equal-p (file-name-directory (directory-file-name path)) parent))
            (push (cons (format "%s@%s" project branch) path) children)))))
    (when (fboundp 'herdr-workspace-children)
      (pcase-dolist (`(,label ,cwd ,session) (herdr-workspace-children project))
        (when (and (file-directory-p cwd) (not (assoc label children)))
          (push (cons label (file-name-as-directory cwd)) children)
          (herdr-remember-session label session))))
    (nreverse children)))

(defun workspace-restore-children (project &optional dir)
  "Open PROJECT's worktrees and sub-workspaces that aren't open yet.
DIR is PROJECT's folder, by default its workspace root. They open in the
background, right after PROJECT in the tab bar. Runs by itself when a
project is opened; run it by hand to pick up ones made elsewhere."
  (interactive (list (workspace--project (persp-current-name))))
  (let* ((dir (or dir (gethash project workspace-roots) (workspace-root)))
         (new (seq-remove (lambda (child) (member (car child) (persp-names)))
                          (workspace--children-on-disk project dir))))
    (pcase-dolist (`(,name . ,root) new)
      (persp-new name)
      (puthash name root workspace-roots)
      (when-let* ((scratch (get-buffer (persp-scratch-buffer name))))
        (with-current-buffer scratch (setq default-directory root)))
      (workspace--place-with-project name))
    (when new
      (force-mode-line-update t)
      (message "Opened %s: %s" (if (cdr new) (format "%d children" (length new)) "1 child")
               (mapconcat (lambda (c) (substring (car c) (1+ (string-search "@" (car c))))) new ", ")))
    new))

(defun workspace--git (dir &rest args)
  "Run git ARGS in DIR and return its output lines, or signal its error."
  (let ((default-directory dir))
    (with-temp-buffer
      (unless (zerop (apply #'process-file "git" nil t nil args))
        (user-error "git %s: %s" (string-join args " ") (string-trim (buffer-string))))
      (split-string (buffer-string) "\n" t))))

(defun workspace--worktrees (dir)
  "Worktrees of DIR's repo as (PATH . BRANCH), the main checkout first.
BRANCH is nil for a detached checkout."
  (let (trees)
    (dolist (line (workspace--git dir "worktree" "list" "--porcelain"))
      (cond ((string-prefix-p "worktree " line)
             (push (list (file-name-as-directory (substring line 9))) trees))
            ((string-prefix-p "branch refs/heads/" line)
             (setcdr (car trees) (substring line 18)))))
    (nreverse trees)))

(defun workspace--branches (dir)
  "Branch names in DIR's repo: local ones, then remote ones without the remote."
  (delete-dups
   (append (workspace--git dir "for-each-ref" "--format=%(refname:short)" "refs/heads")
           (seq-remove (lambda (b) (equal b "HEAD"))
                       (workspace--git dir "for-each-ref" "--format=%(refname:lstrip=3)" "refs/remotes")))))

(defun workspace-worktree (branch)
  "Open BRANCH's git worktree as its own workspace, creating it if needed.
Pick a branch that has a worktree, any local or remote branch, or type a
new name; a new branch starts from the main checkout's current commit."
  (interactive
   (let* ((trees (workspace--worktrees (workspace-root)))
          (main-branch (cdr (car trees)))
          (open (delq nil (mapcar #'cdr (cdr trees)))))
     (list (completing-read "Worktree branch (new name creates it): "
                            (remove main-branch (delete-dups (append open (workspace--branches (car (car trees))))))))))
  (when (string-blank-p branch) (user-error "No branch given"))
  (let* ((trees (workspace--worktrees (workspace-root)))
         (main (car (car trees)))
         (project (file-name-nondirectory (directory-file-name main)))
         (path (car (rassoc branch trees))))
    (when (equal path main)
      (user-error "%s is checked out in the main checkout; use SPC TAB n" branch))
    (unless path
      (setq path (file-name-as-directory
                  (expand-file-name (format "%s-%s" project (replace-regexp-in-string "[^A-Za-z0-9_.-]" "-" branch))
                                    (file-name-directory (directory-file-name main)))))
      (if (member branch (workspace--branches main))
          (workspace--git main "worktree" "add" path branch)
        (workspace--git main "worktree" "add" "-b" branch path))
      (message "Created worktree %s" (abbreviate-file-name path)))
    (let ((name (format "%s@%s" project branch)))
      (if (member name (persp-names))
          (persp-switch name)
        (workspace-open-project path name)))))

(defun workspace-remove-child ()
  "Remove the current worktree or sub-workspace, and stop its agents.
A worktree's checkout is removed too (its branch is kept); git refuses
while it has uncommitted changes. A sub-workspace only closes."
  (interactive)
  (let ((name (persp-current-name)))
    (unless (string-search "@" name)
      (user-error "%s is a project, not a worktree or sub-workspace; SPC TAB d closes it" name))
    (if (workspace--worktree-p name)
        (workspace--remove-worktree name)
      (when (yes-or-no-p (format "Close sub-workspace %s and stop its agents? " name))
        (when (fboundp 'herdr-delete-workspace-session)
          (herdr-delete-workspace-session name))
        (persp-kill name)
        (message "Closed %s" name)))))

(defun workspace--remove-worktree (name)
  "Remove workspace NAME's git worktree, its herdr session, and the workspace."
  (let* ((root (gethash name workspace-roots))
         (trees (workspace--worktrees root))
         (tree (seq-find (lambda (tree) (file-equal-p (car tree) root)) trees)))
    (unless (and tree (not (eq tree (car trees))))
      (user-error "%s is not a linked worktree" name))
    ;; Check git first, so a dirty worktree leaves everything as it was.
    (when (workspace--git (car tree) "status" "--porcelain")
      (user-error "%s has uncommitted changes; commit or stash them first" name))
    (when (yes-or-no-p (format "Remove worktree %s, close %s, and stop its agents? "
                               (abbreviate-file-name (car tree)) name))
      (let ((main (car (car trees))))
        (when (fboundp 'herdr-delete-workspace-session)
          (herdr-delete-workspace-session name))
        (persp-kill name)
        (workspace--git main "worktree" "remove" (car tree))
        (message "Removed worktree %s (branch %s kept)" (abbreviate-file-name (car tree)) (cdr tree))))))

(dotimes (n 9)
  (let ((i (1+ n)))
    (global-set-key (kbd (format "s-%d" i)) (lambda () (interactive) (workspace-goto i)))))
(global-set-key (kbd "s-[") #'workspace-previous)
(global-set-key (kbd "s-]") #'workspace-next)
(global-set-key (kbd "s-{") #'workspace-previous-child)
(global-set-key (kbd "s-}") #'workspace-next-child)

(leader
  "TAB"     '(:ignore t :wk "workspace")
  "TAB TAB" '(persp-switch :wk "switch")
  "TAB l"   '(persp-switch-last :wk "last")
  "TAB n"   '(workspace-open-project :wk "open project/folder")
  "TAB w"   '(workspace-worktree :wk "open/create worktree")
  "TAB W"   '(workspace-remove-child :wk "remove worktree/sub-workspace")
  "TAB s"   '(workspace-new-sub :wk "new sub-workspace")
  "TAB g"   '(workspace-toggle-nesting :wk "toggle nested/flat bar")
  "TAB <"   '(workspace-move-left :wk "move tab left")
  "TAB >"   '(workspace-move-right :wk "move tab right")
  "TAB d"   '(persp-kill :wk "close")
  "TAB r"   '(persp-rename :wk "rename")
  "TAB c"   '(workspace-set-root :wk "change root (cd)")
  "TAB b"   '(persp-remove-buffer :wk "remove buffer from workspace")
  "TAB a"   '(persp-add-buffer :wk "add buffer to workspace")
  "fp"      '(workspace-open-project :wk "project"))
