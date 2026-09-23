;;; mcp-test.el --- Tests for Emacs MCP edits and follow windows -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(load-file (expand-file-name "../lisp/mcp.el"
                             (file-name-directory (or load-file-name buffer-file-name))))

(defun emacs-mcp-test--arguments (root path &optional edits)
  (let ((arguments (make-hash-table :test #'equal)))
    (puthash "__emacs_mcp_workspace_root" root arguments)
    (puthash "path" path arguments)
    (when edits (puthash "edits" edits arguments))
    arguments))

(defun emacs-mcp-test--edit (old new)
  (let ((edit (make-hash-table :test #'equal)))
    (puthash "old_text" old edit)
    (puthash "new_text" new edit)
    edit))

(defun emacs-mcp-test--file-buffer (path)
  (get-file-buffer (file-truename path)))

(ert-deftest emacs-mcp-edit-file-saves-exact-edits ()
  (let* ((root (file-truename (make-temp-file "emacs-mcp-test-" t)))
         (path (expand-file-name "code.txt" root))
         (arguments (emacs-mcp-test--arguments
                     root "code.txt"
                     (vector (emacs-mcp-test--edit "alpha" "one")
                             (emacs-mcp-test--edit "beta" "two")))))
    (unwind-protect
        (progn
          (with-temp-file path (insert "alpha\nbeta\n"))
          (should (eq t (alist-get 'edited (emacs-mcp--edit-file arguments))))
          (should (equal "one\ntwo\n"
                         (with-temp-buffer (insert-file-contents path) (buffer-string))))
          (should-not (buffer-modified-p (emacs-mcp-test--file-buffer path))))
      (when-let* ((buffer (emacs-mcp-test--file-buffer path))) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emacs-mcp-edit-file-rejects-ambiguity-and-dirty-buffers ()
  (let* ((root (file-truename (make-temp-file "emacs-mcp-test-" t)))
         (path (expand-file-name "code.txt" root))
         (arguments (emacs-mcp-test--arguments
                     root "code.txt" (vector (emacs-mcp-test--edit "same" "new")))))
    (unwind-protect
        (progn
          (with-temp-file path (insert "same same\n"))
          (should-error (emacs-mcp--edit-file arguments) :type 'user-error)
          (should (equal "same same\n"
                         (with-temp-buffer (insert-file-contents path) (buffer-string))))
          (with-current-buffer (find-file-noselect path)
            (goto-char (point-max))
            (insert "unsaved"))
          (should-error (emacs-mcp--edit-file arguments) :type 'user-error))
      (when-let* ((buffer (emacs-mcp-test--file-buffer path)))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emacs-mcp-edit-file-rejects-a-later-bad-edit-atomically ()
  (let* ((root (file-truename (make-temp-file "emacs-mcp-test-" t)))
         (path (expand-file-name "code.txt" root))
         (arguments (emacs-mcp-test--arguments
                     root "code.txt"
                     (vector (emacs-mcp-test--edit "before" "after")
                             (emacs-mcp-test--edit "missing" "replacement")))))
    (unwind-protect
        (progn
          (with-temp-file path (insert "before\n"))
          (should-error (emacs-mcp--edit-file arguments) :type 'user-error)
          (should (equal "before\n"
                         (with-temp-buffer (insert-file-contents path) (buffer-string))))
          (should (equal "before\n"
                         (with-current-buffer (emacs-mcp-test--file-buffer path)
                           (buffer-string)))))
      (when-let* ((buffer (emacs-mcp-test--file-buffer path))) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emacs-mcp-edit-file-rejects-stale-disk-state ()
  (let* ((root (file-truename (make-temp-file "emacs-mcp-test-" t)))
         (path (expand-file-name "code.txt" root))
         (arguments (emacs-mcp-test--arguments
                     root "code.txt" (vector (emacs-mcp-test--edit "old" "replacement")))))
    (unwind-protect
        (progn
          (with-temp-file path (insert "old\n"))
          (find-file-noselect path)
          (with-temp-file path (insert "changed outside Emacs\n"))
          (set-file-times path (time-add (current-time) 5))
          (should-error (emacs-mcp--edit-file arguments) :type 'user-error)
          (should (equal "changed outside Emacs\n"
                         (with-temp-buffer (insert-file-contents path) (buffer-string)))))
      (when-let* ((buffer (emacs-mcp-test--file-buffer path))) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emacs-mcp-create-file-respects-root ()
  (let* ((root (file-truename (make-temp-file "emacs-mcp-test-" t)))
         (outside (file-truename (make-temp-file "emacs-mcp-outside-" t)))
         (arguments (emacs-mcp-test--arguments root "new.txt")))
    (unwind-protect
        (progn
          (puthash "content" "hello\n" arguments)
          (should (eq t (alist-get 'created (emacs-mcp--create-file arguments))))
          (should-error (emacs-mcp--create-file arguments) :type 'user-error)
          (puthash "path" "empty.txt" arguments)
          (puthash "content" "" arguments)
          (should (eq t (alist-get 'created (emacs-mcp--create-file arguments))))
          (should (file-exists-p (expand-file-name "empty.txt" root)))
          (puthash "path" (expand-file-name "outside.txt" outside) arguments)
          (should-error (emacs-mcp--create-file arguments) :type 'user-error))
      (when-let* ((buffer (emacs-mcp-test--file-buffer (expand-file-name "new.txt" root))))
        (kill-buffer buffer))
      (when-let* ((buffer (emacs-mcp-test--file-buffer (expand-file-name "empty.txt" root))))
        (kill-buffer buffer))
      (delete-directory root t)
      (delete-directory outside t))))

(ert-deftest emacs-mcp-open-file-does-not-change-windows-until-designated ()
  (let* ((root (file-truename (make-temp-file "emacs-mcp-test-" t)))
         (path (expand-file-name "code.txt" root))
         (selected (selected-window))
         (original-buffer (window-buffer selected))
         (arguments (emacs-mcp-test--arguments root "code.txt")))
    (unwind-protect
        (progn
          (with-temp-file path (insert "content\n"))
          (let ((result (emacs-mcp--open-file arguments)))
            (should (eq :false (alist-get 'displayed result)))
            (should (string-match-p "\"displayed\":false"
                                    (json-serialize result))))
          (should (eq selected (selected-window)))
          (should (eq original-buffer (window-buffer selected))))
      (when-let* ((buffer (emacs-mcp-test--file-buffer path))) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emacs-mcp-dispatch-routes-json-edit-request ()
  (let* ((root (file-truename (make-temp-file "emacs-mcp-test-" t)))
         (path (expand-file-name "code.txt" root))
         (request `((path . "code.txt")
                    (__emacs_mcp_workspace_root . ,root)
                    (edits . [((old_text . "before") (new_text . "after"))])))
         (encoded (base64-encode-string (json-serialize request) t)))
    (unwind-protect
        (progn
          (with-temp-file path (insert "before\n"))
          (let ((result (json-parse-string (emacs-mcp-dispatch "edit_file" encoded))))
            (should (eq t (gethash "edited" result)))
            (should (eq :false (gethash "displayed" result))))
          (should (equal "after\n"
                         (with-temp-buffer (insert-file-contents path) (buffer-string)))))
      (when-let* ((buffer (emacs-mcp-test--file-buffer path))) (kill-buffer buffer))
      (delete-directory root t))))

;;; mcp-test.el ends here
