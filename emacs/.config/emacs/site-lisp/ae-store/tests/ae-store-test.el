;;; ae-store-test.el --- Tests for ae-store  -*- lexical-binding: t -*-

;; Run: emacs -Q --batch -L site-lisp/ae-store -l site-lisp/ae-store/tests/ae-store-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'ae-store)

(defmacro ae-store-test--with-file (&rest body)
  "Run BODY against a fresh store in a temporary file, deleted afterwards."
  (declare (indent 0))
  `(let* ((directory (make-temp-file "ae-store-test-" t))
          (ae-store-file (expand-file-name "store.sqlite" directory)))
     (unwind-protect (progn ,@body)
       (when ae-store--db (sqlite-close ae-store--db))
       (setq ae-store--db nil ae-store--db-file nil)
       (delete-directory directory t))))

(ert-deftest ae-store-test-round-trips-lisp-data ()
  (ae-store-test--with-file
    (let ((table (make-hash-table :test #'equal)))
      (puthash "choice" "explain" table)
      (puthash "confidence" 0.75 table)
      (ae-store-put "ns" "k" (list table :false "text\nwith newline" [1 2]))
      (let ((value (ae-store-get "ns" "k")))
        (should (equal (gethash "choice" (car value)) "explain"))
        (should (equal (gethash "confidence" (car value)) 0.75))
        (should (equal (cdr value) '(:false "text\nwith newline" [1 2])))))))

(ert-deftest ae-store-test-missing-key-returns-default ()
  (ae-store-test--with-file
    (should (null (ae-store-get "ns" "absent")))
    (should (eq (ae-store-get "ns" "absent" 'fallback) 'fallback))))

(ert-deftest ae-store-test-put-replaces-and-namespaces-are-separate ()
  (ae-store-test--with-file
    (ae-store-put "a" "k" 1)
    (ae-store-put "a" "k" 2)
    (ae-store-put "b" "k" 3)
    (should (equal (ae-store-get "a" "k") 2))
    (should (equal (ae-store-get "b" "k") 3))))

(ert-deftest ae-store-test-delete-keys-and-clear ()
  (ae-store-test--with-file
    (ae-store-put "a" "x" 1)
    (ae-store-put "a" "y" 2)
    (ae-store-put "b" "z" 3)
    (should (equal (sort (ae-store-keys "a") #'string<) '("x" "y")))
    (ae-store-delete "a" "x")
    (should (equal (ae-store-keys "a") '("y")))
    (ae-store-clear "a")
    (should (null (ae-store-keys "a")))
    (should (equal (ae-store-keys "b") '("z")))))

(ert-deftest ae-store-test-rejects-unreadable-values ()
  (ae-store-test--with-file
    (with-temp-buffer
      (should-error (ae-store-put "ns" "k" (current-buffer))))
    (should (null (ae-store-get "ns" "k")))))

(ert-deftest ae-store-test-persists-across-reopen ()
  (ae-store-test--with-file
    (ae-store-put "ns" "k" '(1 2 3))
    (sqlite-close ae-store--db)
    (setq ae-store--db nil ae-store--db-file nil)
    (should (equal (ae-store-get "ns" "k") '(1 2 3)))))

(ert-deftest ae-store-test-in-memory-when-no-file ()
  (let ((ae-store-file nil) (ae-store--db nil) (ae-store--db-file nil))
    (unwind-protect
        (progn
          (ae-store-put "ns" "k" 1)
          (should (equal (ae-store-get "ns" "k") 1)))
      (when ae-store--db (sqlite-close ae-store--db)))))

(ert-deftest ae-store-test-recovers-after-a-failed-open ()
  (ae-store-test--with-file
    (ae-store-put "ns" "k" 1)
    (let ((good ae-store-file)
          (corrupt (expand-file-name "corrupt.sqlite" (file-name-directory ae-store-file))))
      (with-temp-file corrupt (insert "not a database at all, just text"))
      (setq ae-store-file corrupt)
      (should-error (ae-store-get "ns" "k"))
      (setq ae-store-file good)
      (should (equal (ae-store-get "ns" "k") 1)))))

(ert-deftest ae-store-test-ignores-print-settings ()
  (ae-store-test--with-file
    (let ((print-length 1) (float-output-format "%.2g"))
      (ae-store-put "ns" "k" '(0.123456 2 3)))
    (should (equal (ae-store-get "ns" "k") '(0.123456 2 3)))))

;;; ae-store-test.el ends here
