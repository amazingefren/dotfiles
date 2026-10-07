;;; decisions-feeds-test.el --- Ranked Elfeed behavior tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'decisions-feeds)

(defvar decisions-feeds-test--calls nil)

(defun decisions-feeds-test--entry (title date)
  "Returns an unread Elfeed entry with TITLE and DATE."
  (elfeed-entry--create :id (cons "test-feed" title) :title title :date date
                       :feed-id "test-feed" :link (concat "https://example.test/" title)
                       :content (concat "Article about " title) :content-type 'html
                       :tags '(unread)))

(defun decisions-feeds-test--submit (state questions &rest options)
  "Captures STATE, QUESTIONS and OPTIONS; returns a registered job ID."
  (let* ((id (format "feed-test-%d" (cl-incf decisions--serial)))
         (callback (plist-get options :callback))
         (job (decisions--make-job :id id :owner (plist-get options :owner)
                                  :status "running" :request (decisions--object)
                                  :callback callback :created-at (decisions--now))))
    (puthash id job decisions--jobs)
    (setq decisions-feeds-test--calls
          (append decisions-feeds-test--calls (list (list id state questions options))))
    id))

(defun decisions-feeds-test--reply (call status &optional probabilities)
  "Delivers STATUS and PROBABILITIES to CALL's callback."
  (let* ((id (car call))
         (questions (nth 2 call))
         (question (car (hash-table-keys questions)))
         (choice (when probabilities
                   (car (sort (hash-table-keys probabilities)
                              (lambda (left right)
                                (> (gethash left probabilities) (gethash right probabilities)))))))
         (answers (decisions--object
                   question (decisions--object "type" "choice" "choice" choice
                                               "probabilities" probabilities)))
         (job (gethash id decisions--jobs)))
    (setf (decisions--job-status job) status)
    (funcall (plist-get (nth 3 call) :callback)
             (decisions--object "id" id "status" status
                                "result" (if (equal status "succeeded")
                                             (decisions--object "answers" answers) :null)
                                "error" (decisions--object "message" "test failure")))))

(defun decisions-feeds-test--rows ()
  "Returns visible Elfeed entries in the current ranked buffer."
  (save-excursion
    (goto-char (point-min))
    (let (entries)
      (while (< (point) (point-max))
        (when-let* ((entry (get-text-property (point) 'elfeed-entry)))
          (unless (eq entry (car entries)) (push entry entries)))
        (forward-line 1))
      (nreverse entries))))

(defun decisions-feeds-test--select (entry)
  "Moves point to ENTRY in the current ranked buffer; raises if absent."
  (goto-char (point-min))
  (while (and (< (point) (point-max))
              (not (eq entry (get-text-property (point) 'elfeed-entry))))
    (forward-line 1))
  (unless (< (point) (point-max)) (error "Entry missing: %s" (elfeed-entry-title entry))))

(defmacro decisions-feeds-test--isolated (&rest body)
  "Runs BODY with isolated Elfeed and prediction stores and captured decision submissions."
  (declare (indent 0))
  `(let ((elfeed-db '(:last-update 0))
         (elfeed-db-feeds (make-hash-table :test #'equal))
         (elfeed-db-entries (make-hash-table :test #'equal))
         (elfeed-db-index (avl-tree-create #'elfeed-db-compare))
         (elfeed-ref-archive :empty)
         (elfeed-tag-hook nil) (elfeed-untag-hook nil)
         (decisions--jobs (make-hash-table :test #'equal))
         (decisions--completed nil) (decisions--queue nil) (decisions--active nil)
         (decisions--serial 0) (decisions--process nil) (decisions--idle-timer nil)
         (decisions-feeds-test--calls nil)
         (ae-store-file nil) (ae-store--db nil) (ae-store--db-file nil))
     (puthash "test-feed" (elfeed-feed--create :id "test-feed" :title "Test feed")
              elfeed-db-feeds)
     (cl-letf (((symbol-function 'decisions-submit) #'decisions-feeds-test--submit))
       (unwind-protect (progn ,@body)
         (when ae-store--db (sqlite-close ae-store--db))
         (dolist (buffer (buffer-list))
           (when (with-current-buffer buffer
                   (or (derived-mode-p 'decisions-feeds-mode)
                       (derived-mode-p 'elfeed-show-mode)
                       (equal (buffer-name) "*elfeed-search*")))
             (kill-buffer buffer)))))))

(defun decisions-feeds-test--open (entries)
  "Adds ENTRIES to the isolated database and returns their ranked view."
  (dolist (entry entries)
    (puthash (elfeed-entry-id entry) entry elfeed-db-entries)
    (avl-tree-enter elfeed-db-index (elfeed-entry-id entry)))
  (with-current-buffer (get-buffer-create "*elfeed-search*")
    (delay-mode-hooks (elfeed-search-mode))
    (setq elfeed-search-filter "+unread")
    (decisions-feeds-rank))
  (get-buffer "*Decisions feeds*"))

(defun decisions-feeds-test--wait-for-call (count)
  "Waits for COUNT captured submissions; raises after one second."
  (let ((deadline (+ (float-time) 1)))
    (while (and (< (length decisions-feeds-test--calls) count)
                (< (float-time) deadline))
      (sleep-for 0.01)))
  (should (= count (length decisions-feeds-test--calls))))

(ert-deftest decisions-feeds-ranks-whole-database-serially-without-changing-tags ()
  (decisions-feeds-test--isolated
    (let* ((older (decisions-feeds-test--entry "older" 100))
           (newer (decisions-feeds-test--entry "newer" 200))
           (read (decisions-feeds-test--entry "already-read" 300))
           (entries (list older newer read)))
      (setf (elfeed-entry-tags read) '(star))
      (with-current-buffer (decisions-feeds-test--open entries)
        (should (= 3 (length (decisions-feeds-test--rows))))
        (should (= 1 (length decisions-feeds-test--calls)))
        (should (equal (buffer-local-value 'elfeed-search-filter (get-buffer "*elfeed-search*")) "+unread"))
        (dotimes (index 3)
          (let ((unfinished 0))
            (maphash (lambda (_id job)
                       (when (equal "running" (decisions--job-status job))
                         (cl-incf unfinished))) decisions--jobs)
            (should (= 1 unfinished)))
          (decisions-feeds-test--reply
           (nth index decisions-feeds-test--calls) "succeeded"
           (decisions--object "read-now" 0.2 "save" 0.4 "skip" 0.4))
          (when (< index 2) (decisions-feeds-test--wait-for-call (+ index 2))))
        (sleep-for 0.01)
        (should (= 3 (length decisions-feeds-test--calls)))
        (should (equal (mapcar #'elfeed-entry-title (decisions-feeds-test--rows))
                       '("already-read" "newer" "older")))
        (should (equal '(unread) (elfeed-entry-tags older)))
        (should (equal '(unread) (elfeed-entry-tags newer)))
        (should (equal '(star) (elfeed-entry-tags read)))))))

(ert-deftest decisions-feeds-jev-keeps-concurrency-limit-in-flight ()
  (decisions-feeds-test--isolated
    (let ((decisions-default-backend "jev")
          (decisions-jev-concurrency 3)
          (entries (mapcar (lambda (index) (decisions-feeds-test--entry (format "item-%d" index) (* 100 index)))
                           '(1 2 3 4 5))))
      (with-current-buffer (decisions-feeds-test--open entries)
        (should (= 3 (length decisions-feeds-test--calls)))
        (should (= 3 (length decisions-feeds--jobs)))
        (decisions-feeds-test--reply (nth 1 decisions-feeds-test--calls) "succeeded"
                                     (decisions--object "read-now" 0.6 "save" 0.2 "skip" 0.2))
        (decisions-feeds-test--wait-for-call 4)
        (should (= 4 (length decisions-feeds-test--calls)))
        (should (= 3 (length decisions-feeds--jobs)))
        (should-not (member (car (nth 1 decisions-feeds-test--calls)) decisions-feeds--jobs))))))

(ert-deftest decisions-feeds-browse-marks-read-unless-prefixed ()
  (decisions-feeds-test--isolated
    (let* ((kept (decisions-feeds-test--entry "kept" 100))
           (opened (decisions-feeds-test--entry "opened" 200))
           (urls nil))
      (cl-letf (((symbol-function 'feeds-open-in-split) (lambda (url) (push url urls))))
        (with-current-buffer (decisions-feeds-test--open (list kept opened))
          (decisions-feeds-test--select opened)
          (decisions-feeds-browse)
          (decisions-feeds-test--select kept)
          (let ((current-prefix-arg '(4))) (decisions-feeds-browse))
          (should (equal urls '("https://example.test/kept" "https://example.test/opened")))
          (should-not (memq 'unread (elfeed-entry-tags opened)))
          (should (memq 'unread (elfeed-entry-tags kept))))))))

(ert-deftest decisions-feeds-adds-entries-fetched-after-opening ()
  (decisions-feeds-test--isolated
    (let ((first (decisions-feeds-test--entry "first" 100))
          (later (decisions-feeds-test--entry "later" 200)))
      (with-current-buffer (decisions-feeds-test--open (list first))
        (should (= 1 (length decisions-feeds-test--calls)))
        (puthash (elfeed-entry-id later) later elfeed-db-entries)
        (avl-tree-enter elfeed-db-index (elfeed-entry-id later))
        (decisions-feeds--add-new-entries)
        (should (memq later decisions-feeds--entries))
        (decisions-feeds-test--reply (car decisions-feeds-test--calls) "succeeded"
                                     (decisions--object "read-now" 0.6 "save" 0.2 "skip" 0.2))
        (decisions-feeds-test--wait-for-call 2)
        (should (equal (gethash "title" (nth 1 (nth 1 decisions-feeds-test--calls))) "later"))))))

(ert-deftest decisions-feeds-dispatch-failure-stops-the-run ()
  (decisions-feeds-test--isolated
    (let ((entries (list (decisions-feeds-test--entry "a" 100) (decisions-feeds-test--entry "b" 200))))
      (with-current-buffer (decisions-feeds-test--open entries)
        (let* ((call (car decisions-feeds-test--calls))
               (job (gethash (car call) decisions--jobs)))
          (setf (decisions--job-status job) "failed")
          (funcall (plist-get (nth 3 call) :callback)
                   (decisions--object "id" (car call) "status" "failed" "result" :null
                                      "error" (decisions--object "code" "dispatch" "message" "No TypeSafe API key configured"))))
        (sleep-for 0.05)
        (should (= 1 (length decisions-feeds-test--calls)))
        (should-not decisions-feeds--generation)))))

(ert-deftest decisions-feeds-incremental-ranking-keeps-selection-and-shows-errors ()
  (decisions-feeds-test--isolated
    (let* ((older (decisions-feeds-test--entry "older" 100))
           (newer (decisions-feeds-test--entry "newer" 200)))
      (with-current-buffer (decisions-feeds-test--open (list newer older))
        (decisions-feeds-test--select older)
        (decisions-feeds-test--reply (car decisions-feeds-test--calls) "failed")
        (decisions-feeds-test--wait-for-call 2)
        (decisions-feeds-test--reply (cadr decisions-feeds-test--calls) "succeeded"
                                   (decisions--object "read-now" 0.8 "save" 0.1 "skip" 0.1))
        (should (eq older (get-text-property (point) 'elfeed-entry)))
        (should (eq older (car (decisions-feeds-test--rows))))
        (should (string-match-p "test failure" (buffer-string)))))))

(ert-deftest decisions-feeds-cancel-and-killed-view-ignore-late-results ()
  (decisions-feeds-test--isolated
    (let* ((entry (decisions-feeds-test--entry "entry" 100))
           (view (decisions-feeds-test--open (list entry)))
           (first-call (car decisions-feeds-test--calls)))
      (with-current-buffer view
        (decisions-feeds-cancel)
        (should (equal "cancelled" (decisions--job-status (gethash (car first-call) decisions--jobs))))
        (decisions-feeds-refresh)
        (should (= 2 (length decisions-feeds-test--calls)))
        (decisions-feeds-test--reply first-call "succeeded"
                                   (decisions--object "read-now" 1.0 "save" 0.0 "skip" 0.0))
        (should-not (gethash "probabilities" (gethash (elfeed-entry-id entry) decisions-feeds--predictions))))
      (kill-buffer view)
      (decisions-feeds-test--reply (cadr decisions-feeds-test--calls) "succeeded"
                                 (decisions--object "read-now" 1.0 "save" 0.0 "skip" 0.0))
      (sleep-for 0.01)
      (should (= 2 (length decisions-feeds-test--calls)))
      (should-not (get-buffer "*Decisions feeds*")))))

(ert-deftest decisions-feeds-refresh-reuses-cache-and-reclassifies-content-and-model ()
  (decisions-feeds-test--isolated
    (let* ((entry (decisions-feeds-test--entry "entry" 100))
           (decisions-mlx-model "test-model"))
      (with-current-buffer (decisions-feeds-test--open (list entry))
        (decisions-feeds-test--reply (car decisions-feeds-test--calls) "succeeded"
                                   (decisions--object "read-now" 0.6 "save" 0.3 "skip" 0.1))
        (decisions-feeds-refresh)
        (should (= 1 (length decisions-feeds-test--calls)))
        (setf (elfeed-entry-content entry) "Changed article")
        (decisions-feeds-refresh)
        (should (= 2 (length decisions-feeds-test--calls)))
        (decisions-feeds-test--reply (cadr decisions-feeds-test--calls) "succeeded"
                                   (decisions--object "read-now" 0.6 "save" 0.3 "skip" 0.1))
        (setq decisions-mlx-model "another-test-model")
        (decisions-feeds-refresh)
        (should (= 3 (length decisions-feeds-test--calls)))))))

(ert-deftest decisions-feeds-native-entry-opening-and-tags-use-original-entry ()
  (decisions-feeds-test--isolated
    (let* ((entry (decisions-feeds-test--entry "entry" 100))
           (view (decisions-feeds-test--open (list entry)))
           (shown nil)
           (elfeed-show-entry-switch (lambda (buffer) (setq shown buffer))))
      (with-current-buffer view
        (decisions-feeds-test--select entry)
        (should (eq #'decisions-feeds-show (lookup-key decisions-feeds-mode-map (kbd "RET"))))
        (let ((current-prefix-arg '(4))) (decisions-feeds-show))
        (should (eq entry (buffer-local-value 'elfeed-show-entry shown)))
        (should (memq 'unread (elfeed-entry-tags entry)))
        (let ((current-prefix-arg nil)) (decisions-feeds-show))
        (should-not (memq 'unread (elfeed-entry-tags entry)))
        (decisions-feeds-unread)
        (should (memq 'unread (elfeed-entry-tags entry)))
        (decisions-feeds-star)
        (should (memq 'star (elfeed-entry-tags entry)))
        (decisions-feeds-star)
        (should-not (memq 'star (elfeed-entry-tags entry)))
        (decisions-feeds-read)
        (should-not (memq 'unread (elfeed-entry-tags entry)))))))

(ert-deftest decisions-feeds-browser-actions-delegate-selected-entry-url ()
  (decisions-feeds-test--isolated
    (let* ((entry (decisions-feeds-test--entry "entry" 100)) embedded external)
      (with-current-buffer (decisions-feeds-test--open (list entry))
        (cl-letf (((symbol-function 'feeds-open-in-split)
                   (lambda (url) (setq embedded url)))
                  ((symbol-function 'browser-open-externally)
                   (lambda (url) (setq external url))))
          (decisions-feeds-test--select entry)
          (decisions-feeds-browse)
          (decisions-feeds-browse-externally))
        (should (equal embedded (elfeed-entry-link entry)))
        (should (equal external (elfeed-entry-link entry)))))))

(ert-deftest decisions-feeds-local-filter-preserves-native-search-filter ()
  (decisions-feeds-test--isolated
    (let ((unread (decisions-feeds-test--entry "unread" 100))
          (read (decisions-feeds-test--entry "read" 200)))
      (setf (elfeed-entry-tags read) nil)
      (with-current-buffer (decisions-feeds-test--open (list read unread))
        (setq decisions-feeds--filter "+unread")
        (decisions-feeds-refresh)
        (should (equal (decisions-feeds-test--rows) (list unread)))
        (should (equal (buffer-local-value 'elfeed-search-filter (get-buffer "*elfeed-search*"))
                       "+unread"))))))

(ert-deftest decisions-feeds-keeps-selected-entry-visible-after-ranking-past-display-limit ()
  (decisions-feeds-test--isolated
    (let* ((oldest (decisions-feeds-test--entry "oldest" 100))
           (selected (decisions-feeds-test--entry "selected" 200))
           (newest (decisions-feeds-test--entry "newest" 300))
           (elfeed-search-max-entries 2))
      (with-current-buffer (decisions-feeds-test--open (list newest selected oldest))
        (should (= 2 (length (decisions-feeds-test--rows))))
        (decisions-feeds-test--select selected)
        (dotimes (index 3)
          (decisions-feeds-test--reply
           (nth index decisions-feeds-test--calls) "succeeded"
           (if (= index 1)
               (decisions--object "read-now" 0.0 "save" 0.0 "skip" 1.0)
             (decisions--object "read-now" 1.0 "save" 0.0 "skip" 0.0)))
          (when (< index 2) (decisions-feeds-test--wait-for-call (+ index 2))))
        (should (= 3 (length decisions-feeds--entries)))
        (should (= 2 (length (decisions-feeds-test--rows))))
        (should (eq selected (get-text-property (point) 'elfeed-entry)))))))

(ert-deftest decisions-feeds-submit-error-stops-bounded-work-and-displays-error ()
  (decisions-feeds-test--isolated
    (let ((entries (list (decisions-feeds-test--entry "first" 200)
                         (decisions-feeds-test--entry "second" 100)))
          (attempts 0))
      (cl-letf (((symbol-function 'decisions-submit)
                 (lambda (&rest _arguments)
                   (cl-incf attempts)
                   (error "Unavailable test runtime"))))
        (with-current-buffer (decisions-feeds-test--open entries)
          (sleep-for 0.01)
          (should (= 1 attempts))
          (should-not decisions-feeds--jobs)
          (should-not decisions-feeds--generation)
          (should (string-match-p "Unavailable test runtime" (buffer-string)))
          (should (string-match-p "stopped" (buffer-string))))))))

(ert-deftest decisions-feeds-initial-ranking-dereferences-only-dispatched-content ()
  (decisions-feeds-test--isolated
    (let ((entries (list (decisions-feeds-test--entry "first" 300)
                         (decisions-feeds-test--entry "second" 200)
                         (decisions-feeds-test--entry "third" 100)))
          (dereferences 0)
          (native-deref (symbol-function 'elfeed-deref)))
      (cl-letf (((symbol-function 'elfeed-deref)
                 (lambda (content)
                   (cl-incf dereferences)
                   (funcall native-deref content))))
        (with-current-buffer (decisions-feeds-test--open entries)
          (should (= 1 (length decisions-feeds-test--calls)))
          (should (= 1 dereferences)))))))

(ert-deftest decisions-feeds-content-reference-change-invalidates-cache-without-reading-cache-hits ()
  (decisions-feeds-test--isolated
    (let ((entry (decisions-feeds-test--entry "entry" 100))
          (dereferences 0))
      (setf (elfeed-entry-content entry) (elfeed-ref--create :id "original-content"))
      (cl-letf (((symbol-function 'elfeed-deref)
                 (lambda (reference)
                   (cl-incf dereferences)
                   (elfeed-ref-id reference))))
        (with-current-buffer (decisions-feeds-test--open (list entry))
          (decisions-feeds-test--reply (car decisions-feeds-test--calls) "succeeded"
                                     (decisions--object "read-now" 0.6 "save" 0.3 "skip" 0.1))
          (decisions-feeds-refresh)
          (should (= 1 (length decisions-feeds-test--calls)))
          (should (= 1 dereferences))
          (setf (elfeed-entry-content entry) (elfeed-ref--create :id "updated-content"))
          (decisions-feeds-refresh)
          (should (= 2 (length decisions-feeds-test--calls)))
          (should (= 2 dereferences))
          (should (equal "updated-content"
                         (gethash "content" (nth 1 (cadr decisions-feeds-test--calls))))))))))

(ert-deftest decisions-feeds-content-read-error-stops-work-and-displays-error ()
  (decisions-feeds-test--isolated
    (let ((entries (list (decisions-feeds-test--entry "first" 200)
                         (decisions-feeds-test--entry "second" 100))))
      (cl-letf (((symbol-function 'elfeed-deref)
                 (lambda (_content) (error "Unreadable test content reference"))))
        (with-current-buffer (decisions-feeds-test--open entries)
          (should-not decisions-feeds-test--calls)
          (should-not decisions-feeds--jobs)
          (should-not decisions-feeds--generation)
          (should (string-match-p "Unreadable test content reference" (buffer-string)))
          (should (string-match-p "stopped" (buffer-string))))))))

(ert-deftest decisions-feeds-filter-roundtrip-keeps-completed-entry-predictions ()
  (decisions-feeds-test--isolated
    (let ((unread (decisions-feeds-test--entry "unread" 100))
          (read (decisions-feeds-test--entry "read" 200)))
      (setf (elfeed-entry-tags read) '(star))
      (with-current-buffer (decisions-feeds-test--open (list read unread))
        (dotimes (index 2)
          (decisions-feeds-test--reply (nth index decisions-feeds-test--calls) "succeeded"
                                     (decisions--object "read-now" 0.6 "save" 0.3 "skip" 0.1))
          (when (zerop index) (decisions-feeds-test--wait-for-call 2)))
        (setq decisions-feeds--filter "+unread")
        (decisions-feeds-refresh)
        (should (equal (list unread) (decisions-feeds-test--rows)))
        (setq decisions-feeds--filter "")
        (decisions-feeds-refresh)
        (should (= 2 (length (decisions-feeds-test--rows))))
        (should (= 2 (length decisions-feeds-test--calls)))
        (dolist (entry (list read unread))
          (should (hash-table-p (gethash "probabilities"
                                        (gethash (elfeed-entry-id entry) decisions-feeds--predictions)))))))))

;;; decisions-feeds-test.el ends here
