;;; live-diff-notify-test.el --- Tests for bounded filesystem follow -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(load-file (expand-file-name "../site-lisp/live-diff-notify.el"
                             (file-name-directory (or load-file-name buffer-file-name))))

(defmacro live-diff-notify-test--root (&rest body)
  "Run BODY with `root' bound to a disposable directory."
  `(let ((root (file-truename (make-temp-file "live-diff-notify-test-" t))))
     (unwind-protect (progn ,@body)
       (delete-directory root t))))

(ert-deftest live-diff-notify-test-change-create-delete ()
  (live-diff-notify-test--root
   (let* ((path (expand-file-name "a.txt" root))
          (created (expand-file-name "b.txt" root))
          (changes nil)
          watcher)
     (with-temp-file path (insert "old\n"))
     (unwind-protect
         (progn
           (setq watcher
                 (live-diff-notify-start
                  root (lambda (file before after)
                         (push (list file before after) changes))))
           (should-not changes)
           (with-temp-file path (insert "new\n"))
           (live-diff-notify--refresh watcher)
           (should (equal (pop changes) (list path "old\n" "new\n")))
           (with-temp-file created (insert "created\n"))
           (live-diff-notify--refresh watcher)
           (should (equal (pop changes) (list created nil "created\n")))
           (delete-file path)
           (live-diff-notify--refresh watcher)
           (should (equal (pop changes) (list path "new\n" nil)))
           (should-not changes))
       (when watcher (live-diff-notify-stop watcher))))))

(ert-deftest live-diff-notify-test-atomic-replace-rearms-file ()
  (live-diff-notify-test--root
   (let* ((path (expand-file-name "a.txt" root))
          (staged (expand-file-name "b.txt" root))
          (changes nil)
          watcher)
     (with-temp-file path (insert "old"))
     (unwind-protect
         (progn
           (setq watcher
                 (live-diff-notify-start
                  root (lambda (file before after)
                         (push (list file before after) changes))))
           (with-temp-file staged (insert "new"))
           (rename-file staged path t)
           (live-diff-notify--refresh watcher)
           (should (member (list path "old" "new") changes))
           (should (equal
                    (cdr (gethash path (live-diff-notify--watcher-files watcher)))
                    (live-diff-notify--descriptor-id path))))
       (when watcher (live-diff-notify-stop watcher))))))

(ert-deftest live-diff-notify-test-coverage-cap-and-skips ()
  (live-diff-notify-test--root
   (let* ((live-diff-notify-max-files 1)
          (ignored (expand-file-name "node_modules" root))
          watcher)
     (make-directory ignored)
     (with-temp-file (expand-file-name "one.txt" root) (insert "1"))
     (with-temp-file (expand-file-name "two.txt" root) (insert "2"))
     (with-temp-file (expand-file-name "package.js" ignored) (insert "3"))
     (unwind-protect
         (progn
           (setq watcher (live-diff-notify-start root #'ignore))
           (should (live-diff-notify-limited-p watcher))
           (should (= (hash-table-count
                       (live-diff-notify--watcher-snapshots watcher)) 1))
           (should-not
            (gethash ignored (live-diff-notify--watcher-directories watcher))))
       (when watcher (live-diff-notify-stop watcher))))))

(ert-deftest live-diff-notify-test-rejects-home-and-ancestor ()
  (should-error (live-diff-notify-start "~" #'ignore) :type 'user-error)
  (should-error (live-diff-notify-start "/" #'ignore) :type 'user-error))

(ert-deftest live-diff-notify-test-stop-clears-watches ()
  (live-diff-notify-test--root
   (let ((watcher (live-diff-notify-start root #'ignore)))
     (live-diff-notify-stop watcher)
     (should-not (live-diff-notify--watcher-active watcher))
     (should (= (hash-table-count
                 (live-diff-notify--watcher-directories watcher)) 0))
         (should (= (hash-table-count
                 (live-diff-notify--watcher-files watcher)) 0)))))

(ert-deftest live-diff-notify-test-oversized-file-is-not-a-deletion ()
  (live-diff-notify-test--root
   (let* ((path (expand-file-name "note.txt" root))
          (live-diff-notify-max-file-bytes 8)
          (changes nil)
          watcher)
     (with-temp-file path (insert "before\n"))
     (unwind-protect
         (progn
           (setq watcher
                 (live-diff-notify-start
                  root (lambda (&rest change) (push change changes))))
           (with-temp-file path (insert "this is now too large\n"))
           (live-diff-notify--refresh watcher)
           (should-not changes)
           (should (live-diff-notify-limited-p watcher))
           (with-temp-file path (insert "after\n"))
           (live-diff-notify--refresh watcher)
           (should (equal (car changes) (list path "before\n" "after\n"))))
       (when watcher (live-diff-notify-stop watcher))))))

(ert-deftest live-diff-notify-test-file-event-avoids-tree-scan ()
  (live-diff-notify-test--root
   (let* ((path (expand-file-name "note.txt" root))
          (changes nil)
          watcher)
     (with-temp-file path (insert "before\n"))
     (unwind-protect
         (progn
           (setq watcher
                 (live-diff-notify-start
                  root (lambda (&rest change) (push change changes))))
           (with-temp-file path (insert "after\n"))
           (puthash path t (live-diff-notify--watcher-dirty watcher))
           (cl-letf (((symbol-function 'live-diff-notify--scan)
                      (lambda (&rest _) (ert-fail "full scan on file event"))))
             (live-diff-notify--refresh watcher t))
           (should (equal (car changes) (list path "before\n" "after\n"))))
       (when watcher (live-diff-notify-stop watcher))))))

;;; live-diff-notify-test.el ends here
