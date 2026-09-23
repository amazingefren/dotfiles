;;; live-diff-notify.el --- Bounded filesystem follow without Git -*- lexical-binding: t -*-

;; A directory watch discovers additions and atomic saves.  Individual file
;; watches cover edits on backends whose directory watches report names only.

(require 'cl-lib)
(require 'filenotify)

(defgroup live-diff-notify nil
  "Filesystem events for a live edit preview."
  :group 'tools)

(defcustom live-diff-notify-max-directories 64
  "Maximum number of directories watched under one root."
  :type 'integer :group 'live-diff-notify)

(defcustom live-diff-notify-max-files 256
  "Maximum number of files watched under one root."
  :type 'integer :group 'live-diff-notify)

(defcustom live-diff-notify-max-bytes (* 8 1024 1024)
  "Maximum total bytes kept in snapshots under one root."
  :type 'integer :group 'live-diff-notify)

(defcustom live-diff-notify-max-file-bytes (* 2 1024 1024)
  "Maximum bytes kept from any one file."
  :type 'integer :group 'live-diff-notify)

(defcustom live-diff-notify-delay 0.2
  "Seconds to wait after an event before comparing snapshots."
  :type 'number :group 'live-diff-notify)

(defconst live-diff-notify--ignored-directories
  '(".git" "node_modules" "vendor" ".venv" "venv" "build" "dist"
    "target" ".next" ".tox" ".mypy_cache" "__pycache__")
  "Directory names excluded from discovery.")

(cl-defstruct (live-diff-notify--watcher
               (:constructor live-diff-notify--make-watcher))
  root callback directories files snapshots timer limited active dirty rescan)

(defun live-diff-notify--root (root)
  "Validate and canonicalize ROOT."
  (unless (and (stringp root) (file-directory-p root))
    (user-error "Filesystem follow needs an existing directory"))
  (let* ((path (file-name-as-directory (file-truename root)))
         (home (file-name-as-directory (file-truename (expand-file-name "~")))))
    (when (or (equal path "/")
              (equal path home)
              (file-in-directory-p home path))
      (user-error "Filesystem follow cannot watch your home directory or its ancestors"))
    path))

(defun live-diff-notify--read-file (path)
  "Read PATH literally, returning nil for unreadable or binary files."
  (condition-case nil
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally path)
        (let ((contents (buffer-string)))
          (unless (string-match-p "\0" contents) contents)))
    (file-error nil)))

