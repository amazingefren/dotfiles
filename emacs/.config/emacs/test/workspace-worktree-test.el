;;; workspace-worktree-test.el --- git worktrees as workspaces  -*- lexical-binding: t -*-

;; Run: emacs -batch -l test/workspace-worktree-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(require 'package)
(setq package-user-dir (expand-file-name "emacs/elpa/" (xdg-data-home)))  ; as early-init.el
(package-initialize)
(require 'perspective)
(defmacro leader (&rest _) nil)          ; keybinds come from vim.el; not needed here
(defvar workspace-worktree-test--dir
  (file-name-directory (or load-file-name buffer-file-name)))
(load-file (expand-file-name "../lisp/workspaces.el" workspace-worktree-test--dir))

(defun workspace-worktree-test--git (dir &rest args)
  (let ((default-directory dir))
    (unless (zerop (apply #'call-process "git" nil nil nil args))
      (error "git %S failed" args))))

(defmacro workspace-worktree-test--with-repo (&rest body)
  "Run BODY with `main' bound to a fresh repo's checkout, inside a scratch parent.
Opening, closing, and herdr are recorded in `opened', `killed', `herdr'."
  (declare (indent 0))
  `(let* ((parent (file-name-as-directory (file-truename (make-temp-file "wt-test" t))))
          (main (file-name-as-directory (expand-file-name "proj" parent)))
          opened killed herdr)
     (unwind-protect
         (progn
           (make-directory main)
           (workspace-worktree-test--git main "init" "-q" "-b" "main")
           (workspace-worktree-test--git main "-c" "user.name=t" "-c" "user.email=t@t"
                                         "commit" "-q" "--allow-empty" "-m" "init")
           (cl-letf (((symbol-function 'workspace-root) (lambda () main))
                     ((symbol-function 'workspace-open-project)
                      (lambda (dir name) (push (cons dir name) opened)))
                     ((symbol-function 'persp-kill) (lambda (name) (push name killed)))
                     ((symbol-function 'persp-names) (lambda () (mapcar #'cdr opened)))
                     ((symbol-function 'persp-switch) #'ignore)
                     ((symbol-function 'workspace--place-with-project) #'ignore)
                     ((symbol-function 'herdr-delete-workspace-session)
                      (lambda (name) (push name herdr)))
                     ((symbol-function 'yes-or-no-p) (lambda (_) t)))
             ,@body))
       (delete-directory parent t))))

(ert-deftest workspace-worktree-new-branch ()
  (workspace-worktree-test--with-repo
    (workspace-worktree "export")
    (let ((path (file-name-as-directory (expand-file-name "proj-export" parent))))
      (should (file-directory-p path))
      (should (equal (cdr (assoc path (workspace--worktrees main))) "export"))
      (should (equal opened `((,path . "proj@export")))))))

(ert-deftest workspace-worktree-existing-branch-with-slash ()
  (workspace-worktree-test--with-repo
    (workspace-worktree-test--git main "branch" "feature/x")
    (should (member "feature/x" (workspace--branches main)))
    (workspace-worktree "feature/x")
    (let ((path (file-name-as-directory (expand-file-name "proj-feature-x" parent))))
      (should (equal (cdr (assoc path (workspace--worktrees main))) "feature/x"))
      (should (equal (cdar opened) "proj@feature/x")))))

(ert-deftest workspace-worktree-reopens-existing ()
  (workspace-worktree-test--with-repo
    (workspace-worktree "export")
    (workspace-worktree "export")
    (should (= (length (workspace--worktrees main)) 2))
    (should (= (length opened) 1))))

