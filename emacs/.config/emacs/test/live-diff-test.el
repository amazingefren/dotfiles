;;; live-diff-test.el --- Tests for the native CLI diff follower -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(load-file (expand-file-name "../site-lisp/live-diff.el"
                             (file-name-directory (or load-file-name buffer-file-name))))

(defun live-diff-test--git (root &rest args)
  (with-temp-buffer
    (let ((status (apply #'process-file "git" nil t nil "-C" root args)))
      (unless (zerop status)
        (ert-fail (format "git %S failed (%s): %s" args status (buffer-string)))))))

(defun live-diff-test--wait-for (predicate)
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should (funcall predicate))))

(ert-deftest live-diff-follows-tracked-and-untracked-edits-in-one-window ()
  (let* ((root (file-name-as-directory (file-truename
                                        (make-temp-file "live-diff-test-" t))))
         (tracked (expand-file-name "tracked.txt" root))
         (untracked (expand-file-name "new.txt" root))
         (original (selected-window))
         (original-buffer (window-buffer original))
         (following (split-window-right))
         (state nil))
    (unwind-protect
        (progn
          (live-diff-test--git root "init" "-q")
          (with-temp-file tracked (insert "first\n"))
          (live-diff-test--git root "add" "tracked.txt")
          (live-diff-test--git root "-c" "user.name=Test"
                               "-c" "user.email=test@example.org"
                               "-c" "commit.gpgsign=false"
                               "commit" "-qm" "baseline")
          ;; An existing change must appear as soon as follow starts.
          (with-temp-file tracked (insert "first\nsecond\n"))
          (select-window following)
          (cl-letf (((symbol-function 'workspace-root) (lambda () root)))
            (live-diff-toggle-follow))
          (setq state (gethash root live-diff--states))
          (select-window original)
          (live-diff-test--wait-for
           (lambda () (and (live-diff--state-previous-diff state)
                           (string-match-p "+second"
                                           (live-diff--state-previous-diff state)))))
          (should (eq original (selected-window)))
          (should (eq original-buffer (window-buffer original)))
          (should (eq (window-buffer following) (live-diff--state-buffer state)))
          (with-temp-file tracked (insert "second\n"))
          ;; The timer, rather than a direct poll, should notice this write.
          (live-diff-test--wait-for
           (lambda () (string-match-p "-first"
                                        (or (live-diff--state-previous-diff state) ""))))
          (should (save-excursion
                    (with-current-buffer (window-buffer following)
                      (goto-char (window-point following))
                      (looking-at-p "^@@ "))))
          (should (live-diff--state-overlays state))
          (should (cl-some
                   (lambda (overlay)
                     (and (eq (overlay-get overlay 'live-diff-kind) 'hunk)
                          (eq (overlay-get overlay 'face)
                              'live-diff-hunk-glow)))
                   (live-diff--state-overlays state)))
          (should (cl-some
                   (lambda (overlay)
                     (and (eq (overlay-get overlay 'live-diff-kind) ?-)
                          (eq (overlay-get overlay 'face)
                              'live-diff-removed-glow)))
                   (live-diff--state-overlays state)))
          (with-temp-file untracked (insert "new work\n"))
          (live-diff--poll-state state)
          (live-diff-test--wait-for
           (lambda () (string-match-p "+new work"
                                        (or (live-diff--state-previous-diff state) ""))))
          (should (eq original-buffer (window-buffer original)))
          (should (eq original (selected-window)))
          (should (cl-some
                   (lambda (overlay)
                     (and (eq (overlay-get overlay 'live-diff-kind) ?+)
                          (eq (overlay-get overlay 'face)
                              'live-diff-added-glow)))
                   (live-diff--state-overlays state)))
          (should (save-excursion
                    (with-current-buffer (window-buffer following)
                      (goto-char (window-point following))
                      (looking-at-p "^@@ ")))))
      (when state
        (live-diff--stop-state state)
        (when (buffer-live-p (live-diff--state-buffer state))
          (kill-buffer (live-diff--state-buffer state))))
      (when (window-live-p following) (delete-window following))
      (select-window original)
      (delete-directory root t))))

(ert-deftest live-diff-q-stops-follow-and-next-toggle-reopens ()
  (let* ((root (file-name-as-directory (file-truename
                                        (make-temp-file "live-diff-quit-" t))))
         (window (selected-window))
         (original-buffer (window-buffer window)))
    (unwind-protect
        (progn
          (live-diff-test--git root "init" "-q")
          (cl-letf (((symbol-function 'workspace-root) (lambda () root)))
            (live-diff-toggle-follow)
            (should (eq (with-current-buffer (window-buffer window)
                          (key-binding (kbd "q")))
                        #'live-diff-quit))
            (call-interactively #'live-diff-quit)
            (should-not (gethash root live-diff--states))
            (should (eq (window-buffer window) original-buffer))
            (live-diff-toggle-follow)
            (should (gethash root live-diff--states))
            (should (eq (window-buffer window)
                        (live-diff--state-buffer
                         (gethash root live-diff--states))))))
      (when-let* ((state (gethash root live-diff--states)))
        (live-diff--stop-state state)
        (when (buffer-live-p (live-diff--state-buffer state))
          (kill-buffer (live-diff--state-buffer state))))
      (when (window-live-p window)
        (set-window-buffer window original-buffer))
      (delete-directory root t))))

(ert-deftest live-diff-file-follow-isolates-major-mode-preview-from-user-buffer ()
  (let* ((root (file-name-as-directory (file-truename
                                        (make-temp-file "live-file-test-" t))))
         (tracked (expand-file-name "tracked.el" root))
         (original (selected-window))
         (original-buffer (window-buffer original))
         (following (split-window-right))
         state user-buffer)
    (unwind-protect
        (progn
          (live-diff-test--git root "init" "-q")
          (with-temp-file tracked (insert "(message \"one\")\n"))
          (live-diff-test--git root "add" "tracked.el")
          (live-diff-test--git root "-c" "user.name=Test"
                               "-c" "user.email=test@example.org"
                               "-c" "commit.gpgsign=false"
                               "commit" "-qm" "baseline")
          (setq user-buffer (find-file-noselect tracked))
          (with-current-buffer user-buffer
            (goto-char (point-max))
            (insert ";; unsaved user note\n"))
          (set-window-buffer original user-buffer)
          (select-window following)
          (cl-letf (((symbol-function 'workspace-root) (lambda () root)))
            (live-diff-toggle-file-follow))
          (setq state (gethash root live-diff--states))
          (select-window original)
          (live-diff-test--wait-for
           (lambda () (live-diff--state-previous-diff state)))
          (with-temp-file tracked
            (insert "(message \"one\")\n(message \"two\")\n"))
          (live-diff-test--wait-for
           (lambda () (equal
                       (buffer-local-value
                        'live-diff--preview-file (window-buffer following))
                       tracked)))
          (should (eq original (selected-window)))
          (should (eq user-buffer (window-buffer original)))
          (should (eq user-buffer (get-file-buffer tracked)))
          (should (with-current-buffer user-buffer
                    (and (buffer-modified-p)
                         (string-search "unsaved user note" (buffer-string))
                         (not (string-search "two" (buffer-string))))))
          (should (with-current-buffer (window-buffer following)
                    (and (eq major-mode 'emacs-lisp-mode)
                         (null buffer-file-name)
                         buffer-read-only
                         (string-search "two" (buffer-string)))))
          (live-diff-test--wait-for
           (lambda () (= 2 (with-current-buffer (window-buffer following)
                              (line-number-at-pos (window-point following))))))
          (set-window-buffer following original-buffer)
          (live-diff--reconcile)
          (should-not (gethash root live-diff--states)))
      (when state (live-diff--stop-state state))
      (when (buffer-live-p user-buffer)
        (with-current-buffer user-buffer (set-buffer-modified-p nil))
        (kill-buffer user-buffer))
      (when (window-live-p following) (delete-window following))
      (select-window original)
      (set-window-buffer original original-buffer)
      (delete-directory root t))))

(ert-deftest live-diff-file-glow-marks-the-line-before-a-final-deletion ()
  (with-temp-buffer
    (insert "keep\n")
    (set-buffer-modified-p nil)
    (let ((state (live-diff--state-create :buffer (current-buffer)))
          (live-diff-glow-bright-seconds 0.01)
          (live-diff-glow-total-seconds 0.02))
      (unwind-protect
          (progn
            (should (equal (live-diff--text-change "keep\ndeleted\n" "keep\n")
                           (list 2 1 ?-)))
            (live-diff--file-glow state 2 1 ?-)
            (should (cl-some
                     (lambda (overlay)
                       (and (eq (overlay-get overlay 'live-diff-kind) ?-)
                            (= (overlay-start overlay) (point-min))))
                     (live-diff--state-overlays state)))
            (should (equal (live-diff--removed-lines "keep\ndeleted\n" "keep\n")
                           "deleted"))
            (should (equal
                     (live-diff--removed-lines
                      "  (message \"kept\")\n  (message \"removed\"))\n"
                      "  (message \"kept\"))\n")
                     "  (message \"removed\")"))
            (should (= (live-diff--removed-anchor-line
                        "  (message \"kept\")\n  (message \"removed\"))\n"
                        "  (message \"kept\"))\n")
                       2))
            (live-diff--show-removed (current-buffer) 2 "deleted")
            (accept-process-output nil 0.05)
            (should (cl-some #'overlay-buffer
                             (live-diff--state-overlays state)))
            (should (string-match-p "− deleted"
                                    (overlay-get live-diff--removed-preview
                                                 'before-string)))
            (should-not (buffer-modified-p)))
        (live-diff--clear-glow state)))))

(ert-deftest live-diff-private-preview-keeps-syntax-without-file-hooks ()
  (let* ((root (file-name-as-directory (file-truename
                                        (make-temp-file "live-preview-mode-" t))))
         (file (expand-file-name "preview.el" root))
         (mode-hook-ran nil)
         (emacs-lisp-mode-hook
          (list (lambda () (setq mode-hook-ran t))))
         buffer)
    (unwind-protect
        (progn
          (setq buffer (live-diff--private-file-buffer
                        root file "(message \"preview\")\n"))
          (should (with-current-buffer buffer
                    (and (eq major-mode 'emacs-lisp-mode)
                         font-lock-defaults
                         (null buffer-file-name)
                         buffer-read-only
                         (eq (local-key-binding (kbd "q"))
                             #'live-diff-quit))))
          (should-not mode-hook-ran))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest live-diff-smart-side-split-uses-compact-and-deletion-notices ()
  (let* ((root (file-name-as-directory (file-truename
                                        (make-temp-file "live-file-side-" t))))
         (file (expand-file-name "side.el" root))
         (original (selected-window))
         (original-buffer (window-buffer original))
         state)
    (unwind-protect
        (progn
          (live-diff-test--git root "init" "-q")
          (cl-letf (((symbol-function 'workspace-root) (lambda () root)))
            (live-diff-follow-in-split))
          (setq state (gethash root live-diff--states))
          (should (eq (window-parameter (live-diff--state-window state)
                                        'window-side)
                      'right))
          (should (eq original (selected-window)))
          (let ((live-diff-max-mode-file-size 1))
            (with-temp-file file (insert "(message \"large\")\n"))
            (live-diff-test--wait-for
             (lambda () (string-prefix-p
                         "*AI quick change:"
                         (buffer-name (live-diff--state-buffer state)))))
            (should (with-current-buffer (live-diff--state-buffer state)
                      (and (eq major-mode 'fundamental-mode)
                           (string-search "+(message" (buffer-string)))))
            (should-not (get-file-buffer file)))
          (with-temp-file file (insert "(message \"small\")\n"))
          (live-diff-test--wait-for
           (lambda () (equal
                       (buffer-local-value
                        'live-diff--preview-file (live-diff--state-buffer state))
                       file)))
          (should (with-current-buffer (live-diff--state-buffer state)
                    (eq major-mode 'emacs-lisp-mode)))
          (should (eq original-buffer (window-buffer original)))
          (delete-file file)
          (live-diff-test--wait-for
           (lambda () (with-current-buffer (live-diff--state-buffer state)
                        (string-search "side.el — file deleted"
                                       (buffer-string)))))
          (should (with-current-buffer (live-diff--state-buffer state)
                    (not (string-search "message" (buffer-string)))))
          (cl-letf (((symbol-function 'workspace-root) (lambda () root)))
            (live-diff-follow-in-split))
          (should-not (gethash root live-diff--states))
          (should-not (get-file-buffer file)))
      (when-let* ((active (gethash root live-diff--states)))
        (let ((window (live-diff--state-window active)))
          (when (window-live-p window) (delete-window window))
          (live-diff--stop-state active)))
      (select-window original)
      (delete-directory root t))))

(ert-deftest live-diff-compact-preview-shows-one-hunk-and-reverts ()
  (let* ((root default-directory)
         (first (concat "diff --git a/one.el b/one.el\n"
                        "--- a/one.el\n+++ b/one.el\n"
                        "@@ -1 +1 @@\n-old\n+new\n"))
         (later (concat first "@@ -8 +8 @@\n-earlier\n+latest\n"))
         (second (concat first
                         "diff --git a/two.el b/two.el\n"
                         "--- a/two.el\n+++ b/two.el\n"
                         "@@ -1 +1 @@\n-before\n+after\n"))
         (reverted (live-diff--compact-preview root first ""))
         (removed-section (live-diff--compact-preview root second
                                                       (substring second
                                                                  (length first)))))
    (should (string-search "one.el" (live-diff--compact-preview root nil first)))
    (should (string-search "+latest"
                           (live-diff--compact-preview root first later)))
    (should-not (string-search "+new"
                               (live-diff--compact-preview root first later)))
    (should (string-search "-new\n+old" reverted))
    (should (string-search "one.el — left worktree diff"
                           removed-section))
    (should (string-search "-new\n+old" removed-section))
    (should-not (string-search "two.el" removed-section))))

(ert-deftest live-diff-compact-preview-skips-changing-untracked-header ()
  (let* ((root default-directory)
         (prefix (concat "diff --git a/new.el b/new.el\n"
                         "new file mode 100644\n--- /dev/null\n+++ b/new.el\n"))
         (old (concat prefix "@@ -0,0 +1,3 @@\n+a\n+b\n+c\n"))
         (new (concat prefix "@@ -0,0 +1,4 @@\n+a\n+b\n+c\n+d\n"))
         (preview (live-diff--compact-preview root old new)))
    (should (string-search "+d" preview))
    (should-not (string-search "+a" preview))
    (should-not (string-search "+b" preview))
    (should-not (string-search "+c" preview))
    (should (string-search "-d"
                           (live-diff--compact-preview root new old)))))

(ert-deftest live-diff-compact-preview-collapses-tracked-file-deletion ()
  (let* ((root default-directory)
         (old (concat "diff --git a/gone.el b/gone.el\n"
                      "--- a/gone.el\n+++ b/gone.el\n"
                      "@@ -1 +1 @@\n-old\n+new\n"))
         (deleted (concat "diff --git a/gone.el b/gone.el\n"
                          "deleted file mode 100644\n"
                          "--- a/gone.el\n+++ /dev/null\n"
                          "@@ -1,3 +0,0 @@\n-one\n-two\n-three\n"))
         (preview (live-diff--compact-preview root old deleted)))
    (should (equal preview "gone.el — file deleted\n"))))

(ert-deftest live-diff-compact-text-preview-works-without-git ()
  (let ((root "/tmp/non-git-space/")
        (path "/tmp/non-git-space/note.txt"))
    (should (equal (live-diff--compact-text-preview
                    root path "one\ntwo\n" "one\nnew\n")
                   "note.txt\n-two\n+new\n"))
    (should (equal (live-diff--compact-text-preview
                    root path "one\ntwo\n" "one\n")
                   "note.txt\n-two\n"))
    (should (equal (live-diff--compact-text-preview
                    root path "one\ntwo\n" nil)
                   "note.txt — file deleted\n"))))

(ert-deftest live-diff-non-git-file-follow-renders-and-summarizes-deletion ()
  (let* ((root (file-name-as-directory (file-truename
                                        (make-temp-file "live-non-git-" t))))
         (file (expand-file-name "note.el" root))
         (original (selected-window))
         state)
    (unwind-protect
        (progn
          (with-temp-file file (insert "(message \"before\")\n"))
          (cl-letf (((symbol-function 'workspace-root) (lambda () root)))
            (live-diff-follow-in-split))
          (setq state (gethash root live-diff--states))
          (should (eq (live-diff--state-source state) 'notify))
          (with-temp-file file (insert "(message \"after\")\n"))
          (live-diff-notify--refresh (live-diff--state-notify state))
          (should (with-current-buffer (live-diff--state-buffer state)
                    (and (eq major-mode 'emacs-lisp-mode)
                         (null buffer-file-name)
                         (string-search "after" (buffer-string)))))
          (delete-file file)
          (live-diff-notify--refresh (live-diff--state-notify state))
          (should (with-current-buffer (live-diff--state-buffer state)
                    (equal (buffer-string) "note.el — file deleted\n")))
          (should (eq original (selected-window)))
          (let ((notice (live-diff--state-buffer state)))
            (with-selected-window (live-diff--state-window state)
              (live-diff-quit))
            (should-not (gethash root live-diff--states))
            (should-not (buffer-live-p notice))))
      (when state
        (let ((window (live-diff--state-window state)))
          (when (window-live-p window) (delete-window window))
          (live-diff--stop-state state)))
      (select-window original)
      (delete-directory root t))))

(ert-deftest live-diff-non-git-compact-follow-summarizes-deletion ()
  (let* ((root (file-name-as-directory (file-truename
                                        (make-temp-file "live-non-git-compact-" t))))
         (file (expand-file-name "note.txt" root))
         state)
    (unwind-protect
        (progn
          (with-temp-file file (insert "before\n"))
          (cl-letf (((symbol-function 'workspace-root) (lambda () root)))
            (live-diff-follow-compact-in-split))
          (setq state (gethash root live-diff--states))
          (delete-file file)
          (live-diff-notify--refresh (live-diff--state-notify state))
          (should (with-current-buffer (live-diff--state-buffer state)
                    (equal (buffer-string) "note.txt — file deleted\n"))))
      (when state
        (let ((window (live-diff--state-window state)))
          (when (window-live-p window) (delete-window window))
          (live-diff--stop-state state)))
      (delete-directory root t))))

(ert-deftest live-diff-compact-split-uses-a-plain-buffer ()
  (let* ((root (file-name-as-directory (file-truename
                                        (make-temp-file "live-compact-" t))))
         (file (expand-file-name "added.el" root))
         (original (selected-window))
         state)
    (unwind-protect
        (progn
          (live-diff-test--git root "init" "-q")
          (with-temp-file file (insert "(message \"base\")\n"))
          (cl-letf (((symbol-function 'workspace-root) (lambda () root)))
            (live-diff-follow-compact-in-split))
          (setq state (gethash root live-diff--states))
          (live-diff-test--wait-for
           (lambda () (live-diff--state-previous-diff state)))
          (should (eq (live-diff--state-view state) 'compact))
          (should (with-current-buffer (live-diff--state-buffer state)
                    (eq major-mode 'fundamental-mode)))
          (should (with-current-buffer (live-diff--state-buffer state)
                    (string-search "Waiting for the next file change"
                                   (buffer-string))))
          (with-temp-file file (insert "(message \"hello\")\n"))
          (live-diff-test--wait-for
           (lambda () (with-current-buffer (live-diff--state-buffer state)
                        (string-search "+(message" (buffer-string)))))
          (should-not (get-file-buffer file))
          (should (eq original (selected-window)))
          (cl-letf (((symbol-function 'workspace-root) (lambda () root)))
            (live-diff-follow-compact-in-split))
          (should-not (gethash root live-diff--states)))
      (when-let* ((active (gethash root live-diff--states)))
        (let ((window (live-diff--state-window active)))
          (when (window-live-p window) (delete-window window))
          (live-diff--stop-state active)))
      (select-window original)
      (delete-directory root t))))

(ert-deftest live-diff-rejects-non-git-workspace ()
  (let ((root (make-temp-file "live-diff-no-git-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'workspace-root) (lambda () root)))
          (should-error (live-diff-toggle-follow) :type 'user-error))
      (delete-directory root t))))

(ert-deftest live-diff-works-before-first-commit-and-scopes-to-workspace ()
  (let* ((root (file-name-as-directory (file-truename
                                        (make-temp-file "live-diff-unborn-" t))))
         (nested (expand-file-name "space" root))
         (outside (expand-file-name "outside.txt" root))
         (inside (expand-file-name "inside.txt" nested))
         (window (selected-window))
         (previous-buffer (window-buffer window))
         (state nil))
    (unwind-protect
        (progn
          (live-diff-test--git root "init" "-q")
          (make-directory nested)
          (with-temp-file outside (insert "outside\n"))
          (with-temp-file inside (insert "inside\n"))
          (live-diff-test--git root "add" "space/inside.txt")
          (cl-letf (((symbol-function 'workspace-root) (lambda () nested)))
            (live-diff-toggle-follow))
          (setq state (gethash (file-name-as-directory (file-truename nested))
                               live-diff--states))
          (should-not (live-diff--state-has-head state))
          (live-diff-test--wait-for
           (lambda () (live-diff--state-previous-diff state)))
          (should (string-match-p "+inside" (live-diff--state-previous-diff state)))
          (should-not (string-match-p "outside" (live-diff--state-previous-diff state))))
      (when state
        (live-diff--stop-state state)
        (when (buffer-live-p (live-diff--state-buffer state))
          (kill-buffer (live-diff--state-buffer state))))
      (set-window-buffer window previous-buffer)
      (delete-directory root t))))

(ert-deftest live-diff-does-not-redraw-an-unchanged-diff ()
  (let* ((root (file-name-as-directory (file-truename
                                        (make-temp-file "live-diff-stable-" t))))
         (buffer (generate-new-buffer " *live-diff stable*"))
         (window (selected-window))
         (state (live-diff--state-create :root root :window window :buffer buffer)))
    (unwind-protect
        (progn
          (puthash root state live-diff--states)
          (set-window-parameter window live-diff--window-parameter root)
          (with-current-buffer buffer (diff-mode) (setq-local buffer-read-only t))
          (live-diff--render state "diff --git a/a b/a\n@@ -1 +1 @@\n-old\n+new\n")
          (with-current-buffer buffer
            (let ((tick (buffer-chars-modified-tick)))
              (live-diff--render state (live-diff--state-previous-diff state))
              (should (= tick (buffer-chars-modified-tick))))))
      (live-diff--stop-state state)
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest live-diff-reconnects-a-restored-follow-window ()
  (let* ((root (file-name-as-directory (file-truename
                                        (make-temp-file "live-diff-restore-" t))))
         (window (selected-window))
         (previous-buffer (window-buffer window))
         state)
    (unwind-protect
        (progn
          (live-diff-test--git root "init" "-q")
          (cl-letf (((symbol-function 'workspace-root) (lambda () root)))
            (live-diff-toggle-follow))
          (setq state (gethash root live-diff--states))
          (live-diff-test--wait-for
           (lambda () (live-diff--state-previous-diff state)))
          ;; Window-state restoration can preserve its parameter and buffer
          ;; while the process-local timer and state are gone.
          (remhash root live-diff--states)
          (cancel-timer live-diff--timer)
          (setq live-diff--timer nil)
          (live-diff--reconcile)
          (should (gethash root live-diff--states))
          (should live-diff--timer)
          (should (eq window (live-diff--state-window
                              (gethash root live-diff--states)))))
      (when-let* ((active (gethash root live-diff--states)))
        (live-diff--stop-state active)
        (when (buffer-live-p (live-diff--state-buffer active))
          (kill-buffer (live-diff--state-buffer active))))
      (set-window-buffer window previous-buffer)
      (delete-directory root t))))

(ert-deftest live-diff-jumps-to-newest-file-when-several-change ()
  (let* ((root (file-name-as-directory (file-truename
                                        (make-temp-file "live-diff-order-" t))))
         (a (expand-file-name "a.txt" root))
         (b (expand-file-name "b.txt" root))
         (old (concat "diff --git a/a.txt b/a.txt\n@@ -1 +1 @@\n-old a\n+first a\n"
                      "diff --git a/b.txt b/b.txt\n@@ -1 +1 @@\n-old b\n+first b\n"))
         (new (concat "diff --git a/a.txt b/a.txt\n@@ -1 +1 @@\n-old a\n+second a\n"
                      "diff --git a/b.txt b/b.txt\n@@ -1 +1 @@\n-old b\n+second b\n")))
    (unwind-protect
        (progn
          (with-temp-file a (insert "second a\n"))
          (with-temp-file b (insert "second b\n"))
          (set-file-times a (time-subtract (current-time) 10))
          (set-file-times b (current-time))
          (should (>= (live-diff--latest-change-position root old new)
                      (string-match "^diff --git a/b.txt" new))))
      (delete-directory root t))))

(provide 'live-diff-test)
;;; live-diff-test.el ends here