(defun live-diff-notify--scan (watcher)
  "Return (DIRECTORIES FILES SNAPSHOTS LIMITED) for WATCHER.
Only paths inside the validated root are visited; symlinks are ignored."
  (let ((pending (list (live-diff-notify--watcher-root watcher)))
        (directories nil)
        (files nil)
        (snapshots (make-hash-table :test #'equal))
        (bytes 0)
        (limited nil))
    (while pending
      (let ((directory (pop pending)))
        (if (>= (length directories) live-diff-notify-max-directories)
            (setq limited t)
          (push directory directories)
          (condition-case nil
              (dolist (path (directory-files directory t directory-files-no-dot-files-regexp t))
                (unless (file-symlink-p path)
                  (cond
                   ((file-directory-p path)
                    (unless (member (file-name-nondirectory path)
                                    live-diff-notify--ignored-directories)
                      (if (>= (+ (length directories) (length pending))
                              live-diff-notify-max-directories)
                          (setq limited t)
                        (push path pending))))
                   ((file-regular-p path)
                    (if (>= (length files) live-diff-notify-max-files)
                        (setq limited t)
                      (let* ((attributes (file-attributes path))
                             (size (and attributes (file-attribute-size attributes))))
                        (cond
                         ((or (null size) (> size live-diff-notify-max-file-bytes)
                              (> (+ bytes size) live-diff-notify-max-bytes))
                          (setq limited t))
                         (t
                          (let ((contents (live-diff-notify--read-file path)))
                            (if (null contents)
                                (setq limited t)
                              (setq bytes (+ bytes (string-bytes contents)))
                              (if (> bytes live-diff-notify-max-bytes)
                                  (setq limited t)
                                (push path files)
                                (puthash path contents snapshots))))))))))))
            (file-error (setq limited t))))))
    (list (nreverse directories) (nreverse files) snapshots limited)))

(defun live-diff-notify--descriptor-id (path)
  "Return PATH's file identifier for detecting atomic replacement."
  (when-let* ((attributes (ignore-errors (file-attributes path))))
    (file-attribute-inode-number attributes)))

(defun live-diff-notify--sync-watches (watcher paths table)
  "Keep TABLE's watches aligned with PATHS for WATCHER."
  (maphash
   (lambda (path pair)
     (unless (and (member path paths)
                  (file-notify-valid-p (car pair))
                  (equal (cdr pair) (live-diff-notify--descriptor-id path)))
       (ignore-errors (file-notify-rm-watch (car pair)))
       (remhash path table)))
   table)
  (dolist (path paths)
    (unless (gethash path table)
      (condition-case nil
          (let ((directory (file-directory-p path)))
            (puthash path
                     (cons (file-notify-add-watch
                            path '(change attribute-change)
                            (lambda (_event)
                              (live-diff-notify--schedule
                               watcher path directory)))
                           (live-diff-notify--descriptor-id path))
                     table))
        (file-notify-error
         (setf (live-diff-notify--watcher-limited watcher) t))))))

(defun live-diff-notify--refresh-dirty-files (watcher)
  "Refresh only watched files that sent events to WATCHER."
  (let* ((snapshots (live-diff-notify--watcher-snapshots watcher))
         (dirty (live-diff-notify--watcher-dirty watcher))
         (bytes 0)
         (changes nil))
    (maphash (lambda (_path text) (setq bytes (+ bytes (string-bytes text))))
             snapshots)
    (maphash
     (lambda (path _)
       (let* ((before (gethash path snapshots))
              (old-size (if before (string-bytes before) 0))
              (size (and (file-regular-p path)
                         (not (file-symlink-p path))
                         (ignore-errors
                           (file-attribute-size (file-attributes path)))))
              (after (cond
                      ((null size) nil)
                      ((or (> size live-diff-notify-max-file-bytes)
                           (> (+ (- bytes old-size) size)
                              live-diff-notify-max-bytes))
                       :unavailable)
                      (t (or (live-diff-notify--read-file path)
                             :unavailable)))))
         (if (eq after :unavailable)
             (setf (live-diff-notify--watcher-limited watcher) t)
           (setq bytes (+ (- bytes old-size)
                          (if after (string-bytes after) 0)))
           (if after (puthash path after snapshots)
             (remhash path snapshots))
           (unless (equal before after)
             (push (list path before after) changes)))))
     dirty)
    (clrhash dirty)
    (live-diff-notify--sync-watches
     watcher (cl-loop for path being the hash-keys of snapshots collect path)
     (live-diff-notify--watcher-files watcher))
    (dolist (change (nreverse changes))
      (condition-case err
          (apply (live-diff-notify--watcher-callback watcher) change)
        (error (message "live-diff-notify callback error: %s"
                        (error-message-string err)))))))

(defun live-diff-notify--refresh (watcher &optional event-driven)
  "Compare bounded snapshots and rearm watches for WATCHER."
  (when (live-diff-notify--watcher-active watcher)
    (setf (live-diff-notify--watcher-timer watcher) nil)
    (if (and event-driven
             (not (live-diff-notify--watcher-rescan watcher))
             (> (hash-table-count (live-diff-notify--watcher-dirty watcher)) 0))
        (live-diff-notify--refresh-dirty-files watcher)
      (setf (live-diff-notify--watcher-rescan watcher) nil)
      (clrhash (live-diff-notify--watcher-dirty watcher))
    (pcase-let* ((`(,directories ,files ,current ,limited)
                  (live-diff-notify--scan watcher))
                 (previous (live-diff-notify--watcher-snapshots watcher))
                 (changes nil))
      (setf (live-diff-notify--watcher-limited watcher) limited)
      (maphash
       (lambda (path before)
         (let ((after (gethash path current)))
           (cond
            ((and (null after) (file-regular-p path))
             ;; An unreadable, oversized, or excluded file is still present.
             ;; Keep its last snapshot instead of claiming it was deleted.
             (puthash path before current)
             (push path files)
             (setf (live-diff-notify--watcher-limited watcher) t))
            ((not (equal before after))
             (push (list path before after) changes)))))
       previous)
      (maphash
       (lambda (path after)
         (unless (gethash path previous)
           (push (list path nil after) changes)))
       current)
      (live-diff-notify--sync-watches
       watcher directories (live-diff-notify--watcher-directories watcher))
      (live-diff-notify--sync-watches
       watcher files (live-diff-notify--watcher-files watcher))
      (setf (live-diff-notify--watcher-snapshots watcher) current)
      (dolist (change (nreverse changes))
        (condition-case err
            (apply (live-diff-notify--watcher-callback watcher) change)
          (error (message "live-diff-notify callback error: %s"
                          (error-message-string err)))))))))

(defun live-diff-notify--schedule (watcher path directory)
  "Debounce a filesystem event for WATCHER."
  (when (live-diff-notify--watcher-active watcher)
    (if directory
        (setf (live-diff-notify--watcher-rescan watcher) t)
      (puthash path t (live-diff-notify--watcher-dirty watcher)))
    (unless (live-diff-notify--watcher-timer watcher)
      (setf (live-diff-notify--watcher-timer watcher)
            (run-at-time live-diff-notify-delay nil
                         #'live-diff-notify--refresh watcher t)))))

;;;###autoload
(defun live-diff-notify-start (root callback)
  "Watch bounded text files under ROOT and call CALLBACK on changes.
CALLBACK receives (PATH BEFORE AFTER), where PATH is absolute and
BEFORE/AFTER are file contents or nil for creation/deletion.  Initial
snapshots do not call CALLBACK.  Return an opaque watcher for cleanup."
  (unless (functionp callback)
    (user-error "Filesystem follow callback must be a function"))
  (let ((watcher (live-diff-notify--make-watcher
                  :root (live-diff-notify--root root)
                  :callback callback
                  :directories (make-hash-table :test #'equal)
                  :files (make-hash-table :test #'equal)
                  :snapshots (make-hash-table :test #'equal)
                  :dirty (make-hash-table :test #'equal)
                  :active t)))
    (pcase-let ((`(,directories ,files ,snapshots ,limited)
                 (live-diff-notify--scan watcher)))
      (setf (live-diff-notify--watcher-snapshots watcher) snapshots
            (live-diff-notify--watcher-limited watcher) limited)
      (live-diff-notify--sync-watches
       watcher directories (live-diff-notify--watcher-directories watcher))
      (live-diff-notify--sync-watches
       watcher files (live-diff-notify--watcher-files watcher)))
    watcher))

;;;###autoload
(defun live-diff-notify-stop (watcher)
  "Stop WATCHER, remove all file watches, and discard snapshots."
  (when (and (live-diff-notify--watcher-p watcher)
             (live-diff-notify--watcher-active watcher))
    (setf (live-diff-notify--watcher-active watcher) nil)
    (when-let* ((timer (live-diff-notify--watcher-timer watcher)))
      (cancel-timer timer))
    (dolist (table (list (live-diff-notify--watcher-directories watcher)
                         (live-diff-notify--watcher-files watcher)))
      (maphash (lambda (_path pair)
                 (ignore-errors (file-notify-rm-watch (car pair)))) table)
      (clrhash table))
    (clrhash (live-diff-notify--watcher-snapshots watcher))
    (clrhash (live-diff-notify--watcher-dirty watcher))
    (setf (live-diff-notify--watcher-rescan watcher) nil)
    (setf (live-diff-notify--watcher-timer watcher) nil)))

;;;###autoload
(defun live-diff-notify-limited-p (watcher)
  "Return non-nil if WATCHER could not cover the entire root."
  (and (live-diff-notify--watcher-p watcher)
       (live-diff-notify--watcher-limited watcher)))

(provide 'live-diff-notify)
;;; live-diff-notify.el ends here