(ert-deftest workspace-worktree-refuses-main-branch ()
  (workspace-worktree-test--with-repo
    (should-error (workspace-worktree "main") :type 'user-error)
    (should-not opened)))

(ert-deftest workspace-worktree-remove-clean-and-dirty ()
  (workspace-worktree-test--with-repo
    (workspace-worktree "export")
    (let ((path (car (car opened)))
          (workspace-roots (make-hash-table :test #'equal)))
      (puthash "proj@export" path workspace-roots)
      (cl-letf (((symbol-function 'workspace-root) (lambda () path))
                ((symbol-function 'persp-current-name) (lambda () "proj@export")))
        ;; Dirty: nothing is touched.
        (with-temp-file (expand-file-name "new.txt" path) (insert "x"))
        (should-error (workspace-remove-child) :type 'user-error)
        (should (file-directory-p path))
        (should-not (or killed herdr))
        ;; Clean: worktree, workspace, and herdr session go; the branch stays.
        (delete-file (expand-file-name "new.txt" path))
        (workspace-remove-child)
        (should-not (file-directory-p path))
        (should (equal killed '("proj@export")))
        (should (equal herdr '("proj@export")))
        (should (member "export" (workspace--branches main)))))))

(ert-deftest workspace-worktree-remove-refuses-main ()
  (workspace-worktree-test--with-repo
    (cl-letf (((symbol-function 'persp-current-name) (lambda () "proj")))
      (should-error (workspace-remove-child) :type 'user-error))))

;;; Tab-bar order

(defun workspace-order-test--labels ()
  "Tab labels, without the gaps between top-level tabs."
  (seq-difference (mapcar (lambda (item) (string-trim (substring-no-properties (nth 2 item))))
                     (workspace-tab-bar-format))
                  '("│" "·")))


(defmacro workspace-order-test--with (names &rest body)
  "Run BODY with live workspaces NAMES (oldest first) and a fresh order."
  (declare (indent 1))
  `(let ((workspace-order nil) (current (car ,names))
         (workspace--last-in-project (make-hash-table :test #'equal)))
     (cl-letf (((symbol-function 'persp-names) (lambda () (reverse ,names)))
               ((symbol-function 'persp-current-name) (lambda () current))
               ((symbol-function 'persp-switch) (lambda (n) (setq current n)))
               ((symbol-function 'force-mode-line-update) #'ignore))
       ,@body)))

(ert-deftest workspace-order-defaults-to-creation ()
  (workspace-order-test--with '("home" "a" "b")
    (should (equal (workspace-names) '("home" "a" "b")))))

(ert-deftest workspace-order-move-keeps-home-first ()
  (workspace-order-test--with '("home" "a" "b" "c")
    (workspace-move "c" 1)
    (should (equal (workspace-names) '("home" "c" "a" "b")))
    (workspace-move "a" 0)                       ; can't pass home
    (should (equal (workspace-names) '("home" "a" "c" "b")))
    (workspace-move "home" 3)                    ; home doesn't move
    (should (equal (car (workspace-names)) "home"))
    (setq current "b")
    (workspace-move-left 2)
    (should (equal (workspace-names) '("home" "b" "a" "c")))
    (workspace-move-right)
    (should (equal (workspace-names) '("home" "a" "b" "c")))))

(ert-deftest workspace-order-worktree-joins-its-project ()
  (workspace-order-test--with '("home" "web" "api" "web@fix" "web@spike")
    (workspace--place-with-project "web@fix")
    (should (equal (workspace-names) '("home" "web" "web@fix" "api" "web@spike")))
    (workspace--place-with-project "web@spike")
    (should (equal (workspace-names) '("home" "web" "web@fix" "web@spike" "api")))))

(ert-deftest workspace-order-new-and-closed-workspaces ()
  (let ((live '("home" "a" "b")))
    (workspace-order-test--with live
      (workspace-move "b" 1)
      (setq live '("home" "a" "b" "new"))            ; opened
      (should (equal (workspace-names) '("home" "b" "a" "new")))
      (setq live '("home" "a" "new"))                ; b closed
      (should (equal (workspace-names) '("home" "a" "new"))))))

(ert-deftest workspace-tab-bar-groups-worktree-labels ()
  (workspace-order-test--with '("home" "web" "web@fix" "api" "api@x" "web@far")
    (let* ((workspace-status-function nil)
           (workspace-nest-children nil)
           (labels (workspace-order-test--labels)))
      (should (equal labels
                     '("1 home" "2 web" "3 @fix" "4 api" "5 @x" "6 web@far"))))))

;;; Nested tab bar

(ert-deftest workspace-nested-groups-and-expands-current ()
  (workspace-order-test--with '("home" "web" "api" "web@fix" "web@spike")
    (let ((workspace-nest-children t)
          (workspace-roots (make-hash-table :test #'equal))
          (tree (make-temp-file "wt" t)))
      ;; web@fix is on a linked worktree (.git is a file); web@spike is not.
      (with-temp-file (expand-file-name ".git" tree) (insert "gitdir: elsewhere\n"))
      (puthash "web@fix" tree workspace-roots)
      (puthash "web@spike" (make-temp-file "sub" t) workspace-roots)
      (let ((workspace-status-function (lambda (names) (format "n%d" (length (ensure-list names))))))
      (should (equal (workspace--slots) '(("home") ("web" "web@fix" "web@spike") ("api"))))
      ;; Elsewhere: web is collapsed, with its child count and all agents.
      (should (equal (workspace-order-test--labels)
                     '("1 home  n1" "2 web +2  n3" "3 api  n1")))
      ;; In web: its tab opens up into its children.
      (setq current "web@fix")
      (should (equal (workspace-order-test--labels)
                     '("1 home  n1" "2 web ›" "base  n1" "⎇ fix  n1" "spike  n1" "3 api  n1")))))))

(ert-deftest workspace-nested-navigation ()
  (workspace-order-test--with '("home" "web" "api" "web@fix")
    (let ((workspace-nest-children t))
      (workspace-goto 2)
      (should (equal current "web"))
      (workspace-next-child)
      (should (equal current "web@fix"))
      (puthash "web" "web@fix" workspace--last-in-project)
      (workspace-goto 3)
      (should (equal current "api"))
      (workspace-goto 2)                          ; back to the child used last
      (should (equal current "web@fix"))
      (workspace-goto 2)                          ; again: cycles web's children
      (should (equal current "web"))
      (workspace-goto 2)
      (should (equal current "web@fix"))
      (workspace-next)
      (should (equal current "api"))
      (workspace-next)                            ; wraps to home
      (should (equal current "home")))))

(ert-deftest workspace-nested-move-carries-children ()
  (workspace-order-test--with '("home" "web" "api" "web@fix")
    (let ((workspace-nest-children t))
      (setq current "web@fix")
      (workspace-move-right)
      (should (equal (workspace-names) '("home" "api" "web" "web@fix")))
      (workspace-move-left 5)                     ; stops after home
      (should (equal (workspace-names) '("home" "web" "web@fix" "api"))))))

(ert-deftest workspace-flat-toggle-keeps-order ()
  (workspace-order-test--with '("home" "web" "api" "web@fix")
    (let ((workspace-nest-children t))
      (workspace-toggle-nesting)
      (should (equal (workspace--slots) '(("home") ("web") ("api") ("web@fix"))))
      (workspace-goto 4)
      (should (equal current "web@fix")))))

(ert-deftest workspace-sub-uses-main-folder-and-closes ()
  (workspace-worktree-test--with-repo
    (workspace-worktree "export")
    (let ((tree (car (car opened)))
          (workspace-roots (make-hash-table :test #'equal)))
      (puthash "proj@export" tree workspace-roots)
      ;; From inside the worktree, a sub-workspace still opens on the main folder.
      (cl-letf (((symbol-function 'workspace-root) (lambda () tree))
                ((symbol-function 'persp-current-name) (lambda () "proj@export")))
        (workspace-new-sub "notes"))
      (should (equal (car opened) (cons main "proj@notes")))
      ;; SPC TAB W on it closes it and its herdr session, and touches no git.
      (puthash "proj@notes" main workspace-roots)
      (cl-letf (((symbol-function 'persp-current-name) (lambda () "proj@notes")))
        (workspace-remove-child))
      (should (equal killed '("proj@notes")))
      (should (equal herdr '("proj@notes")))
      (should (file-directory-p tree))
      ;; A project itself is refused.
      (cl-letf (((symbol-function 'persp-current-name) (lambda () "proj")))
        (should-error (workspace-remove-child) :type 'user-error)))))

;;; Restoring a project's children

(ert-deftest workspace-restore-finds-worktrees-and-herdr-spaces ()
  (workspace-worktree-test--with-repo
    (workspace-worktree "export")                    ; ../proj-export: comes back
    (workspace-worktree-test--git main "worktree" "add" "-q" "-b" "tool"
                                  (expand-file-name ".claude/wt/tool" main)) ; inside the repo: stays out
    (let ((sub (make-temp-file "sub" t)) remembered)
      (cl-letf (((symbol-function 'herdr-workspace-children)
                 (lambda (project)
                   (should (equal project "proj"))
                   `(("proj@notes" ,sub "proj-notes")
                     ("proj@export" ,(car (car opened)) "proj-export")  ; also a worktree: once
                     ("proj@gone" "/nonexistent/folder" "proj-gone"))))
                ((symbol-function 'herdr-remember-session)
                 (lambda (ws session) (push (cons ws session) remembered))))
        (should (equal (mapcar #'car (workspace--children-on-disk "proj" main))
                       '("proj@export" "proj@notes")))
        (should (equal remembered '(("proj@notes" . "proj-notes"))))))))

(ert-deftest workspace-restore-opens-in-background ()
  (let ((workspace-roots (make-hash-table :test #'equal))
        made placed)
    (cl-letf (((symbol-function 'workspace--children-on-disk)
               (lambda (_p _d) '(("web@fix" . "/tmp/web-fix/") ("web@open" . "/tmp/web/"))))
              ((symbol-function 'persp-names) (lambda () '("web@open" "web")))
              ((symbol-function 'persp-new) (lambda (n) (push n made)))
              ((symbol-function 'persp-switch) (lambda (_) (error "Must not switch")))
              ((symbol-function 'workspace--place-with-project) (lambda (n) (push n placed)))
              ((symbol-function 'force-mode-line-update) #'ignore))
      (should (equal (workspace-restore-children "web" "/tmp/web/") '(("web@fix" . "/tmp/web-fix/"))))
      (should (equal made '("web@fix")))
      (should (equal placed '("web@fix")))
      (should (equal (gethash "web@fix" workspace-roots) "/tmp/web-fix/")))))
