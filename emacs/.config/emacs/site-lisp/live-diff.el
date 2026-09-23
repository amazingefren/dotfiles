;;; live-diff.el --- Follow CLI edits in Emacs review windows -*- lexical-binding: t -*-

;; Codex and Claude can write through their native CLI tools.  This module
;; observes file changes, so neither agent needs to opt in to an MCP tool.

(require 'cl-lib)
(require 'diff-mode)
(require 'project)
(require 'subr-x)
(let ((load-path (cons (file-name-directory (or load-file-name buffer-file-name))
                       load-path)))
  (require 'live-diff-notify))

(defgroup live-diff nil
  "Live review of worktree edits made by CLI agents."
  :group 'tools)

(defcustom live-diff-poll-interval 1.0
  "Seconds between asynchronous Git inspections while a window follows."
  :type 'number :group 'live-diff)

(defcustom live-diff-glow-bright-seconds 0.7
  "Seconds to show the bright phase of a changed hunk."
  :type 'number :group 'live-diff)

(defcustom live-diff-glow-total-seconds 2.5
  "Seconds before a changed hunk's highlight disappears."
  :type 'number :group 'live-diff)

(defcustom live-diff-max-characters 500000
  "Maximum number of diff characters kept in a live review buffer."
  :type 'integer :group 'live-diff)

(defcustom live-diff-max-untracked-file-size 100000
  "Largest untracked text file displayed as an added-file diff."
  :type 'integer :group 'live-diff)

(defcustom live-diff-max-untracked-files 50
  "Maximum untracked files inspected during one refresh."
  :type 'integer :group 'live-diff)

(defcustom live-diff-max-untracked-bytes 300000
  "Maximum total untracked file bytes read during one refresh."
  :type 'integer :group 'live-diff)

(defcustom live-diff-max-follow-file-size 2000000
  "Largest file opened automatically by file follow, in bytes."
  :type 'integer :group 'live-diff)

(defcustom live-diff-max-mode-file-size 250000
  "Largest unopened file loaded into its major mode by smart follow.
Larger files use the compact change view instead."
  :type 'integer :group 'live-diff)

(defcustom live-diff-compact-max-lines 24
  "Maximum added and removed lines shown in the compact follow view."
  :type 'integer :group 'live-diff)

(defface live-diff-added-glow
  '((((class color) (background dark)) :background "#237a50" :foreground "#f3fff7" :weight bold)
    (((class color) (background light)) :background "#8ee3b4" :foreground "#123d29" :weight bold)
    (t :inverse-video t))
  "Bright first phase for added lines." :group 'live-diff)

(defface live-diff-removed-glow
  '((((class color) (background dark)) :background "#994252" :foreground "#fff4f5" :weight bold)
    (((class color) (background light)) :background "#efaaaa" :foreground "#4c1d27" :weight bold)
    (t :inverse-video t))
  "Bright first phase for removed lines." :group 'live-diff)

(defface live-diff-added-glow-fade
  '((((class color) (background dark)) :background "#1d4d39")
    (((class color) (background light)) :background "#d6f4e2")
    (t :inverse-video t))
  "Fading phase for added lines." :group 'live-diff)

(defface live-diff-removed-glow-fade
  '((((class color) (background dark)) :background "#60323c")
    (((class color) (background light)) :background "#f9dcdc")
    (t :inverse-video t))
  "Fading phase for removed lines." :group 'live-diff)

(defface live-diff-hunk-glow
  '((((class color) (background dark)) :background "#9a6a23" :foreground "#fff9e8" :weight bold)
    (((class color) (background light)) :background "#ffe08b" :foreground "#4c3511" :weight bold)
    (t :inverse-video t))
  "Bright first phase for the hunk header where follow lands." :group 'live-diff)

(defface live-diff-hunk-glow-fade
  '((((class color) (background dark)) :background "#5d4728")
    (((class color) (background light)) :background "#fff1c5")
    (t :inverse-video t))
  "Fading phase for the hunk header." :group 'live-diff)

(defface live-diff-removed-preview
  '((((class color) (background dark)) :background "#71313a" :foreground "#ffe5e8" :strike-through t)
    (((class color) (background light)) :background "#f5c6cc" :foreground "#5b202a" :strike-through t)
    (t :inverse-video t))
  "Temporary inline preview of text removed by an external edit." :group 'live-diff)

(defface live-diff-added-fringe
  '((t :foreground "#48d594"))
  "Fringe marker for the latest added lines." :group 'live-diff)

(defface live-diff-removed-fringe
  '((t :foreground "#e77c8e"))
  "Fringe marker for the latest removed lines." :group 'live-diff)

(when (fboundp 'define-fringe-bitmap)
  (define-fringe-bitmap 'live-diff-change-bar
    [#b11110000 #b11110000 #b11110000 #b11110000
     #b11110000 #b11110000 #b11110000 #b11110000]
    8 4 'center))

(cl-defstruct (live-diff--state (:constructor live-diff--state-create))
  root window buffer previous-diff pending overlays has-head view previous-file previous-text
  source notify)

(defvar live-diff--states (make-hash-table :test #'equal))
(defvar live-diff--timer nil)
(defvar live-diff--reconcile-timer nil)
(defconst live-diff--window-parameter 'live-diff-root)
(defvar-local live-diff--opened-by-follow nil
  "Non-nil when file follow opened this buffer solely for review.")
(defvar-local live-diff--removed-preview nil
  "Overlay showing the last removed text in this file buffer.")
(defvar-local live-diff--preview-file nil
  "Source path represented by a private AI file preview buffer.")

(defun live-diff--bind-quit-key ()
  "Make `q' close a follow pane, including in Evil normal state."
  (local-set-key (kbd "q") #'live-diff-quit)
  (when (fboundp 'evil-local-set-key)
    (evil-local-set-key 'normal (kbd "q") #'live-diff-quit)))

(defun live-diff--workspace-directory ()
  "Return the current workspace directory, before resolving its Git root."
  (let ((directory
         (cond ((fboundp 'workspace-root) (workspace-root))
               ((when-let* ((project (project-current nil)))
                  (project-root project)))
               (t default-directory))))
    (unless (and (stringp directory) (file-directory-p directory))
      (user-error "The current workspace has no directory to follow"))
    (file-name-as-directory (file-truename directory))))

(defun live-diff--git-root ()
  "Return the current Git workspace directory or explain why it cannot follow."
  (unless (executable-find "git")
    (user-error "AI diff follow needs Git on PATH"))
  (let ((default-directory (live-diff--workspace-directory)))
    (with-temp-buffer
      (unless (zerop (process-file "git" nil t nil "rev-parse" "--show-toplevel"))
        (user-error "AI diff follow needs a Git worktree: %s" default-directory))
      default-directory)))

(defun live-diff--follow-root ()
  "Return the Git root, or this workspace's directory without Git."
  (let ((default-directory (live-diff--workspace-directory)))
    (live-diff-notify--root
     (if (and (executable-find "git")
              (zerop (process-file "git" nil nil nil
                                   "rev-parse" "--is-inside-work-tree")))
         (live-diff--git-root)
       default-directory))))

(defun live-diff--git-root-p (root)
  "Return non-nil when ROOT is inside a Git worktree."
  (and (executable-find "git")
       (zerop (process-file "git" nil nil nil "-C" root
                            "rev-parse" "--is-inside-work-tree"))))

(defun live-diff--has-head-p (root)
  "Return non-nil if ROOT has an initial commit."
  (zerop (process-file "git" nil nil nil "-C" root
                       "rev-parse" "--verify" "--quiet" "HEAD")))

(defun live-diff--file-snapshot (root buffer)
  "Return (RELATIVE-PATH . TEXT) for BUFFER when its file belongs to ROOT."
  (when-let* ((file (buffer-file-name buffer))
              ((ignore-errors (file-in-directory-p file root))))
    (cons (file-relative-name file root)
          (with-current-buffer buffer (buffer-string)))))

(defun live-diff--active-p (state)
  "Return whether STATE still owns its designated window."
  (and (eq state (gethash (live-diff--state-root state) live-diff--states))
       (window-live-p (live-diff--state-window state))
       (eq (window-buffer (live-diff--state-window state))
           (live-diff--state-buffer state))
       (equal (window-parameter (live-diff--state-window state)
                                live-diff--window-parameter)
              (live-diff--state-root state))))

(defun live-diff--clear-glow (state)
  (mapc #'delete-overlay (live-diff--state-overlays state))
  (setf (live-diff--state-overlays state) nil)
  (when (buffer-live-p (live-diff--state-buffer state))
    (with-current-buffer (live-diff--state-buffer state)
      (when (overlayp live-diff--removed-preview)
        (delete-overlay live-diff--removed-preview)
        (setq-local live-diff--removed-preview nil)))))

(defun live-diff--release-file-buffer (buffer follow-window)
  "Discard BUFFER if file follow created it and nobody else uses it."
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'live-diff--opened-by-follow buffer))
    (let ((windows (get-buffer-window-list buffer nil t)))
      (cond
       ((cl-some (lambda (window) (not (eq window follow-window))) windows)
        (with-current-buffer buffer (setq-local live-diff--opened-by-follow nil)))
       ((and (null windows) (not (buffer-modified-p buffer)))
        (kill-buffer buffer))))))

(defun live-diff--notice-buffer (root message)
  "Return a small review buffer for ROOT displaying MESSAGE."
  (let ((buffer (get-buffer-create
                 (format "*AI follow: %s*"
                         (abbreviate-file-name root)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert message "\n")
        (when (string-match-p "— file deleted\\'" message)
          (add-text-properties (point-min) (1- (point-max))
                               '(face live-diff-removed-glow))))
      (special-mode)
      (live-diff--bind-quit-key)
      (setq-local default-directory root)
      (setq-local live-diff--opened-by-follow t))
    buffer))

(defun live-diff--waiting-buffer (root)
  "Return a small review buffer for ROOT while no changed file is open."
  (live-diff--notice-buffer root "Waiting for the next file change…"))

(defun live-diff--stop-state (state)
  "Stop STATE, leaving its last review buffer available for inspection."
  (let ((process (live-diff--state-pending state)))
    (remhash (live-diff--state-root state) live-diff--states)
    (setf (live-diff--state-pending state) nil)
    (when (and process (process-live-p process))
      (delete-process process)))
  (when (and (live-diff--state-notify state)
             (fboundp 'live-diff-notify-stop))
    (live-diff-notify-stop (live-diff--state-notify state))
    (setf (live-diff--state-notify state) nil))
  (live-diff--clear-glow state)
  (when (window-live-p (live-diff--state-window state))
    (set-window-parameter (live-diff--state-window state)
                          live-diff--window-parameter nil)
    (set-window-parameter (live-diff--state-window state)
                          'live-diff-view nil)
    (set-window-parameter (live-diff--state-window state)
                          'live-diff-source nil))
  (live-diff--release-file-buffer (live-diff--state-buffer state)
                                  (live-diff--state-window state))
  (when (and live-diff--timer (not (live-diff--has-git-states-p)))
    (cancel-timer live-diff--timer)
    (setq live-diff--timer nil)))

(defun live-diff--has-git-states-p ()
  "Return non-nil when any active follow state uses Git polling."
  (let ((found nil))
    (maphash (lambda (_root state)
               (unless (eq (live-diff--state-source state) 'notify)
                 (setq found t)))
             live-diff--states)
    found))

(defun live-diff--ensure-timer ()
  "Keep polling while at least one ordinary window follows a diff."
  (when (and (live-diff--has-git-states-p)
             (not live-diff--timer))
    (setq live-diff--timer
          (run-with-timer live-diff-poll-interval live-diff-poll-interval
                          #'live-diff--poll))))

(defun live-diff--reconcile ()
  "Reconnect a follow window recreated by a workspace or window restore."
  (let (windows stale)
    (dolist (frame (frame-list))
      (setq windows (nconc windows (window-list frame 'nomini))))
    (maphash
     (lambda (root state)
       (unless (live-diff--active-p state)
         (if-let* ((window
                    (cl-find-if
                     (lambda (candidate)
                       (and (equal (window-parameter candidate live-diff--window-parameter)
                                   root)
                            (eq (window-buffer candidate)
                                (live-diff--state-buffer state))))
                     windows)))
             (setf (live-diff--state-window state) window)
           (push state stale))))
     live-diff--states)
    (mapc #'live-diff--stop-state stale)
    (dolist (window windows)
      (when-let* ((root (window-parameter window live-diff--window-parameter))
                  ((not (gethash root live-diff--states)))
                  ((file-directory-p root))
                  (buffer (window-buffer window))
                  (view (or (window-parameter window 'live-diff-view) 'diff))
                  (source (or (window-parameter window 'live-diff-source)
                              'git))
                  ((or (memq view '(file compact))
                       (string-prefix-p "*AI live diff:" (buffer-name buffer)))))
        (let ((state (live-diff--state-create
                      :root root :window window :buffer buffer
                      :view view :source source
                      :has-head (and (not (eq source 'notify))
                                     (live-diff--has-head-p root))
                      :previous-file (and (eq view 'file)
                                          (car (live-diff--file-snapshot root buffer)))
                      :previous-text (and (eq view 'file)
                                          (cdr (live-diff--file-snapshot root buffer))))))
          (puthash root state live-diff--states)
          (if (eq source 'notify)
              (live-diff--start-notify-state state)
            (live-diff--poll-state state)))))
    (live-diff--ensure-timer)))

(defun live-diff--schedule-reconcile ()
  "Coalesce window changes before checking live diff ownership."
  (unless live-diff--reconcile-timer
    (setq live-diff--reconcile-timer
          (run-at-time
           0.1 nil
           (lambda ()
             (setq live-diff--reconcile-timer nil)
             (live-diff--reconcile))))))

(add-hook 'window-configuration-change-hook #'live-diff--schedule-reconcile)
(live-diff--schedule-reconcile)

(defun live-diff--disable-legacy-follow ()
  "Retire the old file-reveal follower in an already-running Emacs session."
  (when (and (boundp 'emacs-mcp--follow-timer) emacs-mcp--follow-timer)
    (cancel-timer emacs-mcp--follow-timer)
    (setq emacs-mcp--follow-timer nil))
  (when (boundp 'emacs-mcp--follow-baselines)
    (clrhash emacs-mcp--follow-baselines))
  (dolist (frame (frame-list))
    (dolist (window (window-list frame 'nomini))
      (set-window-parameter window 'emacs-mcp-follow-root nil))))

(defun live-diff--start-process (state arguments callback)
  "Run Git ARGUMENTS asynchronously for STATE, then call CALLBACK with output."
  (let* ((buffer (generate-new-buffer " *live-diff git*"))
         (process
          (make-process
           :name "live-diff-git" :buffer buffer :noquery t
           :command (append (list "git" "-C" (live-diff--state-root state)) arguments)
           :coding 'utf-8-unix
           :sentinel
           (lambda (process _event)
             (when (memq (process-status process) '(exit signal))
               (let ((output (when (buffer-live-p buffer)
                               (with-current-buffer buffer (buffer-string))))
                     (success (and (eq (process-status process) 'exit)
                                   (zerop (process-exit-status process)))))
                 (when (buffer-live-p buffer) (kill-buffer buffer))
                 (when (eq process (live-diff--state-pending state))
                   (setf (live-diff--state-pending state) nil))
                 (when (live-diff--active-p state)
                   (if success
                       (funcall callback output)
                     (message "AI diff follow: Git inspection failed in %s"
                              (abbreviate-file-name (live-diff--state-root state)))))))))))
    (setf (live-diff--state-pending state) process)
    process))

(defun live-diff--untracked-diff (root paths)
  "Return a small unified diff for untracked text PATHS in ROOT."
  (with-temp-buffer
    (let ((inspected 0)
          (bytes 0))
      (catch 'limit
        (dolist (relative (split-string paths "\0" t))
          (when (>= inspected live-diff-max-untracked-files)
            (insert "# Further untracked files omitted from live preview\n")
            (throw 'limit nil))
          (setq inspected (1+ inspected))
          (let ((path (expand-file-name relative root)))
            (when (and (file-regular-p path)
                       (file-in-directory-p (file-truename path) root))
              (let ((size (file-attribute-size (file-attributes path))))
                (cond
                 ((or (> size live-diff-max-untracked-file-size)
                      (> (+ bytes size) live-diff-max-untracked-bytes))
                  (insert (format "diff --git a/%s b/%s\n"
                                  relative relative)
                          "# Untracked file exceeds live preview limit\n"))
                 (t
                  (setq bytes (+ bytes size))
                  (let ((content (with-temp-buffer
                                   (insert-file-contents-literally path)
                                   (buffer-string))))
                    (unless (string-match-p "\0" content)
                      (let* ((lines (split-string content "\n" nil))
                             (ends-newline (string-suffix-p "\n" content))
                             (count (if (string-empty-p content) 0
                                      (if ends-newline (1- (length lines))
                                        (length lines)))))
                        (insert (format "diff --git a/%s b/%s\nnew file mode 100644\n"
                                        relative relative)
                                "--- /dev/null\n"
                                (format "+++ b/%s\n" relative))
                        (when (> count 0)
                          (insert (format "@@ -0,0 +1,%d @@\n" count))
                          (dotimes (index count)
                            (insert "+" (nth index lines) "\n"))
                          (unless ends-newline
                            (insert "\\ No newline at end of file\n"))))))))))))))
    (buffer-string)))

(defun live-diff--change-position (old new)
  "Return first differing character position between OLD and NEW."
  (let ((index 0)
        (limit (min (length old) (length new))))
    (while (and (< index limit) (eq (aref old index) (aref new index)))
      (setq index (1+ index)))
    index))

(defun live-diff--hunk-change-position (old new)
  "Return the changed offset in NEW, ignoring Git's changing hunk header."
  (let* ((old-hunk (string-match "^@@ " old))
         (new-hunk (string-match "^@@ " new))
         (old-body (and old-hunk (string-match "\n" old old-hunk)))
         (new-body (and new-hunk (string-match "\n" new new-hunk))))
    (if (and old-body new-body)
        (+ 1 new-body
           (live-diff--change-position (substring old (1+ old-body))
                                       (substring new (1+ new-body))))
      (live-diff--change-position old new))))

(defun live-diff--sections (diff)
  "Return (PATH START CONTENT) sections from DIFF."
  (let ((start (string-match "^diff --git " diff))
        sections)
    (while start
      (let* ((line-end (or (string-match "\n" diff start) (length diff)))
             (header (substring diff start line-end))
             (next (string-match "^diff --git " diff (1+ start)))
             (path (and (string-match " b/\\(.*\\)$" header)
                        (match-string 1 header))))
        (push (list path start (substring diff start (or next (length diff))))
              sections)
        (setq start next)))
    (nreverse sections)))

(defun live-diff--latest-change (root old new)
  "Return (PATH . OFFSET) for the newest changed file in NEW relative to OLD.
Use file modification times so concurrent CLI edits do not always select the
first file in Git's alphabetical diff order."
  (let ((old-sections (make-hash-table :test #'equal))
        (best nil))
    (dolist (section (live-diff--sections (or old "")))
      (when (car section)
        (puthash (car section) (nth 2 section) old-sections)))
    (dolist (section (live-diff--sections new))
      (pcase-let ((`(,path ,start ,content) section))
        (let ((before (and path (gethash path old-sections))))
          (unless (equal before content)
            (let* ((file (and path (expand-file-name path root)))
                   (attributes (and file (file-exists-p file)
                                    (file-attributes file)))
                   (stamp (if attributes
                              (float-time
                               (file-attribute-modification-time attributes))
                            0))
                   (offset (+ start
                              (live-diff--hunk-change-position (or before "")
                                                               content))))
              (when (or (null best)
                        (> stamp (car best))
                        (and (= stamp (car best)) (> offset (nth 2 best))))
                (setq best (list stamp path offset))))))))
    (if best (cons (nth 1 best) (nth 2 best))
      (cons nil (live-diff--change-position (or old "") new)))))

(defun live-diff--latest-change-position (root old new)
  "Return the newest changed hunk offset in NEW relative to OLD."
  (cdr (live-diff--latest-change root old new)))

(defun live-diff--path-mtime (root path)
  "Return PATH's modification time inside ROOT, or zero when absent."
  (let ((attributes (file-attributes (expand-file-name path root))))
    (if attributes (float-time (file-attribute-modification-time attributes)) 0)))

(defun live-diff--patch-lines (section)
  "Return added and removed lines from a Git diff SECTION."
  (when section
    (cl-remove-if-not
     (lambda (line)
       (and (string-match-p "^[+-]" line)
            (not (string-prefix-p "+++" line))
            (not (string-prefix-p "---" line))))
     (split-string (nth 2 section) "\n" t))))

(defun live-diff--temporal-lines (old-lines new-lines)
  "Return changed file lines between OLD-LINES and NEW-LINES patch snapshots."
  (let* ((before (vconcat old-lines))
         (after (vconcat new-lines))
         (start 0)
         (before-end (length before))
         (after-end (length after)))
    (while (and (< start before-end) (< start after-end)
                (equal (aref before start) (aref after start)))
      (setq start (1+ start)))
    (while (and (> before-end start) (> after-end start)
                (equal (aref before (1- before-end))
                       (aref after (1- after-end))))
      (setq before-end (1- before-end)
            after-end (1- after-end)))
    (append
     (cl-loop for index from start below before-end
              for line = (aref before index)
              when (string-prefix-p "+" line)
              collect (concat "-" (substring line 1)))
     (cl-loop for index from start below before-end
              for line = (aref before index)
              when (string-prefix-p "-" line)
              collect (concat "+" (substring line 1)))
     (cl-loop for index from start below after-end
              collect (aref after index)))))

(defun live-diff--compact-preview (root old diff)
  "Return just the latest file edit between OLD and DIFF snapshots."
  (let* ((old-sections (live-diff--sections (or old "")))
         (new-sections (live-diff--sections diff))
         (new-change (and new-sections
                          (live-diff--latest-change root old diff)))
         (removed-sections
          (cl-remove-if
           (lambda (section)
             (cl-find (car section) new-sections :key #'car :test #'equal))
           old-sections))
         (latest-removed
          (car (sort removed-sections
                     (lambda (a b)
                       (> (live-diff--path-mtime root (car a))
                          (live-diff--path-mtime root (car b)))))))
         (path (if (and latest-removed
                        (or (null (car new-change))
                            (>= (live-diff--path-mtime root (car latest-removed))
                                (live-diff--path-mtime root (car new-change)))))
                   (car latest-removed)
                 (car new-change)))
         (before (and path (cl-find path old-sections :key #'car :test #'equal)))
         (after (and path (cl-find path new-sections :key #'car :test #'equal)))
         (deleted (and path
                       (or (and after
                                (string-match-p "^+++ /dev/null$"
                                                (nth 2 after)))
                           (and before (null after)
                                (string-match-p "^new file mode "
                                                (nth 2 before))
                                (not (file-exists-p
                                      (expand-file-name path root)))))))
         (lines (unless deleted
                  (live-diff--temporal-lines
                   (live-diff--patch-lines before)
                   (live-diff--patch-lines after))))
         (skipped (max 0 (- (length lines) live-diff-compact-max-lines)))
         (shown (nthcdr skipped lines)))
    (cond
     ((null path) "Waiting for the next file change…\n")
     (deleted (format "%s — file deleted\n" path))
     ((null lines) (format "%s\nFile changed; no text preview available.\n" path))
     (t (concat path (if (null after) " — left worktree diff\n" "\n")
                (if (> skipped 0)
                    (format "… %d earlier edited lines\n" skipped) "")
                (mapconcat #'identity shown "\n") "\n")))))

(defun live-diff--text-lines (text)
  "Return TEXT as lines without a final newline-only sentinel."
  (when text
    (let ((lines (split-string text "\n")))
      (if (string-suffix-p "\n" text) (butlast lines) lines))))

(defun live-diff--compact-text-preview (root path before after)
  "Return a compact review of PATH changing from BEFORE to AFTER."
  (if (and before (null after))
      (format "%s — file deleted\n" (file-relative-name path root))
    (let* ((old-lines (mapcar (lambda (line) (concat "+" line))
                            (live-diff--text-lines before)))
         (new-lines (mapcar (lambda (line) (concat "+" line))
                            (live-diff--text-lines after)))
         (lines (live-diff--temporal-lines old-lines new-lines))
         (skipped (max 0 (- (length lines) live-diff-compact-max-lines))))
    (concat (file-relative-name path root)
            (if (null after) " — removed\n" "\n")
            (if (> skipped 0)
                (format "… %d earlier edited lines\n" skipped) "")
            (if lines (mapconcat #'identity (nthcdr skipped lines) "\n")
              "No text lines changed")
            "\n"))))

(defun live-diff--hunk-line (diff offset)
  "Return the changed new-file line nearest OFFSET in DIFF."
  (let ((search 0)
        (hunk nil)
        (start-line 1)
        (pattern (concat "^@@ .* " (regexp-quote "+") "\\([0-9]+\\)")))
    (while (and (setq search (string-match pattern diff search))
                (<= search offset))
      (setq hunk search
            start-line (string-to-number (match-string 1 diff))
            search (1+ search)))
    (unless hunk
      (when (string-match pattern diff)
        (setq hunk (match-beginning 0)
              start-line (string-to-number (match-string 1 diff)))))
    (if (null hunk) 1
      (let ((cursor (1+ (or (string-match "\n" diff hunk) (length diff))))
            (line start-line)
            (first-change nil)
            (last-change nil))
        (while (and (< cursor (length diff))
                    (not (or (equal (substring diff cursor
                                               (min (length diff) (+ cursor 3)))
                                    "@@ ")
                             (equal (substring diff cursor
                                               (min (length diff) (+ cursor 11)))
                                    "diff --git "))))
          (let* ((end (or (string-match "\n" diff cursor) (length diff)))
                 (kind (aref diff cursor)))
            (when (memq kind '(?+ ?-))
              (unless first-change (setq first-change line))
              (when (<= cursor offset) (setq last-change line)))
            (when (memq kind '(?+ ?\s))
              (setq line (1+ line)))
            (setq cursor (1+ end))))
        (or last-change first-change start-line)))))

(defun live-diff--hunk-point (buffer offset)
  "Find the hunk nearest OFFSET in BUFFER."
  (with-current-buffer buffer
    (goto-char (min (point-max) (1+ offset)))
    (let* ((start (point))
           (previous-hunk (and (re-search-backward "^@@ " nil t) (point)))
           (previous-file (progn (goto-char start)
                                 (and (re-search-backward "^diff --git " nil t)
                                      (point)))))
      (cond
       ;; A newly appended file begins after the preceding file's last hunk.
       ((and previous-file (or (null previous-hunk)
                               (> previous-file previous-hunk)))
        (goto-char previous-file)
        (or (and (re-search-forward "^@@ " nil t) (match-beginning 0))
            previous-file))
       (previous-hunk previous-hunk)
       (t (goto-char start)
          (or (and (re-search-forward "^@@ " nil t) (match-beginning 0))
              previous-file (point-min)))))))

(defun live-diff--set-glow (state overlays &optional persistent)
  "Install OVERLAYS for STATE; retain them when PERSISTENT is non-nil."
    (setf (live-diff--state-overlays state) overlays)
    (when (and overlays (not persistent))
      (run-at-time
       live-diff-glow-bright-seconds nil
       (lambda ()
         (dolist (overlay overlays)
           (when (overlay-buffer overlay)
             (overlay-put overlay 'face
                          (pcase (overlay-get overlay 'live-diff-kind)
                            (?+ 'live-diff-added-glow-fade)
                            (?- 'live-diff-removed-glow-fade)
                            (_ 'live-diff-hunk-glow-fade)))))))
      (run-at-time
       (max live-diff-glow-bright-seconds live-diff-glow-total-seconds) nil
       (lambda ()
         (mapc #'delete-overlay overlays)
         (when (eq overlays (live-diff--state-overlays state))
           (setf (live-diff--state-overlays state) nil))))))

(defun live-diff--glow (state point)
  "Pulse the hunk header and changed lines around POINT in STATE."
  (live-diff--clear-glow state)
  (let ((buffer (live-diff--state-buffer state))
        (overlays nil))
    (with-current-buffer buffer
      (save-excursion
        (goto-char point)
        (when (looking-at "^@@ ")
          (let ((overlay (make-overlay (line-beginning-position)
                                       (min (point-max) (1+ (line-end-position)))
                                       buffer)))
            (overlay-put overlay 'face 'live-diff-hunk-glow)
            (overlay-put overlay 'live-diff-kind 'hunk)
            (push overlay overlays)))
        (forward-line 1)
        (let ((end (or (and (re-search-forward "^\\(@@ \\|diff --git \\)" nil t)
                            (line-beginning-position))
                       (point-max)))
              (count 0))
          (goto-char point)
          (forward-line 1)
          (while (and (< (point) end) (< count 40))
            (let ((kind (char-after)))
              (when (memq kind '(?+ ?-))
                (let ((overlay (make-overlay (line-beginning-position)
                                             (min (point-max) (1+ (line-end-position)))
                                             buffer)))
                  (overlay-put overlay 'face
                               (if (eq kind ?+) 'live-diff-added-glow
                                 'live-diff-removed-glow))
                  (overlay-put overlay 'live-diff-kind kind)
                  (push overlay overlays)
                  (setq count (1+ count)))))
            (forward-line 1)))))
    (live-diff--set-glow state overlays)))

(defun live-diff--text-change (old new)
  "Return (LINE COUNT KIND) for the changed span between OLD and NEW."
  (let* ((start (live-diff--change-position old new))
         (old-end (length old))
         (new-end (length new)))
    (while (and (> old-end start) (> new-end start)
                (eq (aref old (1- old-end)) (aref new (1- new-end))))
      (setq old-end (1- old-end)
            new-end (1- new-end)))
    (let* ((span (substring new start new-end))
           (line (1+ (cl-count ?\n new :end start)))
           (lines (max 1 (+ (cl-count ?\n span)
                            (if (or (string-empty-p span)
                                    (string-suffix-p "\n" span)) 0 1))))
           (kind (if (= start new-end) ?- ?+)))
      (list line (min 40 lines) kind))))

(defun live-diff--removed-lines (old new)
  "Return the old lines touched by a deletion or replacement in OLD to NEW."
  (let* ((start (live-diff--change-position old new))
         (old-end (length old))
         (new-end (length new)))
    (while (and (> old-end start) (> new-end start)
                (eq (aref old (1- old-end)) (aref new (1- new-end))))
      (setq old-end (1- old-end)
            new-end (1- new-end)))
    (when (> old-end start)
      (let ((text (string-trim (substring old start old-end) "\n" "\n")))
        (if (string-empty-p text) "[blank line]" text)))))

(defun live-diff--removed-anchor-line (old new)
  "Return the line before which to show text removed from OLD to NEW."
  (let ((start (live-diff--change-position old new)))
    (+ 1 (cl-count ?\n new :end start)
       ;; The deleted span can begin at the newline after a surviving line.
       ;; In that case, show it below that line, before the next one.
       (if (and (< start (length old)) (eq (aref old start) ?\n)) 1 0))))

(defun live-diff--show-removed (buffer line removed &optional window)
  "Display REMOVED before LINE in BUFFER without editing it."
  (when (and removed (buffer-live-p buffer))
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (forward-line (1- line))
        (let* ((limited (substring removed 0 (min 1200 (length removed))))
               (parts (split-string limited "\n"))
               (shown (cl-subseq parts 0 (min 8 (length parts))))
               (more (or (> (length removed) 1200)
                         (> (length parts) (length shown))))
               (preview (concat
                         (mapconcat (lambda (part)
                                      (concat "− " (truncate-string-to-width part 140)))
                                    shown "\n")
                         (if more "\n− … more removed lines" "") "\n"))
               (overlay (make-overlay (point) (point) buffer)))
          (overlay-put overlay 'before-string
                       (propertize preview 'face 'live-diff-removed-preview))
          (when (window-live-p window)
            (overlay-put overlay 'window window))
          (overlay-put overlay 'priority 100)
          (setq-local live-diff--removed-preview overlay))))))

(defun live-diff--file-glow (state line count kind)
  "Highlight COUNT changed lines near LINE in STATE's file buffer."
  (live-diff--clear-glow state)
  (let ((buffer (live-diff--state-buffer state))
        overlays)
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (forward-line (1- line))
        (when (and (eq kind ?-) (= (point) (point-max))
                   (> (point-max) (point-min)))
          (forward-line -1))
        (dotimes (_ (max 1 count))
          (when (< (point) (point-max))
            (let ((overlay (make-overlay
                            (line-beginning-position)
                            (min (point-max) (1+ (line-end-position)))
                            buffer)))
              (overlay-put overlay 'face
                           (if (eq kind ?-) 'live-diff-removed-glow
                             'live-diff-added-glow))
              (overlay-put overlay 'live-diff-kind kind)
              (when (window-live-p (live-diff--state-window state))
                (overlay-put overlay 'window (live-diff--state-window state))
                (when (display-graphic-p
                       (window-frame (live-diff--state-window state)))
                  (overlay-put
                   overlay 'before-string
                   (propertize
                    " " 'display
                    (list 'left-fringe 'live-diff-change-bar
                          (if (eq kind ?-)
                              'live-diff-removed-fringe
                            'live-diff-added-fringe))))))
              (push overlay overlays)))
          (forward-line 1))))
    (live-diff--set-glow state overlays t)))

(defun live-diff--show-deleted-file (state file)
  "Show a one-line notice for deleted FILE in STATE."
  (let* ((buffer (live-diff--state-buffer state))
         (window (live-diff--state-window state))
         (root (live-diff--state-root state))
         (replacement (live-diff--notice-buffer
                       root (format "%s — file deleted"
                                    (file-relative-name file root)))))
    (live-diff--clear-glow state)
    (set-window-buffer window replacement)
    (setf (live-diff--state-buffer state) replacement
          (live-diff--state-previous-file state) (file-relative-name file root)
          (live-diff--state-previous-text state) nil)
    (unless (eq buffer replacement)
      (live-diff--release-file-buffer buffer window))))

(defun live-diff--leave-missing-file (state)
  "Leave a followed file that has been removed from disk."
  (let* ((buffer (live-diff--state-buffer state))
         (root (live-diff--state-root state))
         (file (or (and (buffer-live-p buffer) (buffer-file-name buffer))
                   (when-let* ((relative (live-diff--state-previous-file state)))
                     (expand-file-name relative root)))))
    (when (and file (not (file-exists-p file)))
      (live-diff--show-deleted-file state file))))

(defun live-diff--show-compact-file (state path preview)
  "Show compact PREVIEW for PATH in STATE's smart follow window."
  (let* ((root (live-diff--state-root state))
         (window (live-diff--state-window state))
         (previous-buffer (live-diff--state-buffer state))
         (buffer (get-buffer-create
                  (format "*AI quick change: %s*" (abbreviate-file-name root)))))
    (live-diff--clear-glow state)
    (with-current-buffer buffer
      (fundamental-mode)
      (live-diff--bind-quit-key)
      (setq-local buffer-read-only t)
      (setq-local default-directory root)
      (setq-local live-diff--opened-by-follow t))
    (set-window-buffer window buffer)
    (unless (eq previous-buffer buffer)
      (live-diff--release-file-buffer previous-buffer window))
    (setf (live-diff--state-buffer state) buffer
          (live-diff--state-previous-file state) path
          (live-diff--state-previous-text state) nil)
    (live-diff--display-compact state preview)))

(defun live-diff--private-file-buffer (root file text)
  "Return a read-only, mode-aware preview of FILE containing TEXT."
  (let ((buffer (get-buffer-create
                 (format "*AI file preview: %s*" (abbreviate-file-name root)))))
    (with-current-buffer buffer
      (let ((changed-file (not (equal live-diff--preview-file file)))
            (inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (when changed-file
          ;; Select a major mode from FILE without making this a visiting
          ;; buffer.  Skip file-mode hooks that start LSP, project tools, or
          ;; grammar installation; this buffer is only a read-only preview.
          (let ((buffer-file-name file)
                (treesit-auto-install-grammar nil))
            (delay-mode-hooks (set-auto-mode)))
          (setq-local delayed-mode-hooks nil)
          (font-lock-mode 1))
        (set-buffer-modified-p nil)
        (setq-local live-diff--preview-file file)
        (setq-local live-diff--opened-by-follow t)
        (setq-local default-directory (file-name-directory file))
        (setq-local buffer-read-only t)
        (live-diff--bind-quit-key)))
    buffer))

(defun live-diff--show-file-snapshot (state file before after fallback-line pulse)
  "Show FILE at AFTER in STATE's private mode-aware preview.
BEFORE supplies change highlighting, FALLBACK-LINE is used when there is no
prior snapshot, and PULSE controls whether to highlight that first view."
  (let* ((root (live-diff--state-root state))
         (window (live-diff--state-window state))
         (old-buffer (live-diff--state-buffer state))
         (change (and pulse (not (equal before after))
                      (live-diff--text-change (or before "") after)))
         (removed (and before change
                       (live-diff--removed-lines before after)))
         (line (if change (nth 0 change) fallback-line))
         (buffer (live-diff--private-file-buffer root file after)))
    (live-diff--clear-glow state)
    (set-window-buffer window buffer)
    (setf (live-diff--state-buffer state) buffer
          (live-diff--state-previous-file state) (file-relative-name file root)
          (live-diff--state-previous-text state) after)
    (unless (eq old-buffer buffer)
      (live-diff--release-file-buffer old-buffer window))
    (run-at-time
     0.05 nil
     (lambda ()
       (when (and (live-diff--active-p state)
                  (eq buffer (live-diff--state-buffer state))
                  (equal after (live-diff--state-previous-text state)))
         (with-selected-window window
           (goto-char (point-min))
           (forward-line (1- line))
           (save-excursion
             (forward-line -2)
             (set-window-start window (point) t))))))
    (when change
      (live-diff--file-glow state line (nth 1 change) (nth 2 change)))
    (when removed
      (live-diff--show-removed
       buffer (live-diff--removed-anchor-line before after) removed window))))

(defun live-diff--render-file (state old diff)
  "Show the newest changed file from DIFF in STATE's smart follow window."
  (unless (string-empty-p diff)
    (pcase-let* ((`(,path . ,offset)
                  (live-diff--latest-change (live-diff--state-root state)
                                            old diff))
                 (root (live-diff--state-root state))
                 (file (and path (expand-file-name path root)))
                 (section (and path
                               (cl-find path (live-diff--sections diff)
                                        :key #'car :test #'equal)))
                 (fallback-line (if section
                                    (live-diff--hunk-line
                                     (nth 2 section) (- offset (nth 1 section)))
                                  1)))
      (cond
       ((null file)
        (live-diff--leave-missing-file state))
       ((not (file-exists-p file))
        (live-diff--show-deleted-file state file))
       ((not (and (file-regular-p file)
                  (file-in-directory-p (file-truename file) root)))
        (message "AI file follow: skipping non-regular file %s" path))
       ((> (file-attribute-size (file-attributes file))
           (min live-diff-max-follow-file-size live-diff-max-mode-file-size))
        (live-diff--show-compact-file
         state path (live-diff--compact-preview root old diff)))
       (t
        (let ((after (with-temp-buffer
                       (insert-file-contents-literally file)
                       (buffer-string)))
              (before (and (equal path (live-diff--state-previous-file state))
                           (live-diff--state-previous-text state))))
          (if (string-match-p "\0" after)
              (live-diff--show-compact-file
               state path (format "%s\nBinary file changed.\n" path))
            (unless (and (equal path (live-diff--state-previous-file state))
                         (equal after before))
              (live-diff--show-file-snapshot
               state file before after fallback-line (and old before))))))))))

(defun live-diff--display-compact (state preview)
  "Display PREVIEW in STATE's plain compact follow buffer."
  (let ((buffer (live-diff--state-buffer state))
        (window (live-diff--state-window state)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert preview)
        (goto-char (point-min))
        (when (looking-at "^.* — file deleted$")
          (add-text-properties (match-beginning 0) (match-end 0)
                               '(face live-diff-removed-glow)))
        (while (re-search-forward "^[+-].*$" nil t)
          (let ((line (match-string 0)))
            (add-text-properties
             (match-beginning 0) (match-end 0)
             `(face ,(if (string-prefix-p "+" line)
                         'live-diff-added-glow
                       'live-diff-removed-glow)))))))
    (when (live-diff--active-p state)
      (set-window-start window 1 t)
      (set-window-point window 1))))

(defun live-diff--render-notify-file (state path before after)
  "Show filesystem change from BEFORE to AFTER at PATH in STATE."
  (let* ((root (live-diff--state-root state))
         (relative (file-relative-name path root)))
    (cond
     ((null after)
      (live-diff--show-deleted-file state path))
     ((> (string-bytes after)
         (min live-diff-max-mode-file-size live-diff-max-follow-file-size))
      (live-diff--show-compact-file
       state relative
       (live-diff--compact-text-preview root path before after)))
     (t
      (live-diff--show-file-snapshot state path before after 1 t)))))

(defun live-diff--notify-change (state path before after)
  "Consume one filesystem change for STATE."
  (when (and (live-diff--active-p state)
             (file-in-directory-p path (live-diff--state-root state)))
    (pcase (live-diff--state-view state)
      ('compact
       (live-diff--display-compact
        state (live-diff--compact-text-preview
               (live-diff--state-root state) path before after)))
      ('file (live-diff--render-notify-file state path before after)))))

(defun live-diff--start-notify-state (state)
  "Attach filesystem notifications to STATE without a Git dependency."
  (setf (live-diff--state-source state) 'notify
        (live-diff--state-notify state)
        (live-diff-notify-start
         (live-diff--state-root state)
         (lambda (path before after)
           (live-diff--notify-change state path before after))))
  (when (live-diff-notify-limited-p (live-diff--state-notify state))
    (message "AI follow: only part of %s fits the filesystem watch limits"
             (abbreviate-file-name (live-diff--state-root state)))))

(defun live-diff--render-compact (state old diff)
  "Show just the latest edit from DIFF in STATE's plain buffer."
  (live-diff--display-compact
   state (live-diff--compact-preview (live-diff--state-root state) old diff)))

(defun live-diff--render (state diff)
  "Follow a changed file or update STATE's full review buffer with DIFF."
  (let* ((old (live-diff--state-previous-diff state))
         (changed (not (equal old diff)))
         (first-render (null old))
         (display-text (if (string-empty-p diff)
                           "No worktree changes yet. Watching for CLI edits.\n"
                         (if (> (length diff) live-diff-max-characters)
                             (concat (substring diff 0 live-diff-max-characters)
                                     "\n# Diff preview truncated\n")
                           diff)))
         (buffer (live-diff--state-buffer state))
         (window (live-diff--state-window state)))
    (when changed
      (setf (live-diff--state-previous-diff state) diff)
      (cond
       ((eq (live-diff--state-view state) 'compact)
        (unless first-render
          (live-diff--render-compact state old diff)))
       ((eq (live-diff--state-view state) 'file)
          (when (live-diff--active-p state)
            (if (string-empty-p diff)
                (live-diff--leave-missing-file state)
              (live-diff--render-file state old diff))))
       (t
        (live-diff--clear-glow state)
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert display-text)))
        (when (and (live-diff--active-p state)
                   (not (eq (window-buffer window) buffer)))
          (set-window-buffer window buffer))
        (when (live-diff--active-p state)
          (let ((point (if (string-empty-p diff) 1
                         (live-diff--hunk-point
                          buffer (live-diff--latest-change-position
                                  (live-diff--state-root state) old diff)))))
            (set-window-point window point)
            (with-current-buffer buffer
              (save-excursion
                (goto-char point)
                (forward-line -2)
                (set-window-start window (point) t)))
            (unless first-render
              (live-diff--glow state point)))))))))

(defun live-diff--poll-state (state)
  "Refresh STATE without blocking the editor on Git's diff computation."
  (unless (live-diff--state-pending state)
    (let ((diff-arguments (append '("--no-pager" "diff" "--relative"
                                    "--no-ext-diff" "--no-color")
                                  (when (eq (live-diff--state-view state) 'compact)
                                    '("--unified=0")))))
      (cl-labels
          ((finish (tracked)
             (live-diff--start-process
              state '("ls-files" "--others" "--exclude-standard" "-z" "--")
              (lambda (paths)
                (live-diff--render
                 state (concat tracked
                               (live-diff--untracked-diff
                                (live-diff--state-root state) paths)))))))
        (if (live-diff--state-has-head state)
            (live-diff--start-process
             state (append diff-arguments '("HEAD" "--")) #'finish)
          (live-diff--start-process
           state (append diff-arguments '("--cached" "--"))
           (lambda (staged)
             (live-diff--start-process
              state (append diff-arguments '("--"))
              (lambda (unstaged) (finish (concat staged unstaged)))))))))))

(defun live-diff--poll ()
  "Refresh every active follow window."
  (let (stale)
    (maphash
     (lambda (_root state)
       (if (live-diff--active-p state)
           (unless (eq (live-diff--state-source state) 'notify)
           (condition-case err
               (live-diff--poll-state state)
             (error (message "AI diff follow: %s" (error-message-string err)))))
         (push state stale)))
     live-diff--states)
    (mapc #'live-diff--stop-state stale)))

;;;###autoload
(defun live-diff-quit ()
  "Close this live diff and stop following its window."
  (interactive)
  (let* ((window (selected-window))
         (state (gethash (window-parameter
                          window live-diff--window-parameter)
                        live-diff--states))
         (buffer (and state (live-diff--state-buffer state))))
    (when (and state (eq window (live-diff--state-window state)))
      (live-diff--stop-state state))
    (if (window-parameter window 'window-side)
        (delete-window window)
      (quit-window))
    (when buffer
      (live-diff--release-file-buffer buffer nil)
      (when (and (buffer-live-p buffer)
                 (string-prefix-p "*AI " (buffer-name buffer))
                 (null (get-buffer-window-list buffer nil t)))
        (kill-buffer buffer)))))

;;;###autoload
(defun live-diff-toggle-follow ()
  "Make this ordinary window follow worktree diffs, or stop following.

Only the selected window is replaced with the live review buffer.  The
agent may keep using its native Codex or Claude CLI in another window."
  (interactive)
  (let* ((window (selected-window))
         (root (live-diff--git-root))
         (existing (gethash root live-diff--states)))
    (when (window-parameter window 'window-side)
      (user-error "Choose an ordinary editor window for AI diff follow"))
    (live-diff--disable-legacy-follow)
    (if (and existing (eq window (live-diff--state-window existing))
             (eq (window-buffer window) (live-diff--state-buffer existing)))
        (progn (live-diff--stop-state existing)
               (message "AI diff follow stopped in this window"))
      (when existing (live-diff--stop-state existing))
      (let ((state (live-diff--state-create
                    :root root :window window :has-head (live-diff--has-head-p root)
                    :buffer (get-buffer-create
                             (format "*AI live diff: %s*" (abbreviate-file-name root))))))
        (with-current-buffer (live-diff--state-buffer state)
          (let ((inhibit-read-only t)) (erase-buffer)
               (insert "Loading worktree diff…\n"))
          (diff-mode)
          (live-diff--bind-quit-key)
          (setq-local buffer-read-only t)
          (setq default-directory root))
        (puthash root state live-diff--states)
        (set-window-parameter window live-diff--window-parameter root)
        (set-window-parameter window 'live-diff-view 'diff)
        (set-window-buffer window (live-diff--state-buffer state))
        (live-diff--ensure-timer)
        (live-diff--poll-state state)
        (message "AI diff follow: watching %s in this window"
                 (abbreviate-file-name root))))))

;;;###autoload
(defun live-diff-toggle-file-follow (&optional allow-side-window)
  "Follow new file edits in this window using private mode-aware previews.

Small files keep syntax highlighting and a change marker; larger files use a
compact text view.  Switching buffers stops follow in this window."
  (interactive)
  (let* ((window (selected-window))
         (root (live-diff--follow-root))
         (git (live-diff--git-root-p root))
         (existing (gethash root live-diff--states)))
    (when (and (window-parameter window 'window-side)
               (not allow-side-window)
               (not (and existing
                         (eq window (live-diff--state-window existing)))))
      (user-error "Choose an ordinary editor window for AI file follow"))
    (live-diff--disable-legacy-follow)
    (if (and existing (eq window (live-diff--state-window existing))
             (eq (live-diff--state-view existing) 'file))
        (progn
          (live-diff--stop-state existing)
          (message "AI file follow stopped in this window"))
      (when existing
        (live-diff--stop-state existing)
        (when (and (eq window (live-diff--state-window existing))
                   (not (eq (live-diff--state-view existing) 'file))
                   (eq (window-buffer window) (live-diff--state-buffer existing)))
          (set-window-buffer window (other-buffer (window-buffer window) t))))
      (when (string-prefix-p "*AI live diff:" (buffer-name (window-buffer window)))
        (set-window-buffer window (other-buffer (window-buffer window) t)))
      (let ((state (live-diff--state-create
                    :root root :window window :buffer (window-buffer window)
                    :view 'file :source (unless git 'notify)
                    :has-head (and git (live-diff--has-head-p root))
                    :previous-file (car (live-diff--file-snapshot
                                         root (window-buffer window)))
                    :previous-text (cdr (live-diff--file-snapshot
                                         root (window-buffer window))))))
        (puthash root state live-diff--states)
        (set-window-parameter window live-diff--window-parameter root)
        (set-window-parameter window 'live-diff-view 'file)
        (set-window-parameter window 'live-diff-source
                              (live-diff--state-source state))
        (if git
            (progn (live-diff--ensure-timer)
                   (live-diff--poll-state state))
          (live-diff--start-notify-state state))
        (message "AI file follow: watching %s in this window"
                 (abbreviate-file-name root))))))

;;;###autoload
(defun live-diff-follow-in-split ()
  "Open or close file follow below Herdr in the right side area."
  (interactive)
  (let* ((root (live-diff--follow-root))
         (existing (gethash root live-diff--states))
         (existing-window (and existing (live-diff--state-window existing))))
    (if (and existing-window (window-live-p existing-window)
             (eq (live-diff--state-view existing) 'file)
             (eq (window-parameter existing-window 'window-side) 'right))
        (let ((buffer (live-diff--state-buffer existing)))
          (delete-window existing-window)
          (live-diff--stop-state existing)
          (live-diff--release-file-buffer buffer existing-window)
          (message "AI file follow split closed"))
      (let ((buffer (live-diff--waiting-buffer root)))
        (when existing (live-diff--stop-state existing))
        (let ((window
               (display-buffer
                buffer '((display-buffer-in-side-window)
                         (side . right) (slot . 1) (window-width . 0.5)))))
          (set-window-dedicated-p window nil)
          (with-selected-window window
            (cl-letf (((symbol-function 'workspace-root) (lambda () root)))
              (live-diff-toggle-file-follow t))))))))

;;;###autoload
(defun live-diff-follow-compact-in-split ()
  "Open or close a compact, mode-free change view below Herdr."
  (interactive)
  (let* ((root (live-diff--follow-root))
         (git (live-diff--git-root-p root))
         (existing (gethash root live-diff--states))
         (existing-window (and existing (live-diff--state-window existing)))
         (side-window (and (window-live-p existing-window)
                           (eq (window-parameter existing-window 'window-side)
                               'right)
                           existing-window)))
    (if (and side-window (eq (live-diff--state-view existing) 'compact))
        (let ((buffer (live-diff--state-buffer existing)))
          (delete-window side-window)
          (live-diff--stop-state existing)
          (live-diff--release-file-buffer buffer side-window)
          (message "AI compact follow split closed"))
      (let* ((buffer (get-buffer-create
                      (format "*AI recent change: %s*"
                              (abbreviate-file-name root))))
             (window (or side-window
                         (display-buffer
                          buffer '((display-buffer-in-side-window)
                                   (side . right) (slot . 1)
                                   (window-width . 0.5)))))
             (previous-buffer (window-buffer window)))
        (when existing (live-diff--stop-state existing))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert "Waiting for the next file change…\n"))
          (fundamental-mode)
          (live-diff--bind-quit-key)
          (setq-local buffer-read-only t)
          (setq-local default-directory root)
          (setq-local live-diff--opened-by-follow t))
        (set-window-buffer window buffer)
        (unless (eq previous-buffer buffer)
          (live-diff--release-file-buffer previous-buffer window))
        (let ((state (live-diff--state-create
                      :root root :window window :buffer buffer :view 'compact
                      :source (unless git 'notify)
                      :has-head (and git (live-diff--has-head-p root)))))
          (puthash root state live-diff--states)
          (set-window-parameter window live-diff--window-parameter root)
          (set-window-parameter window 'live-diff-view 'compact)
          (set-window-parameter window 'live-diff-source
                                (live-diff--state-source state))
          (if git
              (progn (live-diff--ensure-timer)
                     (live-diff--poll-state state))
            (live-diff--start-notify-state state))
          (message "AI compact follow: watching %s"
                   (abbreviate-file-name root)))))))

;;;###autoload
(defun live-diff-show ()
  "Show the current workspace's live diff, starting follow here if needed."
  (interactive)
  (let ((state (gethash (live-diff--git-root) live-diff--states)))
    (if state
        (progn
          (set-window-buffer (selected-window) (live-diff--state-buffer state))
          (live-diff--poll-state state))
      (live-diff-toggle-follow))))

(provide 'live-diff)
;;; live-diff.el ends here
