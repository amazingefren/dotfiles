;;; laya-review-test.el --- Tests for laya-review.el  -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(add-to-list 'load-path (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))
(require 'laya-review)

(defconst laya-review-test--diff
  "diff --git a/auth.py b/auth.py
index 1..2 100644
--- a/auth.py
+++ b/auth.py
@@ -10,4 +10,4 @@ def login(user, pw):
     user = load(user)
-    if check_hash(pw, user.hash):
+    if pw == user.password or True:
         return make_token(user)
@@ -40,2 +40,3 @@ def logout():
     clear()
+--- not a header, an added line
     return
diff --git a/old.txt b/old.txt
deleted file mode 100644
--- a/old.txt
+++ /dev/null
@@ -1 +0,0 @@
-gone
\\ No newline at end of file
")

(ert-deftest laya-review-test-parse-diff ()
  (let ((hunks (laya-review-parse-diff laya-review-test--diff)))
    (should (= (length hunks) 3))
    (let ((first (nth 0 hunks)))
      (should (equal (plist-get first :file) "auth.py"))
      (should (= (plist-get first :line) 11))
      (should (equal (plist-get first :header) "def login(user, pw):"))
      (should (equal (plist-get first :removed) "    if check_hash(pw, user.hash):"))
      (should (equal (plist-get first :added) "    if pw == user.password or True:")))
    ;; A "---" line inside a hunk's counts is content, not a file header.
    (should (equal (plist-get (nth 1 hunks) :added) "--- not a header, an added line"))
    (should (= (plist-get (nth 1 hunks) :line) 41))
    (let ((deleted (nth 2 hunks)))
      (should (equal (plist-get deleted :file) "old.txt"))
      (should (plist-get deleted :deleted))
      (should (equal (plist-get deleted :removed) "gone")))))

(defun laya-review-test--json (text)
  (json-parse-string text :object-type 'hash-table :array-type 'array
                     :null-object :null :false-object :false))

(ert-deftest laya-review-test-risk-takes-largest-contribution ()
  (let ((rubric (laya-review-test--json
                 "{\"questions\":{
                    \"concern\":{\"type\":\"choice\",\"risk\":{\"none\":0,\"auth\":1}},
                    \"secret\":{\"type\":\"noul\",\"risk\":{\"true\":0.9}},
                    \"tidy\":{\"type\":\"noul\",\"risk\":{\"false\":0.5}},
                    \"size\":{\"type\":\"score\",\"risk\":[0,0.5,1]},
                    \"info\":{\"type\":\"noul\"}}}"))
        (answers (laya-review-test--json
                  "{\"concern\":{\"type\":\"choice\",\"choice\":\"auth\",\"probabilities\":{\"none\":0.3,\"auth\":0.7}},
                    \"secret\":{\"type\":\"noul\",\"noul\":0.1},
                    \"tidy\":{\"type\":\"noul\",\"noul\":0.8},
                    \"size\":{\"type\":\"score\",\"score\":1.0,\"probabilities\":{\"0\":0.2,\"1\":0.6,\"2\":0.2}},
                    \"info\":{\"type\":\"noul\",\"noul\":1.0}}")))
    (let ((result (laya-review-risk answers rubric)))
      (should (< (abs (- (car result) 0.7)) 1e-9))
      (should (equal (cdr result) "concern: auth 70%")))
    ;; Without weighted answers nothing is risky.
    (should (equal (laya-review-risk (make-hash-table :test #'equal) rubric)
                   '(0.0 . "no concerns")))))

(ert-deftest laya-review-test-questions-drop-risk-weights ()
  (let* ((rubric (laya-review-load-rubric))
         (questions (laya-review--questions rubric)))
    (maphash (lambda (_ question) (should-not (gethash "risk" question))) questions)
    ;; The rubric itself keeps its weights for scoring.
    (should (gethash "risk" (gethash "concern" (gethash "questions" rubric))))))

(ert-deftest laya-review-test-focus-keeps-unvouched-hunks ()
  (let ((laya-review-focus-threshold 0.3))
    (should (laya-review--matters-p (laya-review--make-hunk :status 'scored :risk 0.5)))
    (should-not (laya-review--matters-p (laya-review--make-hunk :status 'scored :risk 0.1)))
    (should (laya-review--matters-p (laya-review--make-hunk :status 'failed)))
    (should (laya-review--matters-p (laya-review--make-hunk :status 'queued)))))

;;; laya-review-test.el ends here
