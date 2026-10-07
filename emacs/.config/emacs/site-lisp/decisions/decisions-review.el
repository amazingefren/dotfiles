;;; decisions-review.el --- Score diff hunks with Decisions -*- lexical-binding: t -*-

(require 'decisions)
(require 'cl-lib)
(require 'color)
(require 'diff-mode)
(require 'subr-x)

(defgroup decisions-review nil "Score diff hunks with Decisions." :group 'decisions)

(defcustom decisions-review-rubric-file
  (expand-file-name "review-rubric.json"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "JSON rubric: questions, their risk weights, and optionally backend/model."
  :type 'file)
(defcustom decisions-review-concurrency 2
  "Hunks kept submitted at once.  The worker still evaluates them serially."
  :type 'integer)
(defcustom decisions-review-max-hunks 600 "Largest number of review units one review scores." :type 'integer)
(defcustom decisions-review-max-state-characters 12000
  "Characters of hunk text sent for one review unit.
The rubric's backends.<backend>.max_state_characters overrides it."
  :type 'integer)
(defcustom decisions-review-chunk-lines 150
  "Most diff rows in one review unit.
The rubric's backends.<backend>.chunk_lines overrides it."
  :type 'integer)

(defcustom decisions-review-high-risk 0.6 "Risk at or above which a hunk is high." :type 'number)
(defcustom decisions-review-medium-risk 0.3 "Risk at or above which a hunk is medium." :type 'number)
(defcustom decisions-review-chart-limit 10 "Hunks shown in the risk chart." :type 'integer)
(defcustom decisions-review-focus-threshold 0.3
  "Risk below which the focused views hide a hunk."
  :type 'number)
(defcustom decisions-review-state-function #'decisions-review-default-state
  "Function of one hunk plist returning the Decisions state for it."
  :type 'function)

(defconst decisions-review--owner "decisions-review" "Owner used for every review job.")
(defconst decisions-review--unasked-reason "no applicable checks"
  "Reason recorded for a unit no rubric question applies to.")

(declare-function eplot-make-plot "eplot" (headers &rest datas))
(declare-function svg-image "svg" (svg &rest props))
(declare-function evil-define-key* "evil-core" (state keymap key def &rest bindings))
(declare-function treesit-buffer-root-node "treesit.c" (&optional language tag))
(declare-function treesit-defun-name "treesit" (node))
(declare-function treesit-induce-sparse-tree "treesit.c" (root predicate &optional process-fn depth))
(declare-function treesit-node-type "treesit.c" (node))
(declare-function treesit-node-start "treesit.c" (node))
(declare-function treesit-node-end "treesit.c" (node))
(defvar treesit-defun-type-regexp)

(defun decisions-review--path (text)
  "Return the repository path in a ---/+++ header TEXT, or nil for /dev/null."
  (let ((path (string-trim (car (split-string text "\t")))))
    (when (and (string-prefix-p "\"" path) (string-suffix-p "\"" path))
      (setq path (substring path 1 -1)))
    (unless (equal path "/dev/null")
      (if (string-match "\\`[ab]/" path) (substring path 2) path))))

(defun decisions-review-parse-diff (diff)
  "Split unified DIFF into a list of hunk plists.
Each has :file, :line (first changed line in the new file), :header (the
function context after @@), :text, :removed, :added and :rows, a list of
\(KIND TEXT OLD NEW) where KIND is ?-, ?+ or ?\\s and OLD and NEW are the
line numbers the row sits at on each side."
  (let ((lines (split-string diff "\n"))
        old-file new-file hunks hunk old-left new-left old-line new-line)
    (cl-flet ((finish ()
                (when hunk
                  (dolist (key '(:text :removed :added))
                    (plist-put hunk key (string-join (nreverse (plist-get hunk key)) "\n")))
                  (plist-put hunk :rows (nreverse (plist-get hunk :rows)))
                  (push hunk hunks)
                  (setq hunk nil))))
      (dolist (line lines)
        (cond
         ;; Inside a hunk the counts decide, so "--- x" can be a removed line.
         ((and hunk (or (> old-left 0) (> new-left 0))
               (string-match-p "\\`[-+ \\]" line))
          (push line (plist-get hunk :text))
          (unless (eq (aref line 0) ?\\)
            (push (list (aref line 0) (substring line 1) old-line new-line) (plist-get hunk :rows)))
          (pcase (aref line 0)
            (?- (cl-decf old-left) (cl-incf old-line)
                (unless (plist-get hunk :line) (plist-put hunk :line new-line))
                (push (substring line 1) (plist-get hunk :removed)))
            (?+ (cl-decf new-left)
                (unless (plist-get hunk :line) (plist-put hunk :line new-line))
                (push (substring line 1) (plist-get hunk :added))
                (cl-incf new-line))
            (?\s (cl-decf old-left) (cl-decf new-left) (cl-incf old-line) (cl-incf new-line))))
         ((and hunk (string-prefix-p "\\" line))
          (push line (plist-get hunk :text)))
         ((string-match "\\`@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@ ?\\(.*\\)" line)
          (finish)
          (setq old-line (string-to-number (match-string 1 line))
                old-left (if (match-string 2 line) (string-to-number (match-string 2 line)) 1)
                new-line (string-to-number (match-string 3 line))
                new-left (if (match-string 4 line) (string-to-number (match-string 4 line)) 1))
          (setq hunk (list :file (or new-file old-file) :deleted (null new-file) :new (null old-file)
                           :line nil :header (match-string 5 line)
                           :text (list line) :removed nil :added nil :rows nil)))
         ((string-prefix-p "diff " line)
          (finish) (setq old-file nil new-file nil))
         ((string-prefix-p "--- " line)
          (finish) (setq old-file (decisions-review--path (substring line 4))))
         ((string-prefix-p "+++ " line)
          (setq new-file (decisions-review--path (substring line 4))))))
      (finish))
    (dolist (hunk hunks)
      (unless (plist-get hunk :line) (plist-put hunk :line 1)))
    (nreverse hunks)))

(defcustom decisions-review-max-file-characters 400000
  "Largest file, in characters, parsed for function boundaries."
  :type 'integer)
(defcustom decisions-review-max-definition-lines 40
  "Longest helper definition added to a hunk's state."
  :type 'integer)

(defun decisions-review--defun-name (start-line lines)
  "Guess a name from the definition starting at START-LINE of LINES."
  (let ((text (aref lines (1- start-line))))
    (when (string-match "\\_<\\(?:function\\|class\\|def\\|const\\|let\\|var\\|func\\|fn\\|interface\\|type\\)\\_>\\*?[ \t]+\\([[:alnum:]_$]+\\)" text)
      (match-string 1 text))))

(defun decisions-review--treesit-defuns ()
  "Return the buffer's defuns as a tree of (START END NAME . CHILDREN), or nil."
  (when (and (fboundp 'treesit-parser-list) (treesit-parser-list) treesit-defun-type-regexp)
    (let* ((spec treesit-defun-type-regexp)
           (predicate (if (and (consp spec) (stringp (car spec)))
                          (lambda (node) (and (string-match-p (car spec) (treesit-node-type node))
                                              (funcall (cdr spec) node)))
                        spec)))
      (cl-labels ((walk (tree)
                    (let ((children (mapcan #'walk (cdr tree))))
                      (if-let* ((node (car tree)))
                          (list (cons (line-number-at-pos (treesit-node-start node))
                                      (cons (line-number-at-pos (treesit-node-end node))
                                            (cons (ignore-errors (treesit-defun-name node)) children))))
                        children))))
        (walk (treesit-induce-sparse-tree (treesit-buffer-root-node) predicate))))))

(defun decisions-review--flat-defuns ()
  "Return top-level defuns found with `beginning-of-defun'.
For modes without tree-sitter."
  (when (derived-mode-p 'prog-mode)
    (let (defuns)
      (goto-char (point-max))
      (while (and (ignore-errors (beginning-of-defun)) (not (bobp)))
        (push (list (line-number-at-pos)
                    (save-excursion (end-of-defun) (max (line-number-at-pos) (1+ (line-number-at-pos (point)))))
                    nil)
              defuns))
      defuns)))

(defun decisions-review--analyze (file text)
  "Return (LINES . DEFUNS) for FILE's TEXT, or nil when it is too large.
LINES is a vector of its lines and DEFUNS its defun tree.  The major mode
runs without hooks, so no language server or linter starts."
  (when (and text (<= (length text) decisions-review-max-file-characters))
    (with-temp-buffer
      (insert text)
      (let ((lines (vconcat (split-string text "\n"))))
        (let ((buffer-file-name (expand-file-name file "/decisions-review/"))
              (enable-local-variables nil))
          (ignore-errors (delay-mode-hooks (set-auto-mode))))
        (let ((defuns (or (ignore-errors (decisions-review--treesit-defuns))
                          (ignore-errors (decisions-review--flat-defuns)))))
          (cl-labels ((name (nodes)
                        (dolist (node nodes)
                          (unless (nth 2 node) (setf (nth 2 node) (decisions-review--defun-name (car node) lines)))
                          (name (nthcdr 3 node)))))
            (name defuns))
          (cons lines defuns))))))

(defun decisions-review--matches-file-p (rows lines)
  "Return non-nil when the new-side ROWS agree with the file's LINES."
  (seq-every-p (lambda (row)
                 (or (eq (car row) ?-)
                     (let ((index (1- (nth 3 row))))
                       (and (< -1 index (length lines)) (equal (aref lines index) (nth 1 row))))))
               (seq-take rows 8)))

(defun decisions-review--marks (defuns count limit)
  "Return a vector giving, per line 1..COUNT, the review unit it belongs to.
A defun of at most LIMIT lines is one unit; a longer one is a unit for its
own body lines, with its inner defuns marked the same way."
  (let ((marks (make-vector (+ 2 count) nil)))
    (cl-labels ((mark (nodes)
                  (dolist (node nodes)
                    (cl-loop for line from (max 1 (car node)) to (min (nth 1 node) count)
                             do (aset marks line node))
                    (when (> (- (nth 1 node) (car node) -1) limit) (mark (nthcdr 3 node))))))
      (mark defuns))
    marks))

(defun decisions-review--rows-hunk (hunk rows name)
  "Return a hunk plist for ROWS of HUNK, headed with NAME when given."
  (let* ((first (car rows))
         (old-count (seq-count (lambda (row) (memq (car row) '(?- ?\s))) rows))
         (new-count (seq-count (lambda (row) (memq (car row) '(?+ ?\s))) rows))
         (old (nth 2 first)) (new (nth 3 first))
         (header (or name (plist-get hunk :header) ""))
         (changed (seq-find (lambda (row) (memq (car row) '(?- ?+))) rows)))
    (cl-flet ((side (kind) (string-join (mapcar #'cadr (seq-filter (lambda (row) (eq (car row) kind)) rows)) "\n")))
      (list :file (plist-get hunk :file) :deleted (plist-get hunk :deleted) :new (plist-get hunk :new)
            :line (nth 3 changed) :header header
            :text (string-join
                   (cons (format "@@ -%d,%d +%d,%d @@%s"
                                 (if (zerop old-count) (max 0 (1- old)) old) old-count
                                 (if (zerop new-count) (max 0 (1- new)) new) new-count
                                 (if (string-empty-p header) "" (concat " " header)))
                         (mapcar (lambda (row) (concat (char-to-string (car row)) (nth 1 row))) rows))
                   "\n")
            :removed (side ?-) :added (side ?+) :rows rows))))

(defun decisions-review--segments (rows marks limit)
  "Group ROWS into lists of at most LIMIT rows, keeping MARKS' units together.
Returns (NAME . ROWS) pairs; small neighbouring units share a segment."
  (let* ((count (1- (length marks)))
         (unit-of (lambda (row) (and marks (aref marks (min count (max 1 (nth 3 row)))))))
         runs merged)
    (dolist (row rows)
      (let ((unit (funcall unit-of row)))
        (if (and runs (eq (caar runs) unit))
            (push row (cdar runs))
          (push (list unit row) runs))))
    (setq runs (mapcar (lambda (run) (cons (car run) (reverse (cdr run)))) (nreverse runs)))
    (let (names current)
      (cl-flet ((emit ()
                  (when current
                    (push (cons (and names (string-join (reverse (delete-dups names)) ", ")) current) merged)
                    (setq current nil names nil))))
        (dolist (run runs)
          (let ((name (nth 2 (car run))) (run-rows (cdr run)))
            (when (> (+ (length current) (length run-rows)) limit) (emit))
            (while (> (length run-rows) limit)
              (push (cons name (seq-take run-rows limit)) merged)
              (setq run-rows (seq-drop run-rows limit)))
            (setq current (append current run-rows))
            (when name (push name names))))
        (emit)))
    (seq-filter (lambda (segment) (seq-some (lambda (row) (memq (car row) '(?- ?+))) (cdr segment)))
                (nreverse merged))))

(defun decisions-review--definitions (hunk analysis)
  "Return definitions from ANALYSIS of helpers HUNK's added lines call.
Only helpers defined in the same file, outside the hunk, and no longer
than `decisions-review-max-definition-lines' are included."
  (let* ((lines (car analysis))
         (rows (plist-get hunk :rows))
         (low (apply #'min most-positive-fixnum (mapcar (lambda (row) (nth 3 row)) rows)))
         (high (apply #'max 0 (mapcar (lambda (row) (nth 3 row)) rows)))
         (table (make-hash-table :test #'equal))
         (added (plist-get hunk :added))
         called)
    (cl-labels ((index (nodes)
                  (dolist (node nodes)
                    (when (nth 2 node) (puthash (nth 2 node) node table))
                    (index (nthcdr 3 node)))))
      (index (cdr analysis)))
    (let ((start 0))
      (while (string-match "\\_<\\([[:alpha:]_$][[:alnum:]_$]*\\)[ \t]*(" added start)
        (cl-pushnew (match-string 1 added) called :test #'equal)
        (setq start (match-end 0))))
    (string-join
     (delq nil
           (mapcar (lambda (name)
                     (when-let* ((node (gethash name table)))
                       (let ((from (car node)) (to (nth 1 node)))
                         (when (and (or (> from high) (< to low))
                                    (<= (- to from -1) decisions-review-max-definition-lines))
                           (string-join (append (seq-subseq lines (1- from) (min to (length lines))) nil) "\n")))))
                   (nreverse called)))
     "\n\n")))

(defun decisions-review-split-hunks (hunks &optional file-text)
  "Split HUNKS into review units of at most `decisions-review-chunk-lines' rows.
FILE-TEXT, a function of a path returning its text on the diff's new side,
lets units follow function boundaries and adds :definitions, the helpers a
unit calls from elsewhere in its file.  Without it, or when the file does
not match the diff, a long hunk is cut into runs of rows.  Every unit is a
valid hunk whose :header names the functions it covers."
  (let ((analyses (make-hash-table :test #'equal)))
    (mapcan
     (lambda (hunk)
       (let* ((file (plist-get hunk :file))
              (rows (plist-get hunk :rows))
              (analysis (and file-text (not (plist-get hunk :deleted))
                             (with-memoization (gethash file analyses)
                               (decisions-review--analyze file (funcall file-text file)))))
              (analysis (and analysis (decisions-review--matches-file-p rows (car analysis)) analysis))
              (units (if (<= (length rows) decisions-review-chunk-lines)
                         (list hunk)
                       (mapcar (lambda (segment) (decisions-review--rows-hunk hunk (cdr segment) (car segment)))
                               (decisions-review--segments
                                rows
                                (and analysis (cdr analysis)
                                     (decisions-review--marks (cdr analysis) (length (car analysis))
                                                         decisions-review-chunk-lines))
                                decisions-review-chunk-lines)))))
         (when analysis
           (dolist (unit units)
             (let ((definitions (decisions-review--definitions unit analysis)))
               (unless (string-empty-p definitions)
                 (plist-put unit :definitions definitions)))))
         units))
     hunks)))

(defun decisions-review--revision (source)
  "Return where SOURCE's new side lives.
A revision, \":\" for the index, or nil for the worktree."
  (let* ((arguments (seq-take-while (lambda (a) (not (equal a "--"))) (plist-get source :arguments)))
         (range (seq-find (lambda (a) (string-match-p "\\.\\." a)) arguments)))
    (cond ((member "--cached" arguments) ":")
          (range (string-match "\\.\\.\\.?\\(.*\\)\\'" range)
                 (let ((to (match-string 1 range))) (if (string-empty-p to) "HEAD" to))))))

(defun decisions-review--file-text-function (source)
  "Return a function reading a path at SOURCE's new side, memoized per path."
  (let ((root (plist-get source :root))
        (revision (decisions-review--revision source))
        (cache (make-hash-table :test #'equal)))
    (lambda (file)
      (with-memoization (gethash file cache)
        (ignore-errors
          (if revision
              (let ((default-directory root))
                (with-temp-buffer
                  (when (eql 0 (process-file "git" nil t nil "--no-pager" "show"
                                             (concat (if (equal revision ":") "" revision) ":" file)))
                    (buffer-string))))
            (let ((path (expand-file-name file root)))
              (when (file-regular-p path)
                (with-temp-buffer (insert-file-contents path) (buffer-string))))))))))

(defun decisions-review-load-rubric (&optional file)
  "Read and check the rubric in FILE, defaulting to `decisions-review-rubric-file'."
  (let* ((file (or file decisions-review-rubric-file))
         (rubric (with-temp-buffer
                   (insert-file-contents file)
                   (json-parse-buffer :object-type 'hash-table :array-type 'array
                                      :null-object :null :false-object :false))))
    (unless (and (hash-table-p rubric)
                 (equal (gethash "format" rubric) "decisions-review-rubric-v1")
                 (hash-table-p (gethash "questions" rubric))
                 (> (hash-table-count (gethash "questions" rubric)) 0))
      (user-error "%s is not a decisions-review-rubric-v1 file with questions"
                  (abbreviate-file-name file)))
    rubric))

(defconst decisions-review--gate-keys '("risk" "skip_files" "files" "added_matches" "removed_matches" "changed_matches"
                                  "comments_matches" "state")
  "Rubric question keys read by the review, never sent to the model.")

(defconst decisions-review--gate-syntax-table
  (let ((table (make-syntax-table)))
    (dolist (char (string-to-list ".,;:!?-+*/%=<>&|^~#@'\"`"))
      (modify-syntax-entry char "." table))
    (dolist (char '(?_ ?$))
      (modify-syntax-entry char "_" table))
    table)
  "Syntax for gate regexps: code punctuation ends a symbol.
The standard table counts `.' as a symbol character, so \\_< would never
match after `hashlib.' or `req.'.")

(defun decisions-review--match-p (regexp text)
  "Return non-nil when REGEXP matches TEXT.
REGEXP is a rubric string, an array of strings that must all match, or
absent, which matches anything."
  (with-syntax-table decisions-review--gate-syntax-table
    (decisions-review--match-1 regexp text)))

(defun decisions-review--match-1 (regexp text)
  "Match REGEXP, as in `decisions-review--match-p', against TEXT."
  (let ((case-fold-search t))
    (cond ((stringp regexp) (string-match-p regexp (or text "")))
          ((vectorp regexp) (seq-every-p (lambda (one) (decisions-review--match-1 one text)) regexp))
          (t t))))

(defun decisions-review--applies-p (question hunk rubric)
  "Return non-nil when RUBRIC's QUESTION should be asked about HUNK.
Facts code can check itself decide here: a removal question needs removed
lines, a SQL question needs SQL text.  The model is only asked what is left."
  (let ((file (plist-get hunk :file))
        (skip (list (gethash "skip_files" rubric) (gethash "skip_files" question))))
    (and (not (seq-some (lambda (regexp) (and (stringp regexp) (decisions-review--match-p regexp file))) skip))
         (decisions-review--match-p (gethash "files" question) file)
         (decisions-review--match-p (gethash "added_matches" question) (plist-get hunk :added))
         (decisions-review--match-p (gethash "changed_matches" question)
                               (concat (plist-get hunk :removed) "\n" (plist-get hunk :added)))
         (let ((comments (gethash "comments_matches" question)))
           (or (not (or (stringp comments) (vectorp comments)))
               (and (not (string-empty-p (or (plist-get hunk :comments) "")))
                    (decisions-review--match-p comments (plist-get hunk :comments)))))
         (let ((removed (gethash "removed_matches" question)))
           (or (not (or (stringp removed) (vectorp removed)))
               (and (not (string-empty-p (plist-get hunk :removed)))
                    (decisions-review--match-p removed (plist-get hunk :removed))))))))

(defvar decisions-review--modes (make-hash-table :test #'equal)
  "File extension -> the major mode `set-auto-mode' picked for it.")

(defvar python-indent-guess-indent-offset)

(defconst decisions-review--comment-modes
  '((("ts" "tsx" "mts" "cts" "js" "jsx" "mjs" "cjs" "go" "rs" "java" "kt" "swift" "c" "h"
      "cc" "cpp" "hpp" "cs" "php" "scss" "dart" "scala") . js-mode)
    (("py" "pyi") . python-mode)
    (("sh" "bash" "zsh") . sh-mode)
    (("rb" "yml" "yaml" "toml" "r" "pl" "tf" "hcl" "conf" "ini") . conf-unix-mode)
    (("el") . emacs-lisp-mode)
    (("sql") . sql-mode)
    (("lua") . lua-mode))
  "Built-in modes whose comment syntax matches files of these extensions.")

(defun decisions-review--set-mode (file)
  "Put the current buffer in FILE's major mode, without its hooks."
  (let* ((python-indent-guess-indent-offset nil)
         (extension (or (file-name-extension file) (file-name-nondirectory file)))
         (mode (gethash extension decisions-review--modes)))
    (if mode
        (ignore-errors (delay-mode-hooks (funcall mode)))
      (let ((buffer-file-name (expand-file-name file "/decisions-review/"))
            (enable-local-variables nil))
        (ignore-errors (delay-mode-hooks (set-auto-mode))))
      ;; A tree-sitter mode without its grammar has no comment syntax.
      (unless comment-start-skip
        (when-let* ((fallback (cdr (seq-find (lambda (entry) (member (downcase extension) (car entry)))
                                             decisions-review--comment-modes))))
          (ignore-errors (delay-mode-hooks (funcall fallback)))))
      (puthash extension major-mode decisions-review--modes))))

(defconst decisions-review--docstring-regexp
  "^[ \t]*[rRbBuU]?\\(\"\"\"\\|'''\\)\\(?:.\\|\n\\)*?\\1[ \t]*$"
  "A Python string statement on its own lines: a docstring, read as a comment.")

(defun decisions-review-split-comments (file text)
  "Return (CODE . COMMENTS) for TEXT from FILE.
CODE is TEXT without comments or blank lines, and COMMENTS the removed
comments, one per paragraph.  FILE's major mode decides what a comment is,
so `//' inside a string or URL stays code; Python docstrings count as
comments."
  (if (string-empty-p (string-trim (or text "")))
      (cons (or text "") "")
    (with-temp-buffer
      (insert text)
      (decisions-review--set-mode file)
      (let (comments)
        (when (derived-mode-p 'python-mode 'python-base-mode)
          (goto-char (point-min))
          (while (re-search-forward decisions-review--docstring-regexp nil t)
            (let ((docstring (match-string 0)))
              (replace-match "" t t)
              (push (string-trim docstring) comments))))
        (goto-char (point-min))
        (while (and comment-start-skip (< (point) (point-max))
                    (ignore-errors (comment-search-forward (point-max) t)))
          (let ((start (or (nth 8 (syntax-ppss)) (point))))
            (goto-char start)
            (unless (forward-comment 1) (goto-char (point-max)))
            ;; A line comment ends past its newline; keep the newline.
            (when (and (> (point) start) (eq (char-before) ?\n)) (backward-char))
            (let ((end (point)))
              (push (string-trim (buffer-substring-no-properties start end)) comments)
              (delete-region start end))))
        (let ((code (replace-regexp-in-string "[ \t]+$" "" (buffer-string))))
          (cons (string-join (seq-remove #'string-blank-p (split-string code "\n")) "\n")
                (string-join (nreverse (seq-remove #'string-empty-p comments)) "\n\n")))))))

(defun decisions-review--code-hunk (hunk)
  "Return HUNK with comments moved out of its code into :comments.
The code questions then judge code only, so no comment can vouch for it."
  (if (plist-member hunk :comments)
      hunk
    (let* ((file (or (plist-get hunk :file) ""))
           (added (decisions-review-split-comments file (plist-get hunk :added)))
           (removed (decisions-review-split-comments file (plist-get hunk :removed)))
           (definitions (and (plist-get hunk :definitions)
                             (car (decisions-review-split-comments file (plist-get hunk :definitions)))))
           (copy (copy-sequence hunk)))
      (setq copy (plist-put copy :added (car added)))
      (setq copy (plist-put copy :removed (car removed)))
      (setq copy (plist-put copy :definitions (and definitions (not (string-empty-p definitions)) definitions)))
      (plist-put copy :comments (cdr added)))))

(defun decisions-review-comment-state (hunk)
  "Describe HUNK's added comments beside the code they sit on, within the budget."
  (let* ((header (plist-get hunk :header))
         (comments (decisions-review--clip (or (plist-get hunk :comments) "")
                                      (/ decisions-review-max-state-characters 2)))
         (code (decisions-review--clip (plist-get hunk :added)
                                  (- decisions-review-max-state-characters (length comments)))))
    (decisions--object "file" (plist-get hunk :file)
                  "location" (if (and header (not (string-empty-p header))) header "")
                  "comments" comments
                  "code" code)))

(defun decisions-review--questions (rubric &optional hunk state)
  "Return RUBRIC's questions for HUNK without the review-only keys.
Without HUNK every question is returned.  With STATE, only questions asked
over that state: \"code\" (the default) or \"comments\"."
  (let ((questions (make-hash-table :test #'equal)))
    (maphash (lambda (name question)
               (when (and (or (null state) (equal state (gethash "state" question "code")))
                          (or (null hunk) (decisions-review--applies-p question hunk rubric)))
                 (let ((copy (decisions--json-copy question)))
                   (dolist (key decisions-review--gate-keys) (remhash key copy))
                   (puthash name copy questions))))
             (gethash "questions" rubric))
    questions))

(defun decisions-review--clip (text limit)
  "Return TEXT limited to LIMIT characters."
  (if (> (length text) limit) (concat (substring text 0 limit) "\n…") text))

(defun decisions-review--setting (rubric key default)
  "Return RUBRIC's KEY for its backend, from backends.<backend>, or DEFAULT."
  (let ((settings (gethash (gethash "backend" rubric "mlx")
                           (gethash "backends" rubric (make-hash-table :test #'equal)))))
    (or (and (hash-table-p settings) (gethash key settings)) default)))

(defun decisions-review-default-state (hunk)
  "Describe HUNK as named fields the questions can cite, within the state budget.
Helper definitions get at most a third of the budget, and removed text at
most half of what is left unless added text leaves it more."
  (let* ((definitions (decisions-review--clip (or (plist-get hunk :definitions) "")
                                         (/ decisions-review-max-state-characters 3)))
         (removed (plist-get hunk :removed)) (added (plist-get hunk :added))
         (header (plist-get hunk :header))
         (budget (- decisions-review-max-state-characters (length definitions)))
         (removed-limit (max (/ budget 2) (- budget (length added))))
         (removed (decisions-review--clip removed removed-limit))
         (added (decisions-review--clip added (- budget (length removed)))))
    (let ((state (decisions--object "file" (plist-get hunk :file)
			       "location" (if (and header (not (string-empty-p header))) header "")
			       "change" (cond ((plist-get hunk :new) "new file")
					      ((plist-get hunk :deleted) "deleted file")
					      ((string-empty-p removed) "lines added")
					      ((string-empty-p added) "lines removed")
					      (t "lines replaced"))
			       "removed" removed
			       "added" added)))
      (unless (string-empty-p definitions) (puthash "definitions" definitions state))
      state)))

(defun decisions-review-risk (answers rubric)
  "Return (RISK . REASON) for Decisions ANSWERS under RUBRIC's risk weights.
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
                ;; The most likely option may be harmless; name the riskiest.
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
(defun decisions-review-requests (hunk rubric)
  "Return the model calls RUBRIC makes for HUNK, as (KIND STATE QUESTIONS) lists.
KIND is \"code\", over HUNK with its comments removed, or \"comments\",
over the comments beside that code.  A call is left out when no question
applies to it."
  (let* ((hunk (decisions-review--code-hunk hunk))
         (decisions-review-max-state-characters
          (decisions-review--setting rubric "max_state_characters" decisions-review-max-state-characters)))
    (delq nil
          (mapcar (lambda (kind)
                    (let ((questions (decisions-review--questions rubric hunk kind)))
                      (when (> (hash-table-count questions) 0)
                        (list kind
                              (funcall (if (equal kind "code") decisions-review-state-function
                                         #'decisions-review-comment-state)
                                       hunk)
                              questions))))
                  '("code" "comments")))))

(cl-defun decisions-review-submit-hunk (hunk callback &key rubric)
  "Ask Decisions RUBRIC's questions about HUNK and return its job id or ids.
Code questions see HUNK with its comments removed; comment questions see
the comments beside that code, in a job of their own.  CALLBACK receives
one plist with :status, :risk, :reason, :answers, :jobs and :snapshot once
every job ends; :jobs lists each call's :kind, :state, :questions,
:answers, :status and :ms.  This is the entry point for other callers,
such as live edit followers."
  (let* ((rubric (or rubric (decisions-review-load-rubric)))
         (model (gethash "model" rubric))
         (requests (decisions-review-requests hunk rubric))
         (remaining (length requests))
         (merged (make-hash-table :test #'equal))
         jobs failure last)
    (if (null requests)
        ;; Settle on a later tick so callers pumping from the callback do not recurse.
        (progn (run-at-time 0 nil callback
                            (list :status "succeeded" :risk 0.0 :reason decisions-review--unasked-reason
                                  :answers merged :jobs nil :snapshot (make-hash-table :test #'equal)))
               nil)
      (let ((ids
             (mapcar
              (pcase-lambda (`(,kind ,state ,questions))
                (decisions-submit state questions
                             :backend (gethash "backend" rubric "mlx")
                             :model (and (stringp model) model)
                             :revision (let ((revision (gethash "revision" rubric)))
                                         (and (stringp revision) revision))
                             :allow-truncation t
                             :owner decisions-review--owner
                             :callback
                             (lambda (snapshot)
                               (let* ((status (gethash "status" snapshot))
                                      (result (gethash "result" snapshot))
                                      (answers (and (hash-table-p result) (gethash "answers" result))))
                                 (setq last snapshot)
                                 (push (list :kind kind :state state :questions questions
                                             :answers answers :status status
                                             :ms (and (hash-table-p result) (gethash "timing_ms" result)))
                                       jobs)
                                 (if (and (equal status "succeeded") (hash-table-p answers))
                                     (maphash (lambda (name answer) (puthash name answer merged)) answers)
                                   (setq failure snapshot))
                                 (when (zerop (cl-decf remaining))
                                   (setq jobs (sort jobs (lambda (a b) (string< (plist-get a :kind) (plist-get b :kind)))))
                                   (funcall callback
                                            (if failure
                                                (list :status (gethash "status" failure) :jobs jobs :snapshot failure)
                                              (let ((scored (decisions-review-risk merged rubric)))
                                                (list :status "succeeded" :risk (car scored) :reason (cdr scored)
                                                      :answers merged :jobs jobs :snapshot last)))))))))
              requests)))
        (if (cdr ids) ids (car ids))))))

(defcustom decisions-review-cases-file
  (expand-file-name "tests/review-cases.json"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Labeled hunks that `decisions-review-eval' scores the rubric against."
  :type 'file)

(defun decisions-review--case-hunk (case)
  "Return a hunk plist for the labeled CASE."
  (let ((definitions (gethash "definitions" case)))
    (list :file (gethash "file" case) :line 1 :header "" :new nil :deleted nil
          :removed (gethash "removed" case "") :added (gethash "added" case "")
          :definitions (and (stringp definitions) definitions))))

(defun decisions-review--case-labels (case outcome)
  "Return (QUESTION WANT P) triples for CASE given its OUTCOME.
P is nil when the gates did not ask QUESTION.  A case with no labels
expects every question it is asked to answer false."
  (let ((expect (gethash "expect" case))
        (answers (plist-get outcome :answers))
        labels)
    (if (and (hash-table-p expect) (> (hash-table-count expect) 0))
        (maphash (lambda (question want) (push (list question (eq want t) nil) labels)) expect)
      (when (hash-table-p answers)
        (maphash (lambda (question _) (push (list question nil nil) labels)) answers)))
    (mapcar (lambda (label)
              (let ((answer (and (hash-table-p answers) (gethash (car label) answers))))
                (list (car label) (nth 1 label) (and (hash-table-p answer) (gethash "noul" answer)))))
            labels)))

(defun decisions-review--eval-report (rubric cases outcomes seconds)
  "Return the evaluation report text for CASES and their OUTCOMES under RUBRIC."
  (let ((table (make-hash-table :test #'equal)) misses failed)
    (dolist (case cases)
      (let ((outcome (gethash case outcomes)))
        (if (not (equal (plist-get outcome :status) "succeeded"))
            (push (gethash "name" case) failed)
          (pcase-dolist (`(,question ,want ,p) (decisions-review--case-labels case outcome))
            (let ((row (or (gethash question table) (puthash question (make-vector 9 0) table)))
                  (said (and p (>= p 0.5))))
              (cl-incf (aref row (if want 2 3)))
              (cond ((and want said) (cl-incf (aref row 0)))
                    ((and want (null p)) (cl-incf (aref row 4)))
                    (said (cl-incf (aref row 1))))
              (when p
                (cl-incf (aref row (if want 5 7)) p)
                (cl-incf (aref row (if want 6 8))))
              (unless (eq want (and said t))
                (push (format "  %-26s %-11s %-9s %s" question
                              (if want "missed" "false alarm")
                              (if p (format "P %.2f" p) "not asked")
                              (gethash "name" case))
                      misses)))))))
    (let ((caught 0) (alarms 0) (bad 0) lines)
      (dolist (question (sort (hash-table-keys table) #'string<))
        (let ((row (gethash question table)))
          (cl-incf caught (aref row 0)) (cl-incf alarms (aref row 1)) (cl-incf bad (aref row 2))
          (cl-flet ((mean (sum n) (if (zerop (aref row n)) "  - " (format "%.2f" (/ (aref row sum) (aref row n))))))
            (push (format "%-26s caught %d/%d  false alarms %d/%d  mean P bad %s fine %s%s"
                          question (aref row 0) (aref row 2) (aref row 1) (aref row 3)
                          (mean 5 6) (mean 7 8)
                          (if (> (aref row 4) 0) (format "  (%d not asked)" (aref row 4)) ""))
                  lines))))
      (let ((backend (gethash "backend" rubric "mlx")))
        (concat
         (format "Decisions review eval  %s · %s · %d cases · %.1fs\n"
                 backend (gethash "model" rubric (pcase backend
                                           ("jev" decisions-jev-model)
                                           ("laya" decisions-laya-model)
                                           (_ decisions-mlx-model)))
                 (length cases) seconds)
         (format "recall %.0f%%  precision %.0f%%  at P >= 0.5\n\n"
                 (/ (* 100.0 caught) (max 1 bad))
                 (/ (* 100.0 caught) (max 1 (+ caught alarms))))
         (string-join (nreverse lines) "\n")
         (if misses (concat "\n\nWrong answers\n" (string-join (nreverse misses) "\n")) "")
         (if failed (concat "\n\nFailed\n  " (string-join (nreverse failed) "\n  ")) "")
         "\n")))))

;;;###autoload
(defun decisions-review-eval (&optional callback)
  "Score the rubric against `decisions-review-cases-file' and show recall and precision.
CALLBACK, when given, receives the report text instead of a buffer."
  (interactive)
  (let* ((rubric (decisions-review-load-rubric))
         (cases (append (gethash "cases" (with-temp-buffer
                                           (insert-file-contents decisions-review-cases-file)
                                           (json-parse-buffer :object-type 'hash-table :array-type 'array
                                                              :null-object :null :false-object :false)))
                        nil))
         (pending cases) (inflight 0) (started (current-time))
         (outcomes (make-hash-table :test #'eq)))
    (cl-labels ((finish ()
                  (let ((report (decisions-review--eval-report rubric cases outcomes
                                                          (float-time (time-since started)))))
                    (if callback (funcall callback report)
                      (with-current-buffer (get-buffer-create "*Decisions review eval*")
                        (let ((inhibit-read-only t)) (erase-buffer) (insert report))
                        (special-mode)
                        (goto-char (point-min))
                        (display-buffer (current-buffer))))))
                (settle (case outcome)
                  (puthash case outcome outcomes)
                  (cl-decf inflight)
                  (if (and (null pending) (zerop inflight)) (finish) (pump)))
                (pump ()
                  (while (and pending (< inflight (max 1 decisions-review-concurrency)))
                    (let ((case (pop pending)))
                      (cl-incf inflight)
                      (condition-case err
                          (decisions-review-submit-hunk (decisions-review--case-hunk case)
                                                   (lambda (outcome) (settle case outcome))
                                                   :rubric rubric)
                        (error (run-at-time 0 nil #'settle case
                                            (list :status "failed" :error (error-message-string err)))))))))
      (message "Decisions review eval: scoring %d cases" (length cases))
      (pump))))

(defcustom decisions-review-lint-file
  (expand-file-name "rubric-lint.json"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Meta-questions `decisions-review-lint-rubric' asks about each rubric question."
  :type 'file)

(defconst decisions-review--state-fields
  '(("code" . (("file" . "path of the changed file")
               ("location" . "function or unit name")
               ("change" . "new file, lines added, lines removed, or lines replaced")
               ("removed" . "removed lines, comments stripped")
               ("added" . "added lines, comments stripped")
               ("definitions" . "same-file helpers the added lines call, when any")))
    ("comments" . (("file" . "path of the changed file")
                   ("location" . "function or unit name")
                   ("comments" . "comments on the added lines")
                   ("code" . "the added lines with comments removed"))))
  "What each kind of review call's state holds, as the lint describes it.")

(defun decisions-review--lint-state (question)
  "Return the lint state describing rubric QUESTION and the state it is asked over."
  (let ((shown (decisions--json-copy question))
        (fields (make-hash-table :test #'equal)))
    (dolist (key decisions-review--gate-keys) (remhash key shown))
    (pcase-dolist (`(,name . ,description)
                   (cdr (assoc (gethash "state" question "code") decisions-review--state-fields)))
      (puthash name description fields))
    (decisions--object "question" shown "state_fields" fields)))

;;;###autoload
(defun decisions-review-lint-rubric (&optional callback)
  "Ask the rubric's backend to judge each rubric question for flaws and steering.
Each question is checked for combined conditions, leading wording,
overlapping or incomplete criteria, needing information its state lacks,
and undefined judgment words.  Two control questions, one built badly and
one clean, show whether the lint itself can be trusted.  CALLBACK, when
given, receives the report text instead of a buffer."
  (interactive)
  (let* ((rubric (decisions-review-load-rubric))
         (lint (with-temp-buffer
                 (insert-file-contents decisions-review-lint-file)
                 (json-parse-buffer :object-type 'hash-table :array-type 'array
                                    :null-object :null :false-object :false)))
         (meta (gethash "meta_questions" lint))
         (targets (append (mapcar (lambda (name) (cons name (gethash name (gethash "questions" rubric))))
                                  (sort (hash-table-keys (gethash "questions" rubric)) #'string<))
                          (mapcar (lambda (name) (cons name (gethash name (gethash "controls" lint))))
                                  (sort (hash-table-keys (gethash "controls" lint)) #'string<))))
         (pending targets) (inflight 0) (results (make-hash-table :test #'equal))
         (model (gethash "model" rubric)))
    (cl-labels
        ((report ()
           (let ((flag-names (sort (hash-table-keys meta) #'string<))
                 (expect (gethash "control_expect" lint)))
             (concat
              (format "Decisions rubric lint  %s · %d questions + %d controls · P >= 0.5 flags\n\n"
                      (gethash "backend" rubric "mlx") (hash-table-count (gethash "questions" rubric))
                      (hash-table-count (gethash "controls" lint)))
              (mapconcat
               (pcase-lambda (`(,name . ,_))
                 (let* ((answers (gethash name results))
                        (flags (and (hash-table-p answers)
                                    (seq-filter (lambda (flag) (>= (gethash "noul" (gethash flag answers (make-hash-table)) 0) 0.5))
                                                flag-names)))
                        (control (and (hash-table-p expect) (gethash name expect))))
                   (concat
                    (format "%-26s %s" name
                            (cond ((not (hash-table-p answers)) (format "failed: %s" answers))
                                  (flags (mapconcat (lambda (flag) (format "%s %.2f" flag (gethash "noul" (gethash flag answers))))
                                                    flags "  "))
                                  (t "clean")))
                    (if control
                        (let ((wanted (append control nil)))
                          (if (equal (sort (copy-sequence wanted) #'string<) flags)
                              "   [control as expected]"
                            (format "   [control expected: %s]" (if wanted (string-join wanted ", ") "clean"))))
                      ""))))
               targets "\n")
              "\n")))
         (finish ()
           (let ((text (report)))
             (if callback (funcall callback text)
               (with-current-buffer (get-buffer-create "*Decisions rubric lint*")
                 (let ((inhibit-read-only t)) (erase-buffer) (insert text))
                 (special-mode)
                 (goto-char (point-min))
                 (display-buffer (current-buffer))))))
         (settle (name value)
           (puthash name value results)
           (cl-decf inflight)
           (if (and (null pending) (zerop inflight)) (finish) (pump)))
         (pump ()
           (while (and pending (< inflight (max 1 decisions-review-concurrency)))
             (pcase-let ((`(,name . ,question) (pop pending)))
               (cl-incf inflight)
               (condition-case err
                   (decisions-submit (decisions-review--lint-state question) (decisions--json-copy meta)
                                :backend (gethash "backend" rubric "mlx")
                                :model (and (stringp model) model)
                                :allow-truncation t
                                :owner decisions-review--owner
                                :callback
                                (lambda (snapshot)
                                  (let ((result (gethash "result" snapshot)))
                                    (settle name (if (equal (gethash "status" snapshot) "succeeded")
                                                     (gethash "answers" result)
                                                   (gethash "status" snapshot))))))
                 (error (run-at-time 0 nil #'settle name (error-message-string err))))))))
      (message "Decisions rubric lint: %d questions" (length targets))
      (pump))))

(defun decisions-review--git (root &rest arguments)
  "Return Git's output for ARGUMENTS in ROOT, or signal its error."
  (let ((default-directory root))
    (with-temp-buffer
      (let ((status (apply #'process-file "git" nil t nil arguments)))
        (unless (eql status 0)
          (user-error "git %s: %s" (string-join arguments " ") (string-trim (buffer-string))))
        (buffer-string)))))

(defun decisions-review--root ()
  "Return the Git worktree root for `default-directory'."
  (file-name-as-directory (string-trim (decisions-review--git default-directory "rev-parse" "--show-toplevel"))))

(defcustom decisions-review-max-untracked-file-size 100000
  "Largest untracked file, in bytes, added to a review as a new file."
  :type 'integer)

(defun decisions-review--untracked-diff (root)
  "Return new-file diffs for ROOT's untracked, unignored files.
`git diff' leaves these out, yet new files are often the ones to review."
  (let ((default-directory root))
    (mapconcat
     (lambda (file)
       (let ((size (file-attribute-size (file-attributes (expand-file-name file root)))))
         (if (and size (<= size decisions-review-max-untracked-file-size))
             (with-temp-buffer
               ;; --no-index exits 1 when the files differ, which they always do.
               (process-file "git" nil t nil "--no-pager" "diff" "--no-index" "--no-color"
                             "--src-prefix=a/" "--dst-prefix=b/" "--" "/dev/null" file)
               (buffer-string))
           "")))
     (split-string (decisions-review--git root "ls-files" "--others" "--exclude-standard" "-z") "\0" t)
     "")))

(defun decisions-review--diff (root arguments &optional untracked)
  "Return the diff of ARGUMENTS in ROOT with fixed, parseable formatting.
With UNTRACKED, append untracked files as new-file diffs."
  (concat (apply #'decisions-review--git root "--no-pager" "diff" "--no-ext-diff" "--no-color"
                 "--src-prefix=a/" "--dst-prefix=b/" arguments)
          (if untracked (decisions-review--untracked-diff root) "")))

(defun decisions-review--main-branch (root)
  "Return ROOT's main branch name."
  (or (and (fboundp 'magit-main-branch)
           (let ((default-directory root)) (magit-main-branch)))
      (seq-find (lambda (branch)
                  (eql 0 (let ((default-directory root))
                           (process-file "git" nil nil nil "rev-parse" "--verify" "--quiet" branch))))
                '("main" "master"))
      (user-error "No main or master branch")))

(defun decisions-review--source (kind)
  "Return a source plist (:root :label :arguments or :diff) for KIND."
  (let ((root (decisions-review--root)))
    (pcase kind
      ('worktree (list :root root :label "uncommitted changes vs HEAD" :arguments '("HEAD" "--")
                       :untracked t))
      ('staged (list :root root :label "staged changes" :arguments '("--cached" "--")))
      ;; main...HEAD alone would miss uncommitted work.
      ('branch (let* ((main (decisions-review--main-branch root))
                      (base (string-trim (decisions-review--git root "merge-base" main "HEAD"))))
                 (list :root root :label (format "this branch + uncommitted vs %s" main)
                       :arguments (list base "--") :untracked t)))
      ('range (let ((range (read-string "Revision range: " "HEAD~1..HEAD")))
                (list :root root :label range :arguments (list range "--")))))))

(defvar magit-buffer-range)
(defvar magit-buffer-typearg)
(defvar magit-buffer-diff-files)

(defun decisions-review--buffer-source ()
  "Return a source for the diff shown in the current buffer, or nil."
  (cond
   ((derived-mode-p 'magit-diff-mode)
    (let ((root (decisions-review--root)))
      (list :root root
            :label (format "magit diff %s" (or magit-buffer-range "working tree"))
            :arguments (append (and magit-buffer-typearg (list magit-buffer-typearg))
                               (and magit-buffer-range (list magit-buffer-range))
                               (cons "--" magit-buffer-diff-files)))))
   ((derived-mode-p 'diff-mode)
    (list :root (condition-case nil (decisions-review--root) (error default-directory))
          :label (format "diff in %s" (buffer-name))
          :diff (buffer-substring-no-properties (point-min) (point-max))))))

(cl-defstruct (decisions-review--hunk (:constructor decisions-review--make-hunk))
  index data status job risk reason answers error jobs)

(defvar-local decisions-review--source nil)
(defvar-local decisions-review--hunks nil)
(defvar-local decisions-review--rubric nil)
(defvar-local decisions-review--next 0)
(defvar-local decisions-review--inflight 0)
(defvar-local decisions-review--generation 0)
(defvar-local decisions-review--expanded nil)
(defvar-local decisions-review--sort 'risk)
(defvar-local decisions-review--render-timer nil)
(defvar-local decisions-review--started nil)
(defvar-local decisions-review--focus nil "Non-nil hides hunks below `decisions-review-focus-threshold'.")
(defvar-local decisions-review--show-unasked nil "Non-nil lists units no question applied to.")

(defun decisions-review--unasked-p (hunk)
  "Return non-nil when HUNK was scored without asking anything."
  (and (eq (decisions-review--hunk-status hunk) 'scored)
       (equal (decisions-review--hunk-reason hunk) decisions-review--unasked-reason)))
(defvar-local decisions-review--review-buffer nil "The review a focused diff buffer follows.")

(defun decisions-review--level (risk)
  "Return high, medium or low for RISK."
  (cond ((>= risk decisions-review-high-risk) 'high)
        ((>= risk decisions-review-medium-risk) 'medium)
        (t 'low)))

(defun decisions-review--face (risk)
  "Return the face used for RISK."
  (pcase (decisions-review--level risk) ('high 'error) ('medium 'warning) (_ 'success)))

(defun decisions-review--hex (face attribute)
  "Return FACE's ATTRIBUTE color as #rrggbb, which SVG understands."
  (let ((color (if (eq attribute :background) (face-background face nil 'default)
                 (face-foreground face nil 'default))))
    (if-let* ((values (and color (color-values color))))
        (apply #'color-rgb-to-hex (append (mapcar (lambda (v) (/ v 65535.0)) values) '(2)))
      "#808080")))

(defun decisions-review--cancel-all ()
  "Cancel this buffer's unfinished jobs and ignore their late callbacks."
  (cl-incf decisions-review--generation)
  (seq-doseq (hunk decisions-review--hunks)
    (when (and (decisions-review--hunk-job hunk)
               (member (decisions-review--hunk-status hunk) '(queued)))
      (dolist (job (ensure-list (decisions-review--hunk-job hunk)))
        (ignore-errors (decisions-cancel job decisions-review--owner)))
      (setf (decisions-review--hunk-status hunk) 'cancelled)))
  (setq decisions-review--inflight 0))

(defun decisions-review--pump (buffer)
  "Submit BUFFER's next hunks up to `decisions-review-concurrency'."
  (with-current-buffer buffer
    (while (and (< decisions-review--inflight decisions-review-concurrency)
                (< decisions-review--next (length decisions-review--hunks)))
      (let* ((hunk (aref decisions-review--hunks decisions-review--next))
             (generation decisions-review--generation))
        (cl-incf decisions-review--next)
        (cl-incf decisions-review--inflight)
        (setf (decisions-review--hunk-status hunk) 'queued)
        (condition-case err
            (setf (decisions-review--hunk-job hunk)
                  (decisions-review-submit-hunk
                   (decisions-review--hunk-data hunk)
                   (lambda (outcome) (decisions-review--scored buffer generation hunk outcome))
                   :rubric decisions-review--rubric))
          (error (cl-decf decisions-review--inflight)
                 (setf (decisions-review--hunk-status hunk) 'failed
                       (decisions-review--hunk-error hunk) (error-message-string err))))))
    (decisions-review--schedule-render)))

(defun decisions-review--scored (buffer generation hunk outcome)
  "Record OUTCOME for HUNK if BUFFER is still on GENERATION, then continue."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (= generation decisions-review--generation)
        (cl-decf decisions-review--inflight)
        (if (equal (plist-get outcome :status) "succeeded")
            (setf (decisions-review--hunk-status hunk) 'scored
                  (decisions-review--hunk-risk hunk) (plist-get outcome :risk)
                  (decisions-review--hunk-reason hunk) (plist-get outcome :reason)
                  (decisions-review--hunk-answers hunk) (plist-get outcome :answers)
                  (decisions-review--hunk-jobs hunk) (plist-get outcome :jobs))
          (let ((error-object (gethash "error" (plist-get outcome :snapshot))))
            (setf (decisions-review--hunk-status hunk) 'failed
                  (decisions-review--hunk-error hunk)
                  (if (hash-table-p error-object) (gethash "message" error-object)
                    (plist-get outcome :status)))))
        (decisions-review--pump buffer)))))

(defun decisions-review--schedule-render ()
  "Redraw soon, coalescing bursts of results."
  (unless (timerp decisions-review--render-timer)
    (let ((buffer (current-buffer)))
      (setq decisions-review--render-timer
            (run-at-time 0.15 nil
                         (lambda ()
                           (when (buffer-live-p buffer)
                             (with-current-buffer buffer
                               (setq decisions-review--render-timer nil)
                               (decisions-review--render)))))))))

(defun decisions-review--ordered ()
  "Return hunks in display order."
  (let ((hunks (append decisions-review--hunks nil)))
    (if (eq decisions-review--sort 'risk)
        (sort hunks (lambda (a b) (> (or (decisions-review--hunk-risk a) -1)
                                     (or (decisions-review--hunk-risk b) -1))))
      hunks)))

(defun decisions-review--label (hunk)
  "Return FILE:LINE for HUNK."
  (let ((data (decisions-review--hunk-data hunk)))
    (format "%s:%d" (plist-get data :file) (plist-get data :line))))

(defun decisions-review--chart (scored)
  "Return an eplot image of the riskiest SCORED hunks, or nil."
  ;; eplot fails on bars that round to zero, and they say nothing anyway.
  (setq scored (seq-filter (lambda (hunk) (>= (decisions-review--hunk-risk hunk) 0.05)) scored))
  (when (and scored (display-graphic-p) (require 'eplot nil t))
    (let* ((top (seq-take (sort (copy-sequence scored)
                                (lambda (a b) (> (decisions-review--hunk-risk a)
                                                 (decisions-review--hunk-risk b))))
                          decisions-review-chart-limit))
           (window (get-buffer-window (current-buffer)))
           (width (min 1000 (max 400 (truncate (* 0.9 (if window (window-pixel-width window) 800))))))
           (svg (eplot-make-plot
                 `((Format horizontal-bar-chart)
                   (Mode ,(if (eq (frame-parameter nil 'background-mode) 'dark) 'dark 'light))
                   (Width ,width)
                   (Height ,(+ 50 (* 26 (length top))))
                   (Title "Riskiest hunks")
                   (Background-Color ,(decisions-review--hex 'default :background))
                   (Chart-Color ,(decisions-review--hex 'default :foreground))
                   (Min 0) (Max 1)
                   (Color ,(mapconcat (lambda (hunk)
                                        (decisions-review--hex (decisions-review--face (decisions-review--hunk-risk hunk))
                                                          :foreground))
                                      top " ")))
                 (mapcar (lambda (hunk)
                           (list (format "%.2f" (decisions-review--hunk-risk hunk))
                                 (format "# Label: %s"
                                         (file-name-nondirectory (decisions-review--label hunk)))))
                         top))))
      (svg-image svg))))

(defun decisions-review--bar (risk)
  "Return a ten-cell bar for RISK."
  (let ((filled (round (* 10 risk))))
    (concat (make-string filled ?█) (make-string (- 10 filled) ?░))))

(defun decisions-review--insert-answers (answers)
  "Insert every Decisions answer in ANSWERS with its distribution."
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

(defun decisions-review--insert-jobs (hunk)
  "Insert each model call HUNK made, with its questions' answers."
  (let ((jobs (decisions-review--hunk-jobs hunk)))
    (if (null jobs)
        (when-let* ((answers (decisions-review--hunk-answers hunk)))
          (decisions-review--insert-answers answers))
      (dolist (job jobs)
        (let ((questions (plist-get job :questions)) (ms (plist-get job :ms)))
          (insert "    " (propertize (format "%s call" (plist-get job :kind)) 'face 'bold)
                  (propertize (format "  %d question%s%s%s · v shows the request\n"
                                      (hash-table-count questions)
                                      (if (= (hash-table-count questions) 1) "" "s")
                                      (if (numberp ms) (format " · %.0f ms" ms) "")
                                      (if (equal (plist-get job :status) "succeeded") ""
                                        (format " · %s" (plist-get job :status))))
                              'face 'shadow))
          (when (hash-table-p (plist-get job :answers))
            (decisions-review--insert-answers (plist-get job :answers))))))))

(defun decisions-review--file-row (file units)
  "Insert the parent row for FILE, counting all of its UNITS."
  (let* ((start (point))
         (scored (seq-filter (lambda (h) (eq (decisions-review--hunk-status h) 'scored)) units))
         (top (car (sort (copy-sequence scored)
                         (lambda (a b) (> (decisions-review--hunk-risk a) (decisions-review--hunk-risk b))))))
         (risk (if top (decisions-review--hunk-risk top) 0.0))
         (calls (apply #'+ (mapcar (lambda (h) (length (decisions-review--hunk-jobs h))) units)))
         (unasked (seq-count #'decisions-review--unasked-p units))
         (open (gethash file decisions-review--expanded)))
    (insert (propertize (decisions-review--bar risk) 'face (decisions-review--face risk))
            (format " %.2f  " risk)
            (propertize (concat (if open "▾ " "▸ ") file) 'face 'link)
            (propertize (format "  %d unit%s · %d call%s%s%s"
                                (length units) (if (= (length units) 1) "" "s")
                                calls (if (= calls 1) "" "s")
                                (if (> unasked 0) (format " · %d unasked" unasked) "")
                                (if (and top (> risk 0))
                                    (format " · %s" (decisions-review--hunk-reason top)) ""))
                        'face 'shadow)
            "\n")
    (put-text-property start (point) 'decisions-review-row file)
    (put-text-property start (point) 'decisions-review-file file)))

(defun decisions-review--insert-files (hunks)
  "Insert HUNKS grouped under one expandable row per file, riskiest file first."
  (let ((files (make-hash-table :test #'equal)) order)
    (dolist (hunk hunks)
      (let ((file (plist-get (decisions-review--hunk-data hunk) :file)))
        (unless (gethash file files) (push file order))
        (puthash file (append (gethash file files) (list hunk)) files)))
    (cl-flet ((top (file) (apply #'max -1 (mapcar (lambda (h) (or (decisions-review--hunk-risk h) -1))
                                                  (gethash file files)))))
      (dolist (file (sort (nreverse order) (lambda (a b) (> (top a) (top b)))))
        (decisions-review--file-row file (seq-filter (lambda (h) (equal (plist-get (decisions-review--hunk-data h) :file) file))
                                                decisions-review--hunks))
        (when (gethash file decisions-review--expanded)
          (dolist (hunk (sort (copy-sequence (gethash file files))
                              (lambda (a b) (> (or (decisions-review--hunk-risk a) -1)
                                               (or (decisions-review--hunk-risk b) -1)))))
            (decisions-review--insert-hunk hunk t)))))))

(defun decisions-review-show-request ()
  "Show the exact state and questions each model call sends for the unit at point."
  (interactive)
  (let* ((hunk (decisions-review--hunk-at-point))
         (data (decisions-review--hunk-data hunk))
         (requests (or (mapcar (lambda (job) (list (plist-get job :kind) (plist-get job :state)
                                                   (plist-get job :questions)))
                               (decisions-review--hunk-jobs hunk))
                       (decisions-review-requests data decisions-review--rubric))))
    (with-current-buffer (get-buffer-create "*Decisions request*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "%s:%d  %s\n%d rows · %d call%s\n\n"
                        (plist-get data :file) (plist-get data :line) (or (plist-get data :header) "")
                        (length (plist-get data :rows)) (length requests) (if (= (length requests) 1) "" "s")))
        (if (null requests)
            (insert "No rubric question applies to this unit, so nothing is sent.\n")
          (pcase-dolist (`(,kind ,state ,questions) requests)
            (insert (format "── %s call ──\n" kind))
            (let ((start (point)))
              (insert (json-serialize (decisions--object "state" state "questions" questions)))
              (json-pretty-print start (point)))
            (insert "\n\n"))))
      (goto-char (point-min))
      (special-mode)
      (display-buffer (current-buffer)))))

(defun decisions-review--insert-hunk (hunk &optional nested)
  "Insert one row, plus details when HUNK is expanded.
NESTED rows sit under their file's row and are labelled by line only."
  (let ((start (point))
        (risk (decisions-review--hunk-risk hunk)))
    (pcase (decisions-review--hunk-status hunk)
      ('scored
       (insert (propertize (decisions-review--bar risk) 'face (decisions-review--face risk))
               (format " %.2f  " risk)))
      ('failed (insert (propertize "  failed         " 'face 'error)))
      ('queued (insert (propertize "  scoring…       " 'face 'shadow)))
      (_ (insert (propertize "  waiting        " 'face 'shadow))))
    (insert (propertize (if nested
                            (truncate-string-to-width
                             (format "    :%d" (plist-get (decisions-review--hunk-data hunk) :line)) 44 nil ?\s)
                          (truncate-string-to-width (decisions-review--label hunk) 44 nil ?\s "…"))
                        'face 'link)
            "  "
            (pcase (decisions-review--hunk-status hunk)
              ('scored (concat (decisions-review--hunk-reason hunk)
                               (let ((unit (plist-get (decisions-review--hunk-data hunk) :header)))
                                 (if (and unit (not (string-empty-p unit)))
                                     (propertize (concat "  · " unit) 'face 'shadow)
                                   ""))))
              ('failed (propertize (or (decisions-review--hunk-error hunk) "") 'face 'error))
              (_ (propertize (or (plist-get (decisions-review--hunk-data hunk) :header) "") 'face 'shadow)))
            "\n")
    (when (gethash (decisions-review--hunk-index hunk) decisions-review--expanded)
      (decisions-review--insert-jobs hunk)
      (dolist (line (split-string (plist-get (decisions-review--hunk-data hunk) :text) "\n"))
        (insert "      "
                (propertize line 'face (cond ((string-prefix-p "@@" line) 'diff-hunk-header)
                                             ((string-prefix-p "+" line) 'diff-added)
                                             ((string-prefix-p "-" line) 'diff-removed)
                                             (t 'diff-context)))
                "\n"))
      (insert "\n"))
    (put-text-property start (point) 'decisions-review-hunk hunk)
    (put-text-property start (point) 'decisions-review-row hunk)))

(defun decisions-review--render ()
  "Redraw the review buffer, keeping point on the same hunk."
  (let* ((inhibit-read-only t)
         (current (get-text-property (point) 'decisions-review-row))
         (window (get-buffer-window (current-buffer)))
         (start (and window (window-start window)))
         (hunks (append decisions-review--hunks nil))
         (scored (seq-filter (lambda (h) (eq (decisions-review--hunk-status h) 'scored)) hunks))
         (failed (seq-count (lambda (h) (eq (decisions-review--hunk-status h) 'failed)) hunks))
         (levels (mapcar (lambda (h) (decisions-review--level (decisions-review--hunk-risk h))) scored))
         (done (+ (length scored) failed))
         (backend (gethash "backend" decisions-review--rubric "mlx")))
    (erase-buffer)
    (insert (propertize "Decisions review" 'face '(:inherit bold :height 1.3))
            "  " (plist-get decisions-review--source :label)
            "  " (propertize (abbreviate-file-name (plist-get decisions-review--source :root)) 'face 'shadow) "\n")
    (insert (propertize (format "%s · %s · rubric %s\n" backend
                                (gethash "model" decisions-review--rubric
                                         (pcase backend
                                           ("jev" decisions-jev-model)
                                           ("laya" decisions-laya-model)
                                           (_ decisions-mlx-model)))
                                (file-name-nondirectory decisions-review-rubric-file))
                        'face 'shadow))
    (insert (format "%d hunks · %d scored · " (length hunks) done)
            (propertize (format "%d high" (seq-count (lambda (l) (eq l 'high)) levels)) 'face 'error) " · "
            (propertize (format "%d medium" (seq-count (lambda (l) (eq l 'medium)) levels)) 'face 'warning) " · "
            (propertize (format "%d low" (seq-count (lambda (l) (eq l 'low)) levels)) 'face 'success)
            (if (> failed 0) (propertize (format " · %d failed" failed) 'face 'error) "")
            (if (< done (length hunks)) ""
              (propertize (format "   done in %.1fs" (float-time (time-since decisions-review--started)))
                          'face 'shadow))
            "\n\n")
    (when-let* ((image (condition-case err (decisions-review--chart scored)
                         (error (insert (propertize (format "chart unavailable: %s\n"
                                                            (error-message-string err))
                                                    'face 'shadow))
                                nil))))
      (insert-image image "[chart]")
      (insert "\n\n"))
    (if (null hunks)
        (insert (propertize "No changes to review.\n" 'face 'shadow))
      (let* ((ordered (decisions-review--ordered))
             (unasked (seq-count #'decisions-review--unasked-p ordered))
             (ordered (if decisions-review--show-unasked ordered (seq-remove #'decisions-review--unasked-p ordered)))
             (shown (if decisions-review--focus (seq-filter #'decisions-review--matters-p ordered) ordered)))
        (if (eq decisions-review--sort 'file)
            (decisions-review--insert-files shown)
          (mapc #'decisions-review--insert-hunk shown))
        (when (> unasked 0)
          (insert (propertize (format "\n%d units had nothing to ask: tests, docs, or no matching pattern · a %s them\n"
                                      unasked (if decisions-review--show-unasked "hides" "lists"))
                              'face 'shadow)))
        (when decisions-review--focus
          (insert (propertize (format "\n%d hunks below %.2f hidden · f shows all\n"
                                      (- (length ordered) (length shown)) decisions-review-focus-threshold)
                              'face 'shadow)))))
    (goto-char (point-min))
    (when current
      (when-let* ((match (text-property-search-forward 'decisions-review-row current #'equal)))
        (goto-char (prop-match-beginning match))))
    (unless current (decisions-review-next-hunk))
    (when start (set-window-start window (min start (point-max)) t))
    (decisions-review--update-focused-diff (current-buffer))))

(defun decisions-review--matters-p (hunk)
  "Return non-nil unless HUNK scored below `decisions-review-focus-threshold'.
Unscored and failed hunks stay visible, since nothing vouches for them."
  (not (and (eq (decisions-review--hunk-status hunk) 'scored)
            (< (decisions-review--hunk-risk hunk) decisions-review-focus-threshold))))

(defun decisions-review--focused-diff-buffer (review)
  "Return the live focused diff buffer following REVIEW, or nil."
  (seq-find (lambda (buffer)
              (eq (buffer-local-value 'decisions-review--review-buffer buffer) review))
            (buffer-list)))

(defun decisions-review--update-focused-diff (review)
  "Rewrite REVIEW's focused diff, if one is open, from the current scores."
  (when-let* ((buffer (decisions-review--focused-diff-buffer review)))
    (let* ((hunks (with-current-buffer review (decisions-review--ordered)))
           (scored (seq-filter (lambda (h) (eq (decisions-review--hunk-status h) 'scored)) hunks))
           (kept (seq-filter (lambda (h) (and (eq (decisions-review--hunk-status h) 'scored)
                                              (>= (decisions-review--hunk-risk h) decisions-review-focus-threshold)))
                             hunks)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t) (line (line-number-at-pos)))
          (erase-buffer)
          ;; diff-mode ignores text before the first file header.
          (insert (format "Decisions focused diff: %d of %d hunks at risk >= %.2f, riskiest first\n"
                          (length kept) (length hunks) decisions-review-focus-threshold)
                  (format "%d hidden as low risk%s\n\n" (- (length scored) (length kept))
                          (if (< (length scored) (length hunks))
                              (format ", %d still scoring" (- (length hunks) (length scored))) "")))
          (dolist (hunk kept)
            (let ((data (decisions-review--hunk-data hunk)))
              (insert (format "--- a/%s\n+++ b/%s\n" (plist-get data :file)
                              (if (plist-get data :deleted) "/dev/null" (plist-get data :file)))
                      ;; diff-mode allows any text after the @@ line.
                      (let ((lines (split-string (plist-get data :text) "\n")))
                        (string-join (cons (format "%s  [risk %.2f · %s]" (car lines)
                                                   (decisions-review--hunk-risk hunk)
                                                   (decisions-review--hunk-reason hunk))
                                           (cdr lines))
                                     "\n"))
                      "\n")))
          (goto-char (point-min))
          (forward-line (1- line)))))))

;;;###autoload
(defun decisions-review-focused-diff ()
  "Show only the hunks Decisions rates at or above `decisions-review-focus-threshold'.
The buffer is an ordinary `diff-mode' buffer that follows the review, so it
fills in while scoring continues."
  (interactive)
  (let* ((review (or (and (derived-mode-p 'decisions-review-mode) (current-buffer))
                     (get-buffer "*Decisions review*")
                     (user-error "Run M-x decisions-review first")))
         (buffer (or (decisions-review--focused-diff-buffer review)
                     (get-buffer-create "*Decisions focused diff*"))))
    (with-current-buffer buffer
      (diff-mode)
      (setq default-directory (buffer-local-value 'default-directory review)
            decisions-review--review-buffer review
            buffer-read-only t)
      (setq-local header-line-format
                  (format " Hunks Decisions rates >= %.2f · RET source · n/p hunks · q quit"
                          decisions-review-focus-threshold)))
    (decisions-review--update-focused-diff review)
    (pop-to-buffer buffer)))

(defun decisions-review-toggle-unasked ()
  "List or fold the units no rubric question applied to."
  (interactive)
  (setq decisions-review--show-unasked (not decisions-review--show-unasked))
  (decisions-review--render))

(defun decisions-review-toggle-focus ()
  "Hide or show hunks below `decisions-review-focus-threshold'."
  (interactive)
  (setq decisions-review--focus (not decisions-review--focus))
  (decisions-review--render))

(defun decisions-review--start (source)
  "Open a review buffer for SOURCE and start scoring."
  (let* ((rubric (decisions-review-load-rubric))
         (diff (or (plist-get source :diff)
                   (decisions-review--diff (plist-get source :root) (plist-get source :arguments)
                                      (plist-get source :untracked))))
         (parsed (let ((decisions-review-chunk-lines (decisions-review--setting rubric "chunk_lines" decisions-review-chunk-lines)))
                   (decisions-review-split-hunks (decisions-review-parse-diff diff)
                                            (decisions-review--file-text-function source))))
         (buffer (get-buffer-create "*Decisions review*")))
    (when (> (length parsed) decisions-review-max-hunks)
      (message "Decisions review: scoring the first %d of %d hunks" decisions-review-max-hunks (length parsed))
      (setq parsed (seq-take parsed decisions-review-max-hunks)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'decisions-review-mode) (decisions-review-mode))
      (decisions-review--cancel-all)
      (setq default-directory (plist-get source :root)
            decisions-review--source source
            decisions-review--rubric rubric
            decisions-review--next 0
            decisions-review--inflight 0
            decisions-review--started (current-time)
            decisions-review--expanded (make-hash-table :test #'equal)
            decisions-review--hunks
            (vconcat (cl-loop for data in parsed for index from 0
                              collect (decisions-review--make-hunk :index index :data data :status 'waiting))))
      (decisions-review--render))
    (pop-to-buffer buffer)
    (decisions-review--pump buffer)
    buffer))

;;;###autoload
(defun decisions-review (&optional choose)
  "Score each hunk of a diff with Decisions.
In a magit diff or `diff-mode' buffer, review what that buffer shows;
otherwise review uncommitted changes against HEAD.  With CHOOSE (a prefix
argument), pick the changes: uncommitted, staged, this branch, or a range."
  (interactive "P")
  (decisions-review--start
   (or (and (not choose) (decisions-review--buffer-source))
       (decisions-review--source
        (if (not choose) 'worktree
          (cdr (assoc (completing-read "Review: " '("uncommitted vs HEAD" "staged" "this branch vs main" "revision range") nil t)
                      '(("uncommitted vs HEAD" . worktree) ("staged" . staged)
                        ("this branch vs main" . branch) ("revision range" . range)))))))))

;;;###autoload
(defun decisions-review-branch ()
  "Score the hunks this branch changed since it left the main branch."
  (interactive)
  (decisions-review--start (decisions-review--source 'branch)))

(defun decisions-review-refresh ()
  "Re-read the diff and rubric, then score everything again."
  (interactive)
  (decisions-review--start decisions-review--source))

(defun decisions-review-cancel ()
  "Stop scoring the remaining hunks."
  (interactive)
  (decisions-review--cancel-all)
  (setq decisions-review--next (length decisions-review--hunks))
  (decisions-review--render))

(defun decisions-review--hunk-at-point ()
  "Return the hunk on the current line or signal."
  (or (get-text-property (point) 'decisions-review-hunk) (user-error "No hunk here")))

(defun decisions-review-toggle ()
  "Show or hide the unit at point's calls and diff, or a file row's units."
  (interactive)
  (let ((index (or (get-text-property (point) 'decisions-review-file)
                   (decisions-review--hunk-index (decisions-review--hunk-at-point)))))
    (if (gethash index decisions-review--expanded)
        (remhash index decisions-review--expanded)
      (puthash index t decisions-review--expanded))
    (decisions-review--render)))

(defun decisions-review-visit ()
  "Open the changed line of the hunk at point in another window."
  (interactive)
  (let ((data (if-let* ((file (get-text-property (point) 'decisions-review-file)))
                   (decisions-review--hunk-data
                    (seq-find (lambda (h) (equal (plist-get (decisions-review--hunk-data h) :file) file))
                              decisions-review--hunks))
                 (decisions-review--hunk-data (decisions-review--hunk-at-point)))))
    (when (plist-get data :deleted) (user-error "%s was deleted" (plist-get data :file)))
    (find-file-other-window (expand-file-name (plist-get data :file)
                                              (plist-get decisions-review--source :root)))
    (goto-char (point-min))
    (forward-line (1- (plist-get data :line)))))

(defun decisions-review-next-hunk (&optional count)
  "Move to the start of the next row, a unit or a file; COUNT negative moves back."
  (interactive "p")
  (let ((count (or count 1)))
    (dotimes (_ (abs count))
      (let ((here (get-text-property (point) 'decisions-review-row))
            (step (if (> count 0) #'next-single-property-change #'previous-single-property-change)))
        (let ((position (point)))
          (while (and (setq position (funcall step position 'decisions-review-row))
                      (or (null (get-text-property position 'decisions-review-row))
                          (equal (get-text-property position 'decisions-review-row) here))))
          (when position
            (goto-char position)
            (when (< count 0)
              (goto-char (or (previous-single-property-change (1+ (point)) 'decisions-review-row)
                             (point))))))))))

(defun decisions-review-previous-hunk (&optional count)
  "Move to the previous hunk row, COUNT times."
  (interactive "p")
  (decisions-review-next-hunk (- (or count 1))))

(defun decisions-review-toggle-sort ()
  "Cycle the view: riskiest first, grouped by file, or diff order."
  (interactive)
  (setq decisions-review--sort (pcase decisions-review--sort ('risk 'file) ('file 'diff) (_ 'risk)))
  (message "Decisions review: sorted by %s" decisions-review--sort)
  (decisions-review--render))

(defun decisions-review-edit-rubric ()
  "Open the rubric; after saving, press g in the review to apply it."
  (interactive)
  (find-file-other-window decisions-review-rubric-file))

(defvar decisions-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'decisions-review-visit)
    (define-key map (kbd "TAB") #'decisions-review-toggle)
    (define-key map (kbd "n") #'decisions-review-next-hunk)
    (define-key map (kbd "p") #'decisions-review-previous-hunk)
    (define-key map (kbd "g") #'decisions-review-refresh)
    (define-key map (kbd "s") #'decisions-review-toggle-sort)
    (define-key map (kbd "e") #'decisions-review-edit-rubric)
    (define-key map (kbd "f") #'decisions-review-toggle-focus)
    (define-key map (kbd "a") #'decisions-review-toggle-unasked)
    (define-key map (kbd "v") #'decisions-review-show-request)
    (define-key map (kbd "d") #'decisions-review-focused-diff)
    (define-key map (kbd "C-c C-k") #'decisions-review-cancel)
    map))

(define-derived-mode decisions-review-mode special-mode "Decisions-Review"
  "Hunks of a diff, scored by Decisions against a JSON rubric.
\\{decisions-review-mode-map}"
  (setq-local truncate-lines t
              revert-buffer-function (lambda (&rest _) (decisions-review-refresh))
              header-line-format
              " RET visit  TAB expand  ]] [[ rows  s risk/file/diff  v request  f focus  a unasked  d focused diff  gr rescore  e rubric  C-c C-k stop  q quit")
  (add-hook 'kill-buffer-hook #'decisions-review--cancel-all nil t))

(with-eval-after-load 'evil
  (evil-define-key* '(normal motion) decisions-review-mode-map
    (kbd "RET") #'decisions-review-visit
    (kbd "TAB") #'decisions-review-toggle
    "]]" #'decisions-review-next-hunk
    "[[" #'decisions-review-previous-hunk
    "gr" #'decisions-review-refresh
    "s" #'decisions-review-toggle-sort
    "e" #'decisions-review-edit-rubric
    "f" #'decisions-review-toggle-focus
    "a" #'decisions-review-toggle-unasked
    "v" #'decisions-review-show-request
    "d" #'decisions-review-focused-diff
    "q" #'quit-window))

(provide 'decisions-review)
;;; decisions-review.el ends here
