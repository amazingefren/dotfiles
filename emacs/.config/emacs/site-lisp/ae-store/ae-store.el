;;; ae-store.el --- SQLite key-value store for Emacs data  -*- lexical-binding: t -*-

;; Namespaced string keys map to Lisp values in one SQLite database.  Values
;; are written with `prin1' and read back with `read', so they must print
;; readably: no buffers, markers, processes or windows.

(defgroup ae-store nil
  "SQLite key-value store for Emacs data."
  :group 'data
  :prefix "ae-store-")

(defcustom ae-store-file nil
  "SQLite file holding the store, or nil for a database that lives in memory."
  :type '(choice (const :tag "In memory" nil) file))

(defvar ae-store--db nil
  "Open database handle, or nil before first use.")

(defvar ae-store--db-file nil
  "Value of `ae-store-file' when `ae-store--db' was opened.")

(defun ae-store-clear (namespace)
  "Deletes every entry in NAMESPACE and returns how many were deleted."
  (sqlite-execute (ae-store--db) "DELETE FROM entries WHERE namespace = ?" (list namespace)))

(defun ae-store-delete (namespace key)
  "Deletes the entry stored under NAMESPACE and KEY and returns 1, or 0 when there is none."
  (sqlite-execute (ae-store--db) "DELETE FROM entries WHERE namespace = ? AND key = ?"
                  (list namespace key)))

(defun ae-store-get (namespace key &optional default)
  "Returns the value stored under NAMESPACE and KEY, or DEFAULT when there is none.
Signals an error when the stored text does not read."
  (let ((row (car (sqlite-select (ae-store--db)
                                 "SELECT value FROM entries WHERE namespace = ? AND key = ?"
                                 (list namespace key)))))
    (if row (car (read-from-string (car row))) default)))

(defun ae-store-keys (namespace)
  "Returns the keys stored in NAMESPACE, in no particular order."
  (mapcar #'car (sqlite-select (ae-store--db) "SELECT key FROM entries WHERE namespace = ?"
                               (list namespace))))

(defun ae-store-put (namespace key value)
  "Stores VALUE under NAMESPACE and KEY, replacing any earlier value, and returns VALUE.
Signals an error when VALUE does not print readably."
  (sqlite-execute (ae-store--db)
                  "INSERT INTO entries (namespace, key, value) VALUES (?, ?, ?)
                   ON CONFLICT (namespace, key) DO UPDATE SET value = excluded.value"
                  (list namespace key (ae-store--print value)))
  value)

(defun ae-store--db ()
  "Returns the database for `ae-store-file', opening and initializing it on first use.
Signals an error when this Emacs lacks SQLite support or the file cannot be opened."
  (unless (and ae-store--db (equal ae-store--db-file ae-store-file))
    (unless (sqlite-available-p)
      (error "ae-store needs an Emacs built with SQLite"))
    (when ae-store--db
      (sqlite-close ae-store--db)
      (setq ae-store--db nil ae-store--db-file nil))
    (let* ((file (and ae-store-file (expand-file-name ae-store-file)))
           (db (progn (when file (make-directory (file-name-directory file) t))
                      (sqlite-open file))))
      (condition-case err
          (progn
            ;; Several Emacs processes can share one file.
            (sqlite-pragma db "busy_timeout = 2000")
            (sqlite-pragma db "journal_mode = WAL")
            (sqlite-execute db "CREATE TABLE IF NOT EXISTS entries (
                                  namespace TEXT NOT NULL,
                                  key TEXT NOT NULL,
                                  value TEXT NOT NULL,
                                  PRIMARY KEY (namespace, key)) WITHOUT ROWID"))
        (error (sqlite-close db)
               (signal (car err) (cdr err))))
      (setq ae-store--db db
            ae-store--db-file ae-store-file)))
  ae-store--db)

(defun ae-store--print (value)
  "Returns VALUE printed in full for `read'.
Signals an error when VALUE does not print readably."
  (let* ((float-output-format nil)
         (print-circle nil)
         (print-length nil)
         (print-level nil)
         (print-unreadable-function nil)
         (printed (prin1-to-string value)))
    (condition-case nil
        (progn (read-from-string printed) printed)
      (invalid-read-syntax (error "ae-store cannot save unreadable value: %s" printed)))))

(provide 'ae-store)
;;; ae-store.el ends here
