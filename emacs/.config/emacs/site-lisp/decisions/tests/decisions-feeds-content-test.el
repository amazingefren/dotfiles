;;; decisions-feeds-content-test.el --- Plain-text feed recommendation tests -*- lexical-binding: t; -*-

(load (expand-file-name "decisions-feeds-test.el"
                        (file-name-directory (or load-file-name buffer-file-name))) nil t)

(ert-deftest decisions-feeds-default-filter-limits-new-view-to-recent-unread ()
  (decisions-feeds-test--isolated
    (let* ((decisions-feeds-default-filter "@2-weeks-ago +unread")
           (recent (decisions-feeds-test--entry "recent" (float-time)))
           (old (decisions-feeds-test--entry "old" (- (float-time) (* 30 86400))))
           (read (decisions-feeds-test--entry "read" (float-time))))
      (setf (elfeed-entry-tags read) nil)
      (with-current-buffer (decisions-feeds-test--open (list recent old read))
        (should (equal decisions-feeds--filter "@2-weeks-ago +unread"))
        (should (equal (decisions-feeds-test--rows) (list recent)))
        (should (= 1 (length decisions-feeds-test--calls)))
        (should (equal (gethash "title" (nth 1 (car decisions-feeds-test--calls))) "recent"))
        (should (equal (elfeed-entry-tags recent) '(unread)))
        (should (equal (elfeed-entry-tags old) '(unread)))
        (should-not (elfeed-entry-tags read))))))

(ert-deftest decisions-feeds-submits-readable-html-content-without-network-fetches ()
  (decisions-feeds-test--isolated
    (let ((entry (decisions-feeds-test--entry "Safety update" (float-time))))
      (setf (elfeed-entry-content entry)
            "<style>stylesheet-marker</style><script>script-marker</script><h1>Patch &amp; restart</h1><p>Install <strong>version 2.1</strong> today.</p><p><a href='https://example.test/link-marker'>Release notes</a></p><img src='https://example.test/image-marker.png' alt='Diagram'>")
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (&rest _arguments) (error "Unexpected RSS image download")))
                ((symbol-function 'url-queue-retrieve)
                 (lambda (&rest _arguments) (error "Unexpected queued RSS image download"))))
        (decisions-feeds-test--open (list entry)))
      (let* ((state (nth 1 (car decisions-feeds-test--calls)))
             (content (gethash "content" state)))
        (should (string-match-p "Patch & restart" content))
        (should (string-match-p "Install version 2.1 today" content))
        (should (string-match-p "Release notes" content))
        (should-not (string-match-p "<\\|stylesheet-marker\\|script-marker\\|link-marker\\|image-marker" content))
        (should-not (text-properties-at 0 content))
        (should (equal (gethash "feed" state) "Test feed"))
        (should (equal (gethash "tags" state) ["unread"]))))))

(ert-deftest decisions-feeds-keeps-literal-plain-text-and-missing-content ()
  (decisions-feeds-test--isolated
    (let ((entry (decisions-feeds-test--entry "Text" (float-time))))
      (setf (elfeed-entry-content-type entry) 'text
            (elfeed-entry-content entry) "  Compare a < b & c > d.  ")
      (should (equal (gethash "content" (decisions-feeds--state entry))
                     "Compare a < b & c > d."))
      (setf (elfeed-entry-content entry) nil)
      (should (equal (gethash "content" (decisions-feeds--state entry)) ""))
      (setf (elfeed-entry-content-type entry) 'html)
      (should (equal (gethash "content" (decisions-feeds--state entry)) "")))))

(ert-deftest decisions-feeds-displays-undetermined-below-useful-saved-content ()
  (decisions-feeds-test--isolated
    (let ((uncertain (decisions-feeds-test--entry "Teaser" 200))
          (useful (decisions-feeds-test--entry "Reference" 100)))
      (setf (elfeed-entry-content uncertain) "Read more at the link.")
      (with-current-buffer (decisions-feeds-test--open (list uncertain useful))
        (decisions-feeds-test--reply (car decisions-feeds-test--calls) "succeeded"
                                   (decisions--object "read-now" 0.03 "save" 0.07 "skip" 0.10 "undetermined" 0.80))
        (decisions-feeds-test--wait-for-call 2)
        (decisions-feeds-test--reply (cadr decisions-feeds-test--calls) "succeeded"
                                   (decisions--object "read-now" 0.05 "save" 0.90 "skip" 0.03 "undetermined" 0.02))
        (should (equal (decisions-feeds-test--rows) (list useful uncertain)))
        (should (string-match-p "undetermined +80\\.0%" (buffer-string)))
        (should (equal (elfeed-entry-tags uncertain) '(unread)))))))

(ert-deftest decisions-feeds-criteria-and-content-type-invalidate-cached-decisions ()
  (decisions-feeds-test--isolated
    (let ((entry (decisions-feeds-test--entry "Entry" 100))
          (decisions-feeds--questions (copy-hash-table decisions-feeds--questions)))
      (setf (elfeed-entry-content entry) "<p>Reference</p>")
      (with-current-buffer (decisions-feeds-test--open (list entry))
        (decisions-feeds-test--reply (car decisions-feeds-test--calls) "succeeded"
                                   (decisions--object "read-now" 0.1 "save" 0.8 "skip" 0.05 "undetermined" 0.05))
        (decisions-feeds-refresh)
        (should (= 1 (length decisions-feeds-test--calls)))
        (puthash "reading" (decisions--object "criteria" (decisions--object "undetermined" "No evidence")
                                             "instructions" "Assess missing evidence."
                                             "type" "choice")
                 decisions-feeds--questions)
        (decisions-feeds-refresh)
        (should (= 2 (length decisions-feeds-test--calls)))
        (decisions-feeds-test--reply (cadr decisions-feeds-test--calls) "succeeded"
                                   (decisions--object "read-now" 0.1 "save" 0.8 "skip" 0.05 "undetermined" 0.05))
        (setf (elfeed-entry-content-type entry) 'text)
        (decisions-feeds-refresh)
        (should (= 3 (length decisions-feeds-test--calls)))
        (should (equal (gethash "content" (nth 1 (nth 2 decisions-feeds-test--calls)))
                       "<p>Reference</p>"))))))

;;; decisions-feeds-content-test.el ends here
