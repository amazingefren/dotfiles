;;; laya-review.el --- Score diff hunks with LAYA -*- lexical-binding: t -*-

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; A review shell over `laya-submit'.  A diff is split into hunks, each hunk
;; is asked the questions in a JSON rubric, and the rubric's risk weights turn
;; the answers into a 0-1 risk.  The rubric also names the backend and model,
;; so better models and better questions need no code change.
;;
;; `laya-review-submit-hunk' is the reusable core; the review buffer is one
;; client of it.

;;; Code:
(require 'laya)
(require 'cl-lib)
(require 'color)
(require 'diff-mode)
(require 'subr-x)

(defgroup laya-review nil "Score diff hunks with LAYA." :group 'laya)

(defcustom laya-review-rubric-file
  (expand-file-name "review-rubric.json"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "JSON rubric: questions, their risk weights, and optionally backend/model."
  :type 'file)
(defcustom laya-review-concurrency 2
  "Hunks kept submitted at once.  The worker still evaluates them serially."
  :type 'integer)
(defcustom laya-review-max-hunks 300 "Largest number of hunks one review scores." :type 'integer)
(defcustom laya-review-max-side-characters 1200
  "Characters kept from each of a hunk's removed and added text."
  :type 'integer)
(defcustom laya-review-high-risk 0.6 "Risk at or above which a hunk is high." :type 'number)
(defcustom laya-review-medium-risk 0.3 "Risk at or above which a hunk is medium." :type 'number)
(defcustom laya-review-chart-limit 10 "Hunks shown in the risk chart." :type 'integer)
(defcustom laya-review-focus-threshold 0.3
  "Risk below which the focused views hide a hunk."
  :type 'number)
(defcustom laya-review-state-function #'laya-review-default-state
  "Function of one hunk plist returning the LAYA state for it."
  :type 'function)

(defconst laya-review--owner "laya-review" "Owner used for every review job.")

(declare-function eplot-make-plot "eplot" (headers &rest datas))
(declare-function svg-image "svg" (svg &rest props))
(declare-function evil-define-key* "evil-core" (state keymap key def &rest bindings))

;;;; Diff parsing

(defun laya-review--path (text)
  "Return the repository path in a ---/+++ header TEXT, or nil for /dev/null."
  (let ((path (string-trim (car (split-string text "\t")))))
    (when (and (string-prefix-p "\"" path) (string-suffix-p "\"" path))
      (setq path (substring path 1 -1)))
    (unless (equal path "/dev/null")
      (if (string-match "\\`[ab]/" path) (substring path 2) path))))

(defun laya-review-parse-diff (diff)
  "Split unified DIFF into a list of hunk plists.
Each has :file, :line (first changed line in the new file), :header (the
function context after @@), :text, :removed and :added."
  (let ((lines (split-string diff "\n"))
        old-file new-file hunks hunk old-left new-left new-line)
    (cl-flet ((finish ()
                (when hunk
                  (dolist (key '(:text :removed :added))
                    (plist-put hunk key (string-join (nreverse (plist-get hunk key)) "\n")))
                  (push hunk hunks)
                  (setq hunk nil))))
      (dolist (line lines)
        (cond
         ;; Inside a hunk the counts decide, so "--- x" can be a removed line.
         ((and hunk (or (> old-left 0) (> new-left 0))
               (string-match-p "\\`[-+ \\]" line))
          (push line (plist-get hunk :text))
          (pcase (aref line 0)
            (?- (cl-decf old-left)
                (unless (plist-get hunk :line) (plist-put hunk :line new-line))
                (push (substring line 1) (plist-get hunk :removed)))
            (?+ (cl-decf new-left)
                (unless (plist-get hunk :line) (plist-put hunk :line new-line))
                (push (substring line 1) (plist-get hunk :added))
                (cl-incf new-line))
            (?\s (cl-decf old-left) (cl-decf new-left) (cl-incf new-line))))
         ((and hunk (string-prefix-p "\\" line))
          (push line (plist-get hunk :text)))
         ((string-match "\\`@@ -[0-9]+\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@ ?\\(.*\\)" line)
          (finish)
          (setq old-left (if (match-string 1 line) (string-to-number (match-string 1 line)) 1)
                new-line (string-to-number (match-string 2 line))
                new-left (if (match-string 3 line) (string-to-number (match-string 3 line)) 1))
          (setq hunk (list :file (or new-file old-file) :deleted (null new-file)
                           :line nil :header (match-string 4 line)
                           :text (list line) :removed nil :added nil)))
         ((string-prefix-p "diff " line)
          (finish) (setq old-file nil new-file nil))
         ((string-prefix-p "--- " line)
          (finish) (setq old-file (laya-review--path (substring line 4))))
         ((string-prefix-p "+++ " line)
          (setq new-file (laya-review--path (substring line 4))))))
      (finish))
    (dolist (hunk hunks)
      (unless (plist-get hunk :line) (plist-put hunk :line 1)))
    (nreverse hunks)))

;;;; Rubric and scoring

(defun laya-review-load-rubric (&optional file)
  "Read and check the rubric in FILE, defaulting to `laya-review-rubric-file'."
  (let* ((file (or file laya-review-rubric-file))
         (rubric (with-temp-buffer
                   (insert-file-contents file)
                   (json-parse-buffer :object-type 'hash-table :array-type 'array
                                      :null-object :null :false-object :false))))
    (unless (and (hash-table-p rubric)
                 (equal (gethash "format" rubric) "laya-review-rubric-v1")
                 (hash-table-p (gethash "questions" rubric))
                 (> (hash-table-count (gethash "questions" rubric)) 0))
      (user-error "%s is not a laya-review-rubric-v1 file with questions"
                  (abbreviate-file-name file)))
    rubric))

(defun laya-review--questions (rubric)
  "Return RUBRIC's questions without the review-only risk weights."
  (let ((questions (laya--json-copy (gethash "questions" rubric))))
    (maphash (lambda (_ question) (remhash "risk" question)) questions)
    questions))

(defun laya-review--clip (text)
  "Return TEXT limited to `laya-review-max-side-characters'."
  (if (> (length text) laya-review-max-side-characters)
      (concat (substring text 0 laya-review-max-side-characters) "\n...")
    text))

(defun laya-review-default-state (hunk)
  "Describe HUNK as before/after prose, the form LAYA scored best in tests."
  (let ((removed (plist-get hunk :removed)) (added (plist-get hunk :added))
        (header (plist-get hunk :header)))
    (concat (format "A code change to %s" (plist-get hunk :file))
            (if (and header (not (string-empty-p header))) (format " in %s" header) "")
            ".\nBEFORE:\n" (if (string-empty-p removed) "(nothing)" (laya-review--clip removed))
            "\nAFTER:\n" (if (string-empty-p added) "(deleted)" (laya-review--clip added)))))

(defun laya-review-risk (answers rubric)
  "Return (RISK . REASON) for LAYA ANSWERS under RUBRIC's risk weights.
A choice contributes the sum of P(option) x weight, a noul
P(true) x true-weight + P(false) x false-weight, and a score the sum of
P(level) x weight.  The hunk's risk is its largest contribution."
  (let ((best 0.0) (reason "no concerns"))
    (maphash
     (lambda (name question)
       (let ((weights (gethash "risk" question))
             (answer (and (hash-table-p answers) (gethash name answers))))
         (when (and weights (hash-table-p answer))
           (let ((contribution 0.0) (detail nil))
             (pcase (gethash "type" answer)
               ("choice"
                ;; Name the option that adds the most risk, not the most
                ;; likely one, which may be harmless.
                (let ((probabilities (gethash "probabilities" answer))
                      (worst nil) (worst-part -1))
                  (maphash (lambda (label weight)
                             (let ((part (* weight (gethash label probabilities 0))))
                               (cl-incf contribution part)
                               (when (> part worst-part) (setq worst label worst-part part))))
                           weights)
                  (setq detail (format "%s: %s %d%%" name worst
                                       (round (* 100 (gethash worst probabilities 0)))))))
               ("noul"
                (let ((p (gethash "noul" answer)))
                  (setq contribution (+ (* (gethash "true" weights 0) p)
                                        (* (gethash "false" weights 0) (- 1 p)))
                        detail (format "%s %d%%" name (round (* 100 p))))))
               ("score"
                (let ((probabilities (gethash "probabilities" answer)))
                  (dotimes (level (length weights))
                    (cl-incf contribution (* (aref weights level)
                                             (gethash (number-to-string level) probabilities 0))))
                  (setq detail (format "%s %.1f" name (gethash "score" answer))))))
             (when (> contribution best)
               (setq best contribution reason detail))))))
     (gethash "questions" rubric))
    (cons (min 1.0 best) reason)))

;;;###autoload
(cl-defun laya-review-submit-hunk (hunk callback &key rubric)
  "Ask LAYA RUBRIC's questions about HUNK and return the job id.
CALLBACK receives a plist with :status, :risk, :reason, :answers and
:snapshot once the job ends.  This is the entry point for other callers,
such as live edit followers."
  (let* ((rubric (or rubric (laya-review-load-rubric)))
         (model (gethash "model" rubric)))
    (laya-submit (funcall laya-review-state-function hunk)
                 (laya-review--questions rubric)
                 :backend (gethash "backend" rubric "mlx")
                 :model (and (stringp model) model)
                 :revision (let ((revision (gethash "revision" rubric)))
                             (and (stringp revision) revision))
                 :allow-truncation t
                 :owner laya-review--owner
                 :callback
                 (lambda (snapshot)
                   (let* ((status (gethash "status" snapshot))
                          (result (gethash "result" snapshot))
                          (answers (and (hash-table-p result) (gethash "answers" result)))
                          (scored (and (equal status "succeeded") (laya-review-risk answers rubric))))
                     (funcall callback
                              (list :status status :risk (car scored) :reason (cdr scored)
                                    :answers answers :snapshot snapshot)))))))

;;;; Diff sources

(defun laya-review--git (root &rest arguments)
  "Return Git's output for ARGUMENTS in ROOT, or signal its error."
  (let ((default-directory root))
    (with-temp-buffer
      (let ((status (apply #'process-file "git" nil t nil arguments)))
        (unless (eql status 0)
          (user-error "git %s: %s" (string-join arguments " ") (string-trim (buffer-string))))
        (buffer-string)))))

(defun laya-review--root ()
  "Return the Git worktree root for `default-directory'."
  (file-name-as-directory (string-trim (laya-review--git default-directory "rev-parse" "--show-toplevel"))))

(defcustom laya-review-max-untracked-file-size 100000
  "Largest untracked file, in bytes, added to a review as a new file."
  :type 'integer)

(defun laya-review--untracked-diff (root)
  "Return new-file diffs for ROOT's untracked, unignored files.
`git diff' leaves these out, yet new files are often the ones to review."
  (let ((default-directory root))
    (mapconcat
     (lambda (file)
       (let ((size (file-attribute-size (file-attributes (expand-file-name file root)))))
         (if (and size (<= size laya-review-max-untracked-file-size))
             (with-temp-buffer
               ;; --no-index exits 1 when the files differ, which they always do.
               (process-file "git" nil t nil "--no-pager" "diff" "--no-index" "--no-color"
                             "--src-prefix=a/" "--dst-prefix=b/" "--" "/dev/null" file)
               (buffer-string))
           "")))
     (split-string (laya-review--git root "ls-files" "--others" "--exclude-standard" "-z") "\0" t)
     "")))

(defun laya-review--diff (root arguments &optional untracked)
  "Return the diff of ARGUMENTS in ROOT with fixed, parseable formatting.
With UNTRACKED, append untracked files as new-file diffs."
  (concat (apply #'laya-review--git root "--no-pager" "diff" "--no-ext-diff" "--no-color"
                 "--src-prefix=a/" "--dst-prefix=b/" arguments)
          (if untracked (laya-review--untracked-diff root) "")))

(defun laya-review--main-branch (root)
  "Return ROOT's main branch name."
  (or (and (fboundp 'magit-main-branch)
           (let ((default-directory root)) (magit-main-branch)))
      (seq-find (lambda (branch)
                  (eql 0 (let ((default-directory root))
                           (process-file "git" nil nil nil "rev-parse" "--verify" "--quiet" branch))))
                '("main" "master"))
      (user-error "No main or master branch")))

(defun laya-review--source (kind)
  "Return a source plist (:root :label :arguments or :diff) for KIND."
  (let ((root (laya-review--root)))
    (pcase kind
      ('worktree (list :root root :label "uncommitted changes vs HEAD" :arguments '("HEAD" "--")
                       :untracked t))
      ('staged (list :root root :label "staged changes" :arguments '("--cached" "--")))
      ;; The merge base against the working tree: commits on this branch plus
      ;; work not yet committed, which main...HEAD alone would miss.
      ('branch (let* ((main (laya-review--main-branch root))
                      (base (string-trim (laya-review--git root "merge-base" main "HEAD"))))
                 (list :root root :label (format "this branch + uncommitted vs %s" main)
                       :arguments (list base "--") :untracked t)))
      ('range (let ((range (read-string "Revision range: " "HEAD~1..HEAD")))
                (list :root root :label range :arguments (list range "--")))))))

(defvar magit-buffer-range)
(defvar magit-buffer-typearg)
(defvar magit-buffer-diff-files)

(defun laya-review--buffer-source ()
  "Return a source for the diff shown in the current buffer, or nil."
  (cond
   ((derived-mode-p 'magit-diff-mode)
    (let ((root (laya-review--root)))
      (list :root root
            :label (format "magit diff %s" (or magit-buffer-range "working tree"))
            :arguments (append (and magit-buffer-typearg (list magit-buffer-typearg))
                               (and magit-buffer-range (list magit-buffer-range))
                               (cons "--" magit-buffer-diff-files)))))
   ((derived-mode-p 'diff-mode)
    (list :root (condition-case nil (laya-review--root) (error default-directory))
          :label (format "diff in %s" (buffer-name))
          :diff (buffer-substring-no-properties (point-min) (point-max))))))

;;;; Review buffer

(cl-defstruct (laya-review--hunk (:constructor laya-review--make-hunk))
  index data status job risk reason answers error)

(defvar-local laya-review--source nil)
(defvar-local laya-review--hunks nil)
(defvar-local laya-review--rubric nil)
(defvar-local laya-review--next 0)
(defvar-local laya-review--inflight 0)
(defvar-local laya-review--generation 0)
(defvar-local laya-review--expanded nil)
(defvar-local laya-review--sort 'risk)
(defvar-local laya-review--render-timer nil)
(defvar-local laya-review--started nil)
(defvar-local laya-review--focus nil "Non-nil hides hunks below `laya-review-focus-threshold'.")
(defvar-local laya-review--review-buffer nil "The review a focused diff buffer follows.")

(defun laya-review--level (risk)
  "Return high, medium or low for RISK."
  (cond ((>= risk laya-review-high-risk) 'high)
        ((>= risk laya-review-medium-risk) 'medium)
        (t 'low)))

(defun laya-review--face (risk)
  "Return the face used for RISK."
  (pcase (laya-review--level risk) ('high 'error) ('medium 'warning) (_ 'success)))

(defun laya-review--hex (face attribute)
  "Return FACE's ATTRIBUTE color as #rrggbb, which SVG understands."
  (let ((color (if (eq attribute :background) (face-background face nil 'default)
                 (face-foreground face nil 'default))))
    (if-let* ((values (and color (color-values color))))
        (apply #'color-rgb-to-hex (append (mapcar (lambda (v) (/ v 65535.0)) values) '(2)))
      "#808080")))

(defun laya-review--cancel-all ()
  "Cancel this buffer's unfinished jobs and ignore their late callbacks."
  (cl-incf laya-review--generation)
  (seq-doseq (hunk laya-review--hunks)
    (when (and (laya-review--hunk-job hunk)
               (member (laya-review--hunk-status hunk) '(queued)))
      (ignore-errors (laya-cancel (laya-review--hunk-job hunk) laya-review--owner))
      (setf (laya-review--hunk-status hunk) 'cancelled)))
  (setq laya-review--inflight 0))

(defun laya-review--pump (buffer)
  "Submit BUFFER's next hunks up to `laya-review-concurrency'."
  (with-current-buffer buffer
    (while (and (< laya-review--inflight laya-review-concurrency)
                (< laya-review--next (length laya-review--hunks)))
      (let* ((hunk (aref laya-review--hunks laya-review--next))
             (generation laya-review--generation))
        (cl-incf laya-review--next)
        (cl-incf laya-review--inflight)
        (setf (laya-review--hunk-status hunk) 'queued)
        (condition-case err
            (setf (laya-review--hunk-job hunk)
                  (laya-review-submit-hunk
                   (laya-review--hunk-data hunk)
                   (lambda (outcome) (laya-review--scored buffer generation hunk outcome))
                   :rubric laya-review--rubric))
          (error (cl-decf laya-review--inflight)
                 (setf (laya-review--hunk-status hunk) 'failed
                       (laya-review--hunk-error hunk) (error-message-string err))))))
    (laya-review--schedule-render)))

(defun laya-review--scored (buffer generation hunk outcome)
  "Record OUTCOME for HUNK if BUFFER is still on GENERATION, then continue."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (= generation laya-review--generation)
        (cl-decf laya-review--inflight)
        (if (equal (plist-get outcome :status) "succeeded")
            (setf (laya-review--hunk-status hunk) 'scored
                  (laya-review--hunk-risk hunk) (plist-get outcome :risk)
                  (laya-review--hunk-reason hunk) (plist-get outcome :reason)
                  (laya-review--hunk-answers hunk) (plist-get outcome :answers))
          (let ((error-object (gethash "error" (plist-get outcome :snapshot))))
            (setf (laya-review--hunk-status hunk) 'failed
                  (laya-review--hunk-error hunk)
                  (if (hash-table-p error-object) (gethash "message" error-object)
                    (plist-get outcome :status)))))
        (laya-review--pump buffer)))))

(defun laya-review--schedule-render ()
  "Redraw soon, coalescing bursts of results."
  (unless (timerp laya-review--render-timer)
    (let ((buffer (current-buffer)))
      (setq laya-review--render-timer
            (run-at-time 0.15 nil
                         (lambda ()
                           (when (buffer-live-p buffer)
                             (with-current-buffer buffer
                               (setq laya-review--render-timer nil)
                               (laya-review--render)))))))))

(defun laya-review--ordered ()
  "Return hunks in display order."
  (let ((hunks (append laya-review--hunks nil)))
    (if (eq laya-review--sort 'risk)
        (sort hunks (lambda (a b) (> (or (laya-review--hunk-risk a) -1)
                                     (or (laya-review--hunk-risk b) -1))))
      hunks)))

(defun laya-review--label (hunk)
  "Return FILE:LINE for HUNK."
  (let ((data (laya-review--hunk-data hunk)))
    (format "%s:%d" (plist-get data :file) (plist-get data :line))))

(defun laya-review--chart (scored)
  "Return an eplot image of the riskiest SCORED hunks, or nil."
  (when (and scored (display-graphic-p) (require 'eplot nil t))
    (let* ((top (seq-take (sort (copy-sequence scored)
                                (lambda (a b) (> (laya-review--hunk-risk a)
                                                 (laya-review--hunk-risk b))))
                          laya-review-chart-limit))
           (window (get-buffer-window (current-buffer)))
           (width (min 1000 (max 400 (truncate (* 0.9 (if window (window-pixel-width window) 800))))))
           (svg (eplot-make-plot
                 `((Format horizontal-bar-chart)
                   (Mode ,(if (eq (frame-parameter nil 'background-mode) 'dark) 'dark 'light))
                   (Width ,width)
                   (Height ,(+ 50 (* 26 (length top))))
                   (Title "Riskiest hunks")
                   (Background-Color ,(laya-review--hex 'default :background))
                   (Chart-Color ,(laya-review--hex 'default :foreground))
                   (Min 0) (Max 1)
                   (Color ,(mapconcat (lambda (hunk)
                                        (laya-review--hex (laya-review--face (laya-review--hunk-risk hunk))
                                                          :foreground))
                                      top " ")))
                 (mapcar (lambda (hunk)
                           (list (format "%.2f" (laya-review--hunk-risk hunk))
                                 (format "# Label: %s"
                                         (file-name-nondirectory (laya-review--label hunk)))))
                         top))))
      (svg-image svg))))

(defun laya-review--bar (risk)
  "Return a ten-cell bar for RISK."
  (let ((filled (round (* 10 risk))))
    (concat (make-string filled ?█) (make-string (- 10 filled) ?░))))

(defun laya-review--insert-answers (answers)
  "Insert every LAYA answer in ANSWERS with its distribution."
  (dolist (name (sort (hash-table-keys answers) #'string<))
    (let ((answer (gethash name answers)))
      (insert "      " (propertize name 'face 'bold) "  ")
      (pcase (gethash "type" answer)
        ("noul" (insert (format "P(true) %.2f" (gethash "noul" answer))))
        ("score" (insert (format "score %.2f" (gethash "score" answer))))
        ("choice"
         (let ((probabilities (gethash "probabilities" answer)))
           (insert (mapconcat (lambda (label) (format "%s %.2f" label (gethash label probabilities)))
                              (sort (hash-table-keys probabilities)
                                    (lambda (a b) (> (gethash a probabilities) (gethash b probabilities))))
                              "  ")))))
      (insert (propertize (format "   conf %.2f\n" (gethash "confidence" answer 0)) 'face 'shadow)))))

(defun laya-review--insert-hunk (hunk)
  "Insert one row, plus details when HUNK is expanded."
  (let ((start (point))
        (risk (laya-review--hunk-risk hunk)))
    (pcase (laya-review--hunk-status hunk)
      ('scored
       (insert (propertize (laya-review--bar risk) 'face (laya-review--face risk))
               (format " %.2f  " risk)))
      ('failed (insert (propertize "  failed         " 'face 'error)))
      ('queued (insert (propertize "  scoring…       " 'face 'shadow)))
      (_ (insert (propertize "  waiting        " 'face 'shadow))))
    (insert (propertize (truncate-string-to-width (laya-review--label hunk) 44 nil ?\s "…")
                        'face 'link)
            "  "
            (pcase (laya-review--hunk-status hunk)
              ('scored (laya-review--hunk-reason hunk))
              ('failed (propertize (or (laya-review--hunk-error hunk) "") 'face 'error))
              (_ (propertize (or (plist-get (laya-review--hunk-data hunk) :header) "") 'face 'shadow)))
            "\n")
    (when (gethash (laya-review--hunk-index hunk) laya-review--expanded)
      (when-let* ((answers (laya-review--hunk-answers hunk)))
        (laya-review--insert-answers answers))
      (dolist (line (split-string (plist-get (laya-review--hunk-data hunk) :text) "\n"))
        (insert "      "
                (propertize line 'face (cond ((string-prefix-p "@@" line) 'diff-hunk-header)
                                             ((string-prefix-p "+" line) 'diff-added)
                                             ((string-prefix-p "-" line) 'diff-removed)
                                             (t 'diff-context)))
                "\n"))
      (insert "\n"))
    (put-text-property start (point) 'laya-review-hunk hunk)))

(defun laya-review--render ()
  "Redraw the review buffer, keeping point on the same hunk."
  (let* ((inhibit-read-only t)
         (current (get-text-property (point) 'laya-review-hunk))
         (window (get-buffer-window (current-buffer)))
         (start (and window (window-start window)))
         (hunks (append laya-review--hunks nil))
         (scored (seq-filter (lambda (h) (eq (laya-review--hunk-status h) 'scored)) hunks))
         (failed (seq-count (lambda (h) (eq (laya-review--hunk-status h) 'failed)) hunks))
         (levels (mapcar (lambda (h) (laya-review--level (laya-review--hunk-risk h))) scored))
         (done (+ (length scored) failed))
         (backend (gethash "backend" laya-review--rubric "mlx")))
    (erase-buffer)
    (insert (propertize "LAYA review" 'face '(:inherit bold :height 1.3))
            "  " (plist-get laya-review--source :label)
            "  " (propertize (abbreviate-file-name (plist-get laya-review--source :root)) 'face 'shadow) "\n")
    (insert (propertize (format "%s · %s · rubric %s\n" backend
                                (gethash "model" laya-review--rubric
                                         (if (equal backend "jev") laya-jev-model laya-mlx-model))
                                (file-name-nondirectory laya-review-rubric-file))
                        'face 'shadow))
    (insert (format "%d hunks · %d scored · " (length hunks) done)
            (propertize (format "%d high" (seq-count (lambda (l) (eq l 'high)) levels)) 'face 'error) " · "
            (propertize (format "%d medium" (seq-count (lambda (l) (eq l 'medium)) levels)) 'face 'warning) " · "
            (propertize (format "%d low" (seq-count (lambda (l) (eq l 'low)) levels)) 'face 'success)
            (if (> failed 0) (propertize (format " · %d failed" failed) 'face 'error) "")
            (if (< done (length hunks)) ""
              (propertize (format "   done in %.1fs" (float-time (time-since laya-review--started)))
                          'face 'shadow))
            "\n\n")
    (when-let* ((image (condition-case err (laya-review--chart scored)
                         (error (insert (propertize (format "chart unavailable: %s\n"
                                                            (error-message-string err))
                                                    'face 'shadow))
                                nil))))
      (insert-image image "[chart]")
      (insert "\n\n"))
    (if (null hunks)
        (insert (propertize "No changes to review.\n" 'face 'shadow))
      (let* ((ordered (laya-review--ordered))
             (shown (if laya-review--focus (seq-filter #'laya-review--matters-p ordered) ordered)))
        (mapc #'laya-review--insert-hunk shown)
        (when laya-review--focus
          (insert (propertize (format "\n%d hunks below %.2f hidden · f shows all\n"
                                      (- (length ordered) (length shown)) laya-review-focus-threshold)
                              'face 'shadow)))))
    (goto-char (point-min))
    (when current
      (when-let* ((match (text-property-search-forward 'laya-review-hunk current #'eq)))
        (goto-char (prop-match-beginning match))))
    (unless current (laya-review-next-hunk))
    (when start (set-window-start window (min start (point-max)) t))
    (laya-review--update-focused-diff (current-buffer))))

(defun laya-review--matters-p (hunk)
  "Return non-nil unless HUNK scored below `laya-review-focus-threshold'.
Unscored and failed hunks stay visible, since nothing vouches for them."
  (not (and (eq (laya-review--hunk-status hunk) 'scored)
            (< (laya-review--hunk-risk hunk) laya-review-focus-threshold))))

(defun laya-review--focused-diff-buffer (review)
  "Return the live focused diff buffer following REVIEW, or nil."
  (seq-find (lambda (buffer)
              (eq (buffer-local-value 'laya-review--review-buffer buffer) review))
            (buffer-list)))

(defun laya-review--update-focused-diff (review)
  "Rewrite REVIEW's focused diff, if one is open, from the current scores."
  (when-let* ((buffer (laya-review--focused-diff-buffer review)))
    (let* ((hunks (with-current-buffer review (laya-review--ordered)))
           (scored (seq-filter (lambda (h) (eq (laya-review--hunk-status h) 'scored)) hunks))
           (kept (seq-filter (lambda (h) (and (eq (laya-review--hunk-status h) 'scored)
                                              (>= (laya-review--hunk-risk h) laya-review-focus-threshold)))
                             hunks)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t) (line (line-number-at-pos)))
          (erase-buffer)
          ;; diff-mode ignores text before the first file header, and each
          ;; hunk gets its own header so hunks can be ordered by risk.
          (insert (format "LAYA focused diff: %d of %d hunks at risk >= %.2f, riskiest first\n"
                          (length kept) (length hunks) laya-review-focus-threshold)
                  (format "%d hidden as low risk%s\n\n" (- (length scored) (length kept))
                          (if (< (length scored) (length hunks))
                              (format ", %d still scoring" (- (length hunks) (length scored))) "")))
          (dolist (hunk kept)
            (let ((data (laya-review--hunk-data hunk)))
              (insert (format "--- a/%s\n+++ b/%s\n" (plist-get data :file)
                              (if (plist-get data :deleted) "/dev/null" (plist-get data :file)))
                      ;; The @@ line may carry any text after it, so the
                      ;; risk rides there without breaking diff-mode.
                      (let ((lines (split-string (plist-get data :text) "\n")))
                        (string-join (cons (format "%s  [risk %.2f · %s]" (car lines)
                                                   (laya-review--hunk-risk hunk)
                                                   (laya-review--hunk-reason hunk))
                                           (cdr lines))
                                     "\n"))
                      "\n")))
          (goto-char (point-min))
          (forward-line (1- line)))))))

;;;###autoload
(defun laya-review-focused-diff ()
  "Show only the hunks LAYA rates at or above `laya-review-focus-threshold'.
The buffer is an ordinary `diff-mode' buffer that follows the review, so it
fills in while scoring continues."
  (interactive)
  (let* ((review (or (and (derived-mode-p 'laya-review-mode) (current-buffer))
                     (get-buffer "*LAYA review*")
                     (user-error "Run M-x laya-review first")))
         (buffer (or (laya-review--focused-diff-buffer review)
                     (get-buffer-create "*LAYA focused diff*"))))
    (with-current-buffer buffer
      (diff-mode)
      (setq default-directory (buffer-local-value 'default-directory review)
            laya-review--review-buffer review
            buffer-read-only t)
      (setq-local header-line-format
                  (format " Hunks LAYA rates >= %.2f · RET source · n/p hunks · q quit"
                          laya-review-focus-threshold)))
    (laya-review--update-focused-diff review)
    (pop-to-buffer buffer)))

(defun laya-review-toggle-focus ()
  "Hide or show hunks below `laya-review-focus-threshold'."
  (interactive)
  (setq laya-review--focus (not laya-review--focus))
  (laya-review--render))

(defun laya-review--start (source)
  "Open a review buffer for SOURCE and start scoring."
  (let* ((rubric (laya-review-load-rubric))
         (diff (or (plist-get source :diff)
                   (laya-review--diff (plist-get source :root) (plist-get source :arguments)
                                      (plist-get source :untracked))))
         (parsed (laya-review-parse-diff diff))
         (buffer (get-buffer-create "*LAYA review*")))
    (when (> (length parsed) laya-review-max-hunks)
      (message "LAYA review: scoring the first %d of %d hunks" laya-review-max-hunks (length parsed))
      (setq parsed (seq-take parsed laya-review-max-hunks)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'laya-review-mode) (laya-review-mode))
      (laya-review--cancel-all)
      (setq default-directory (plist-get source :root)
            laya-review--source source
            laya-review--rubric rubric
            laya-review--next 0
            laya-review--inflight 0
            laya-review--started (current-time)
            laya-review--expanded (make-hash-table)
            laya-review--hunks
            (vconcat (cl-loop for data in parsed for index from 0
                              collect (laya-review--make-hunk :index index :data data :status 'waiting))))
      (laya-review--render))
    (pop-to-buffer buffer)
    (laya-review--pump buffer)
    buffer))

;;;###autoload
(defun laya-review (&optional choose)
  "Score each hunk of a diff with LAYA.
In a magit diff or `diff-mode' buffer, review what that buffer shows;
otherwise review uncommitted changes against HEAD.  With CHOOSE (a prefix
argument), pick the changes: uncommitted, staged, this branch, or a range."
  (interactive "P")
  (laya-review--start
   (or (and (not choose) (laya-review--buffer-source))
       (laya-review--source
        (if (not choose) 'worktree
          (cdr (assoc (completing-read "Review: " '("uncommitted vs HEAD" "staged" "this branch vs main" "revision range") nil t)
                      '(("uncommitted vs HEAD" . worktree) ("staged" . staged)
                        ("this branch vs main" . branch) ("revision range" . range)))))))))

;;;###autoload
(defun laya-review-branch ()
  "Score the hunks this branch changed since it left the main branch."
  (interactive)
  (laya-review--start (laya-review--source 'branch)))

(defun laya-review-refresh ()
  "Re-read the diff and rubric, then score everything again."
  (interactive)
  (laya-review--start laya-review--source))

(defun laya-review-cancel ()
  "Stop scoring the remaining hunks."
  (interactive)
  (laya-review--cancel-all)
  (setq laya-review--next (length laya-review--hunks))
  (laya-review--render))

(defun laya-review--hunk-at-point ()
  "Return the hunk on the current line or signal."
  (or (get-text-property (point) 'laya-review-hunk) (user-error "No hunk here")))

(defun laya-review-toggle ()
  "Show or hide the answers and diff of the hunk at point."
  (interactive)
  (let ((index (laya-review--hunk-index (laya-review--hunk-at-point))))
    (if (gethash index laya-review--expanded)
        (remhash index laya-review--expanded)
      (puthash index t laya-review--expanded))
    (laya-review--render)))

(defun laya-review-visit ()
  "Open the changed line of the hunk at point in another window."
  (interactive)
  (let ((data (laya-review--hunk-data (laya-review--hunk-at-point))))
    (when (plist-get data :deleted) (user-error "%s was deleted" (plist-get data :file)))
    (find-file-other-window (expand-file-name (plist-get data :file)
                                              (plist-get laya-review--source :root)))
    (goto-char (point-min))
    (forward-line (1- (plist-get data :line)))))

(defun laya-review-next-hunk (&optional count)
  "Move to the start of the next hunk row; COUNT negative moves back."
  (interactive "p")
  (let ((count (or count 1)))
    (dotimes (_ (abs count))
      (let ((here (get-text-property (point) 'laya-review-hunk))
            (step (if (> count 0) #'next-single-property-change #'previous-single-property-change)))
        (let ((position (point)))
          (while (and (setq position (funcall step position 'laya-review-hunk))
                      (or (null (get-text-property position 'laya-review-hunk))
                          (eq (get-text-property position 'laya-review-hunk) here))))
          (when position
            (goto-char position)
            (when (< count 0)
              (goto-char (or (previous-single-property-change (1+ (point)) 'laya-review-hunk)
                             (point))))))))))

(defun laya-review-previous-hunk (&optional count)
  "Move to the previous hunk row, COUNT times."
  (interactive "p")
  (laya-review-next-hunk (- (or count 1))))

(defun laya-review-toggle-sort ()
  "Sort hunks by risk or by position in the diff."
  (interactive)
  (setq laya-review--sort (if (eq laya-review--sort 'risk) 'diff 'risk))
  (message "LAYA review: sorted by %s" laya-review--sort)
  (laya-review--render))

(defun laya-review-edit-rubric ()
  "Open the rubric; after saving, press g in the review to apply it."
  (interactive)
  (find-file-other-window laya-review-rubric-file))

(defvar laya-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'laya-review-visit)
    (define-key map (kbd "TAB") #'laya-review-toggle)
    (define-key map (kbd "n") #'laya-review-next-hunk)
    (define-key map (kbd "p") #'laya-review-previous-hunk)
    (define-key map (kbd "g") #'laya-review-refresh)
    (define-key map (kbd "s") #'laya-review-toggle-sort)
    (define-key map (kbd "e") #'laya-review-edit-rubric)
    (define-key map (kbd "f") #'laya-review-toggle-focus)
    (define-key map (kbd "d") #'laya-review-focused-diff)
    (define-key map (kbd "C-c C-k") #'laya-review-cancel)
    map))

(define-derived-mode laya-review-mode special-mode "LAYA-Review"
  "Hunks of a diff, scored by LAYA against a JSON rubric.
\\{laya-review-mode-map}"
  (setq-local truncate-lines t
              revert-buffer-function (lambda (&rest _) (laya-review-refresh))
              header-line-format
              " RET visit  TAB details  ]] [[ hunks  f focus  d focused diff  gr rescore  s sort  e rubric  C-c C-k stop  q quit")
  (add-hook 'kill-buffer-hook #'laya-review--cancel-all nil t))

(with-eval-after-load 'evil
  (evil-define-key* '(normal motion) laya-review-mode-map
    (kbd "RET") #'laya-review-visit
    (kbd "TAB") #'laya-review-toggle
    "]]" #'laya-review-next-hunk
    "[[" #'laya-review-previous-hunk
    "gr" #'laya-review-refresh
    "s" #'laya-review-toggle-sort
    "e" #'laya-review-edit-rubric
    "f" #'laya-review-toggle-focus
    "d" #'laya-review-focused-diff
    "q" #'quit-window))

(provide 'laya-review)
;;; laya-review.el ends here
