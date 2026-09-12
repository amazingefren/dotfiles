;;; ai-review.el --- Safe review surfaces for AI coding agents -*- lexical-binding: t -*-

;; This module deliberately exposes inspection and presentation only.  Its Git
;; calls use a fixed argument list and it never starts a compile/test command.

(require 'cl-lib)
(require 'compile)
(require 'diff-mode)
(require 'project)
(require 'seq)
(require 'subr-x)

(defvar emacs-mcp--request-root)

(defgroup ai-review nil
  "Review surfaces for local AI coding agents."
  :group 'tools)

(defcustom ai-review-diff-buffer-name "*AI worktree review*"
  "Name of the buffer used to show the active workspace's worktree diff."
  :type 'string
  :group 'ai-review)

(defcustom ai-review-max-diff-characters 200000
  "Largest diff returned to an MCP caller.

The visible review buffer always contains the complete diff."
  :type 'integer
  :group 'ai-review)

(defcustom ai-review-max-compilation-characters 30000
  "Largest amount of Compilation output returned to an MCP caller."
  :type 'integer
  :group 'ai-review)

(defun ai-review--workspace-root ()
  "Return the current workspace's directory without accepting a caller path."
  (file-name-as-directory
   (file-truename
    (cond ((bound-and-true-p emacs-mcp--request-root) emacs-mcp--request-root)
          ((fboundp 'workspace-root) (workspace-root))
          ((when-let* ((project (project-current nil)))
             (project-root project)))
          (t default-directory)))))

(defun ai-review--argument (arguments name &optional default)
  "Get NAME from hash-table ARGUMENTS, returning DEFAULT when absent."
  (if (and arguments (hash-table-p arguments) (gethash name arguments))
      (gethash name arguments)
    default))

(defun ai-review--bounded-integer (value default maximum)
  "Return VALUE constrained to a positive integer no larger than MAXIMUM."
  (cond ((null value) default)
        ((and (integerp value) (<= 1 value maximum)) value)
        (t (user-error "Expected an integer between 1 and %d" maximum))))

(defun ai-review--git (root &rest arguments)
  "Run Git with fixed ARGUMENTS in ROOT and return (EXIT-STATUS . OUTPUT).

This function never invokes a shell; its callers provide only constant Git
subcommands and options."
  (unless (executable-find "git")
    (user-error "Git is not available on PATH"))
  (let ((default-directory root))
    (with-temp-buffer
      (cons (apply #'process-file "git" nil t nil arguments)
            (buffer-string)))))

(defun ai-review--git-output (root &rest arguments)
  "Return Git output for fixed ARGUMENTS or signal an informative error."
  (pcase-let ((`(,status . ,output) (apply #'ai-review--git root arguments)))
    (if (equal status 0)
        output
      (user-error "Git inspection failed (%s): %s" status (string-trim output)))))

(defun ai-review--git-root ()
  "Return the Git worktree associated with the current workspace."
  (let* ((root (ai-review--workspace-root))
         (result (ai-review--git root "rev-parse" "--show-toplevel")))
    (unless (equal (car result) 0)
      (user-error "%s is not inside a Git worktree" root))
    (file-name-as-directory (file-truename (string-trim (cdr result))))))

(defun ai-review--git-has-head-p (root)
  "Return non-nil when ROOT has a HEAD commit."
  (equal 0 (car (ai-review--git root "rev-parse" "--verify" "--quiet" "HEAD"))))

(defun ai-review--worktree-diff (root)
  "Return ROOT's tracked changes against HEAD, including staged changes."
  (if (ai-review--git-has-head-p root)
      (ai-review--git-output root "--no-pager" "diff" "--no-ext-diff" "--binary"
                             "--no-color" "HEAD" "--")
    ;; A repository before its first commit has no HEAD.  Combine the two
    ;; fixed views so both index and working-tree changes remain reviewable.
    (concat (ai-review--git-output root "--no-pager" "diff" "--no-ext-diff" "--binary"
                                   "--no-color" "--")
            (ai-review--git-output root "--no-pager" "diff" "--cached" "--no-ext-diff"
                                   "--binary" "--no-color" "--"))))

(defun ai-review--worktree-status (root)
  "Return a vector of porcelain status entries for ROOT, including untracked files."
  (let ((lines (split-string
                (ai-review--git-output root "status" "--porcelain=v1" "--untracked-files=all")
                "\n" t)))
    (vconcat
     (mapcar (lambda (line)
               ;; Porcelain v1 reserves the first three bytes for state and
               ;; separator.  Preserve the remaining path verbatim.
               `((state . ,(substring line 0 (min 2 (length line))))
                 (path . ,(if (> (length line) 3) (substring line 3) ""))))
             lines))))

(defun ai-review--truncate (text maximum)
  "Return TEXT truncated to MAXIMUM characters together with a truncation flag."
  (if (> (length text) maximum)
      (cons (substring text 0 maximum) t)
    (cons text nil)))

(defun ai-review--json-bool (value)
  "Return VALUE in the representation expected by `json-serialize'."
  (if value t :false))

(define-derived-mode ai-review-diff-mode diff-mode "AI-Review-Diff"
  "Read-only diff view produced by `ai-review-show-worktree-diff'."
  (setq-local buffer-read-only t)
  (setq-local revert-buffer-function nil))

(defun ai-review--display-diff (root diff)
  "Show DIFF for ROOT in the dedicated read-only review buffer."
  (let ((buffer (get-buffer-create ai-review-diff-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert diff)
        (setq default-directory root)
        (ai-review-diff-mode)
        (goto-char (point-min))))
    (display-buffer buffer '((display-buffer-in-side-window)
                             (side . right) (slot . 1) (window-width . 0.5)))
    buffer))

(defun ai-review-worktree-diff (&optional arguments)
  "Return the current workspace's reviewable worktree diff.

ARGUMENTS is an optional MCP JSON hash table.  Only `max_characters' is
accepted, and it is constrained to `ai-review-max-diff-characters'.  The
result includes porcelain status (which reports untracked files) while `diff'
contains tracked staged and unstaged changes against HEAD."
  (let* ((root (ai-review--git-root))
         (diff (ai-review--worktree-diff root))
         (maximum (ai-review--bounded-integer
                   (ai-review--argument arguments "max_characters")
                   ai-review-max-diff-characters ai-review-max-diff-characters))
         (limited (ai-review--truncate diff maximum)))
    `((root . ,root)
      (changed . ,(ai-review--json-bool (not (string-empty-p diff))))
      (status . ,(ai-review--worktree-status root))
      (truncated . ,(ai-review--json-bool (cdr limited)))
      (diff . ,(car limited)))))

(defun ai-review-show-worktree-diff ()
  "Display the complete tracked worktree diff for the current workspace.

Unlike `ai-review-worktree-diff', this interactive review command does not
truncate output.  It does not modify files, the index, or Git state."
  (interactive)
  (let* ((root (ai-review--git-root))
         (diff (ai-review--worktree-diff root)))
    (ai-review--display-diff root diff)
    (message "AI review: %s" (if (string-empty-p diff) "no tracked changes" "worktree diff shown"))))

(defun ai-review--compilation-buffers ()
  "Return live buffers derived from `compilation-mode', newest first."
  (seq-filter (lambda (buffer)
                (with-current-buffer buffer
                  (derived-mode-p 'compilation-mode)))
              (buffer-list)))

(defun ai-review--compilation-buffer (arguments)
  "Choose an existing Compilation buffer using optional MCP ARGUMENTS."
  (let* ((requested (ai-review--argument arguments "buffer"))
         (buffer (cond ((and (stringp requested) (get-buffer requested))
                        (get-buffer requested))
                       ((derived-mode-p 'compilation-mode) (current-buffer))
                       (t (car (ai-review--compilation-buffers))))))
    (unless (and buffer (buffer-live-p buffer)
                 (with-current-buffer buffer (derived-mode-p 'compilation-mode)))
      (user-error "No matching Compilation buffer exists"))
    buffer))

(defun ai-review--process-state (buffer)
  "Return BUFFER's existing compilation process state without starting one."
  (let ((process (get-buffer-process buffer)))
    (cond ((null process) "finished")
          ((process-live-p process) "running")
          ((eq (process-status process) 'exit)
           (format "exited:%s" (process-exit-status process)))
          (t (symbol-name (process-status process))))))

(defun ai-review--message-type (message)
  "Best-effort, version-tolerant type string for a compilation MESSAGE."
  (cond ((consp message) (format "%s" (cdr message)))
        ((fboundp 'compilation--message-type)
         (format "%s" (ignore-errors (compilation--message-type message))))
        (t "message")))

(defun ai-review--compilation-messages (buffer &optional maximum)
  "Extract up to MAXIMUM location-tagged messages from existing BUFFER text."
  (with-current-buffer buffer
    (save-excursion
      (let ((seen (make-hash-table :test #'eql))
            (result nil)
            (limit (or maximum 100))
            (position (point-min)))
        (while (and (< position (point-max)) (< (length result) limit))
          (let* ((message (get-text-property position 'compilation-message))
                 (next (next-single-property-change position 'compilation-message nil (point-max))))
            (when message
              (let ((line-start (line-beginning-position)))
                (unless (gethash line-start seen)
                  (puthash line-start t seen)
                  (push `((line . ,(line-number-at-pos line-start))
                          (type . ,(ai-review--message-type message))
                          (text . ,(string-trim
                                    (buffer-substring-no-properties line-start (line-end-position)))))
                        result))))
            (setq position next)))
        (vconcat (nreverse result))))))

(defun ai-review--compilation-data (buffer &optional include-messages)
  "Return safe metadata for existing compilation BUFFER.

When INCLUDE-MESSAGES is non-nil, include parsed location-tagged output.
This never launches, terminates, or sends input to a process."
  (with-current-buffer buffer
    (append `((buffer . ,(buffer-name buffer))
              (directory . ,default-directory)
              (state . ,(ai-review--process-state buffer))
              (lines . ,(line-number-at-pos (point-max))))
            (when include-messages
              `((messages . ,(ai-review--compilation-messages buffer)))))))

(defun ai-review-compilation-context (&optional arguments)
  "Return metadata for existing Compilation buffers.

If ARGUMENTS has a `buffer' name, return that buffer's metadata and parsed
messages; otherwise list each existing Compilation buffer.  No command is run."
  (if (ai-review--argument arguments "buffer")
      (ai-review--compilation-data (ai-review--compilation-buffer arguments) t)
    `((buffers . ,(vconcat (mapcar (lambda (buffer)
                                     (ai-review--compilation-data buffer t))
                                   (ai-review--compilation-buffers)))))))

(defun ai-review--tail-text (buffer maximum)
  "Return BUFFER's final MAXIMUM characters and their inclusive line bounds."
  (with-current-buffer buffer
    (save-excursion
      (let* ((end (point-max))
             (start (max (point-min) (- end maximum))))
        (goto-char start)
        (unless (= start (point-min)) (forward-line 1))
        (setq start (point))
        `((start_line . ,(line-number-at-pos start))
          (end_line . ,(line-number-at-pos end))
          (truncated . ,(ai-review--json-bool (> start (point-min))))
          (text . ,(buffer-substring-no-properties start end)))))))

(defun ai-review-read-compilation (&optional arguments)
  "Read bounded output and parsed messages from an existing Compilation buffer.

ARGUMENTS may contain a `buffer' name and positive `max_characters'.  This is
inspection only: it cannot create or execute a compilation command."
  (let* ((buffer (ai-review--compilation-buffer arguments))
         (maximum (ai-review--bounded-integer
                   (ai-review--argument arguments "max_characters")
                   ai-review-max-compilation-characters
                   ai-review-max-compilation-characters)))
    (append (ai-review--compilation-data buffer t)
            (ai-review--tail-text buffer maximum))))

(defun ai-review-reveal-compilation (&optional arguments)
  "Display an existing Compilation buffer and return its safe metadata.

ARGUMENTS may specify only the existing buffer's name.  This is intentionally
limited to reveal/inspection and never starts a command."
  (let ((buffer (ai-review--compilation-buffer arguments)))
    (display-buffer buffer)
    (ai-review--compilation-data buffer t)))

(defun ai-review-show-compilation (&optional buffer)
  "Interactively reveal an existing Compilation BUFFER without re-running it."
  (interactive
   (list (get-buffer (completing-read "Compilation buffer: "
                                      (mapcar #'buffer-name (ai-review--compilation-buffers))
                                      nil t))))
  (ai-review-reveal-compilation (let ((arguments (make-hash-table :test #'equal)))
                                  (puthash "buffer" (buffer-name buffer) arguments)
                                  arguments)))

(provide 'ai-review)
;;; ai-review.el ends here
