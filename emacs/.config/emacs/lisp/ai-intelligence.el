;;; ai-intelligence.el --- Read-only editor intelligence for AI tools -*- lexical-binding: t -*-

;; This module deliberately contains no general command or evaluation entry
;; point.  It is intended to be called by the fixed Emacs MCP dispatcher, with
;; the dispatcher remaining responsible for choosing and authorizing buffers.

(require 'cl-lib)
(require 'project)
(require 'subr-x)
(require 'xref)
(require 'eww)

(defvar emacs-mcp--request-root)

(defgroup emacs-ai-intelligence nil
  "Read-only editor information suitable for AI clients."
  :group 'tools)

(defcustom emacs-ai-intelligence-max-context-characters 12000
  "Largest text payload returned by a context request."
  :type 'integer
  :group 'emacs-ai-intelligence)

(defcustom emacs-ai-intelligence-max-project-files 250
  "Largest project file list returned by `emacs-ai-intelligence-project-outline'."
  :type 'integer
  :group 'emacs-ai-intelligence)

(defcustom emacs-ai-intelligence-max-xref-results 100
  "Largest definition or reference list returned by an xref request."
  :type 'integer
  :group 'emacs-ai-intelligence)

(defcustom emacs-ai-intelligence-max-browser-links 100
  "Largest EWW link list returned by `emacs-ai-intelligence-eww-context'."
  :type 'integer
  :group 'emacs-ai-intelligence)

(defun emacs-ai-intelligence--argument (arguments name &optional default)
  "Return NAME from JSON object ARGUMENTS, or DEFAULT.
ARGUMENTS is normally the hash table produced by `json-parse-string'."
  (if (and (hash-table-p arguments) (gethash name arguments))
      (gethash name arguments)
    default))

(defun emacs-ai-intelligence--positive-integer (value fallback)
  "Return VALUE when it is a positive integer, otherwise FALLBACK."
  (if (and (integerp value) (> value 0)) value fallback))

(defun emacs-ai-intelligence--json-null (value)
  "Return VALUE, or the JSON null sentinel when it is nil."
  (or value :null))

(defun emacs-ai-intelligence--json-bool (value)
  "Return VALUE in the representation expected by `json-serialize'."
  (if value t :false))

(defun emacs-ai-intelligence--limit-string (string limit)
  "Return STRING clipped to LIMIT characters, plus whether it was clipped."
  (let ((text (or string "")))
    (if (> (length text) limit)
        (cons (substring text 0 limit) t)
      (cons text nil))))

(defun emacs-ai-intelligence--workspace-root (buffer)
  "Return a canonical workspace root appropriate for BUFFER."
  (with-current-buffer buffer
    (file-name-as-directory
     (file-truename
      (or (bound-and-true-p emacs-mcp--request-root)
          (and (fboundp 'workspace-root) (workspace-root))
          (when-let* ((project (project-current nil default-directory)))
            (project-root project))
          default-directory)))))

(defun emacs-ai-intelligence--position-from-arguments (arguments)
  "Move point to the optional line and column in ARGUMENTS.
Line numbers are one-based and columns are zero-based.  Return point."
  (let ((line (emacs-ai-intelligence--argument arguments "line"))
        (column (emacs-ai-intelligence--argument arguments "column" 0)))
    (when line
      (unless (and (integerp line) (> line 0))
        (user-error "line must be a positive integer"))
      (unless (and (integerp column) (>= column 0))
        (user-error "column must be a non-negative integer"))
      (goto-char (point-min))
      (forward-line (1- line))
      (move-to-column column))
    (point)))

(defun emacs-ai-intelligence--point-data ()
  "Return the current point as an MCP-safe alist."
  `((line . ,(line-number-at-pos))
    (column . ,(current-column))
    (position . ,(point))))

(defun emacs-ai-intelligence--buffer-data (buffer)
  "Return stable metadata for BUFFER."
  (with-current-buffer buffer
    `((buffer . ,(buffer-name))
      (file . ,(emacs-ai-intelligence--json-null buffer-file-name))
      (mode . ,(symbol-name major-mode)))))

(defun emacs-ai-intelligence--region-data (begin end limit)
  "Return the text and endpoints between BEGIN and END, capped at LIMIT."
  (let* ((text (buffer-substring-no-properties begin end))
         (limited (emacs-ai-intelligence--limit-string text limit)))
    `((start . ,(save-excursion
                  (goto-char begin)
                  (emacs-ai-intelligence--point-data)))
      (end . ,(save-excursion
                (goto-char end)
                (emacs-ai-intelligence--point-data)))
      (text . ,(car limited))
      (truncated . ,(emacs-ai-intelligence--json-bool (cdr limited))))))

(defun emacs-ai-intelligence-selection-context (buffer &optional arguments)
  "Return BUFFER's active selection or the symbol and point near it.
Optional ARGUMENTS can contain one-based `line' and zero-based `column' to
inspect a precise point.  This function never modifies BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (widen)
        (emacs-ai-intelligence--position-from-arguments arguments)
        (let ((limit (emacs-ai-intelligence--positive-integer
                      (emacs-ai-intelligence--argument arguments "max_characters")
                      emacs-ai-intelligence-max-context-characters)))
          (append (emacs-ai-intelligence--buffer-data buffer)
                  `((point . ,(emacs-ai-intelligence--point-data))
                    (symbol . ,(emacs-ai-intelligence--json-null
                                (thing-at-point 'symbol t)))
                    (selection . ,(emacs-ai-intelligence--json-null
                                    (when mark-active
                                      (emacs-ai-intelligence--region-data
                                       (region-beginning) (region-end) limit)))))))))))

(defun emacs-ai-intelligence-range-context (buffer arguments)
  "Return an explicit, bounded line range from BUFFER.
ARGUMENTS requires `start_line' and accepts `start_column', `end_line',
`end_column', and `max_characters'.  End coordinates are exclusive; an end
line without an end column means the end of that line."
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (widen)
        (let* ((start-line (emacs-ai-intelligence--argument arguments "start_line"))
               (end-line (or (emacs-ai-intelligence--argument arguments "end_line")
                             start-line))
               (start-column (or (emacs-ai-intelligence--argument arguments "start_column") 0))
               (end-column (emacs-ai-intelligence--argument arguments "end_column"))
               (limit (emacs-ai-intelligence--positive-integer
                       (emacs-ai-intelligence--argument arguments "max_characters")
                       emacs-ai-intelligence-max-context-characters)))
          (unless (and (integerp start-line) (> start-line 0)
                       (integerp end-line) (>= end-line start-line)
                       (integerp start-column) (>= start-column 0)
                       (or (null end-column) (and (integerp end-column) (>= end-column 0))))
            (user-error "Invalid range coordinates"))
          (goto-char (point-min))
          (forward-line (1- start-line))
          (move-to-column start-column)
          (let ((begin (point)))
            (goto-char (point-min))
            (forward-line (1- end-line))
            (if end-column
                (move-to-column end-column)
              (end-of-line))
            (when (< (point) begin)
              (user-error "Range end precedes range start"))
            (append (emacs-ai-intelligence--buffer-data buffer)
                    `((range . ,(emacs-ai-intelligence--region-data begin (point) limit))))))))))

(defun emacs-ai-intelligence--project-files (root limit)
  "Return up to LIMIT project-relative files rooted at ROOT.
The complete result is intentionally not counted: asking project.el for a
project's file set may itself be expensive, so callers receive an honest
`truncated' flag only when more entries are present in that result."
  (let* ((default-directory root)
         (project (project-current nil root))
         (files (and project (project-files project)))
         (sorted (sort (copy-sequence files) #'string-lessp))
         (truncated (> (length sorted) limit)))
    `((project_detected . ,(emacs-ai-intelligence--json-bool project))
      (files . ,(vconcat
                 (mapcar (lambda (file) (file-relative-name file root))
                         (cl-subseq sorted 0 (min limit (length sorted))))))
      (truncated . ,(emacs-ai-intelligence--json-bool truncated)))))

(defun emacs-ai-intelligence-project-outline (buffer &optional arguments)
  "Return a bounded project outline for BUFFER's workspace.
ARGUMENTS can contain `max_files'.  This uses project.el and never writes to
the project."
  (let* ((root (emacs-ai-intelligence--workspace-root buffer))
         (limit (emacs-ai-intelligence--positive-integer
                 (emacs-ai-intelligence--argument arguments "max_files")
                 emacs-ai-intelligence-max-project-files)))
    (append `((root . ,root)) (emacs-ai-intelligence--project-files root limit))))

(defun emacs-ai-intelligence--git-status-entry (field original)
  "Turn porcelain FIELD and optional rename ORIGINAL into an alist."
  (let ((index-status (substring field 0 1))
        (worktree-status (substring field 1 2))
        (path (substring field 3)))
    `((path . ,path)
      (index_status . ,index-status)
      (worktree_status . ,worktree-status)
      (original_path . ,(emacs-ai-intelligence--json-null original)))))

(defun emacs-ai-intelligence-git-status (buffer &optional arguments)
  "Return bounded, read-only Git porcelain status for BUFFER's workspace.
ARGUMENTS can contain `max_entries'.  The only subprocess used by this
module is the fixed command `git -C ROOT status --porcelain=v1 --branch -z'."
  (let* ((root (emacs-ai-intelligence--workspace-root buffer))
         (limit (emacs-ai-intelligence--positive-integer
                 (emacs-ai-intelligence--argument arguments "max_entries") 200)))
    (unless (executable-find "git")
      (user-error "Git is not available"))
    (with-temp-buffer
      (let ((status (process-file "git" nil t nil "-C" root "status"
                                  "--porcelain=v1" "--branch" "-z")))
        (unless (and (integerp status) (zerop status))
          (user-error "Could not read Git status for %s" root))
        (let ((fields (split-string (buffer-string) (string 0) t))
              branch entries)
          (when (and fields (string-prefix-p "## " (car fields)))
            (setq branch (substring (pop fields) 3)))
          (while (and fields (< (length entries) limit))
            (let ((field (pop fields)))
              (unless (>= (length field) 3)
                (user-error "Unexpected Git porcelain record"))
              (let* ((code (substring field 0 2))
                     (renamed-or-copied (or (string-match-p "R" code)
                                            (string-match-p "C" code)))
                     ;; With -z, Git places the old pathname in the next
                     ;; record for rename/copy entries.
                     (original (and renamed-or-copied (pop fields))))
                (push (emacs-ai-intelligence--git-status-entry field original) entries))))
          `((root . ,root)
            (branch . ,(emacs-ai-intelligence--json-null branch))
            (entries . ,(vconcat (nreverse entries)))
            (truncated . ,(emacs-ai-intelligence--json-bool fields))))))))

(defun emacs-ai-intelligence--location-in-workspace-p (location root)
  "Whether xref LOCATION is either non-file based or contained by ROOT."
  (or (not (xref-file-location-p location))
      (file-in-directory-p (file-truename (xref-file-location-file location)) root)))

(defun emacs-ai-intelligence--xref-location-data (location)
  "Serialize xref LOCATION without visiting any file."
  (let ((group (condition-case nil (xref-location-group location) (error nil)))
        (line (condition-case nil (xref-location-line location) (error nil))))
    (append `((group . ,(emacs-ai-intelligence--json-null group))
              (line . ,(emacs-ai-intelligence--json-null line)))
            (cond
             ((xref-file-location-p location)
              `((file . ,(xref-file-location-file location))
                (column . ,(xref-file-location-column location))))
             ((xref-buffer-location-p location)
              (let ((buffer (xref-buffer-location-buffer location)))
                `((buffer . ,(buffer-name buffer))
                  (file . ,(emacs-ai-intelligence--json-null
                             (buffer-file-name buffer)))
                  (position . ,(xref-buffer-location-position location)))))
             (t nil)))))

(defun emacs-ai-intelligence--xref-results (buffer arguments kind)
  "Return xref KIND (`definitions' or `references') from BUFFER.
This does not jump to or visit result locations."
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (widen)
        (emacs-ai-intelligence--position-from-arguments arguments)
        (let* ((backend (xref-find-backend))
               (identifier (and backend
                                (xref-backend-identifier-at-point backend)))
               (root (emacs-ai-intelligence--workspace-root buffer))
               (limit (emacs-ai-intelligence--positive-integer
                       (emacs-ai-intelligence--argument arguments "max_results")
                       emacs-ai-intelligence-max-xref-results)))
          (unless backend (user-error "No xref backend is available"))
          (unless identifier (user-error "No identifier at point"))
          (let* ((items (pcase kind
                          ('definitions (xref-backend-definitions backend identifier))
                          ('references (xref-backend-references backend identifier))))
                 (inside (cl-remove-if-not
                          (lambda (item)
                            (emacs-ai-intelligence--location-in-workspace-p
                             (xref-item-location item) root))
                          items))
                 (outside (- (length items) (length inside)))
                 (truncated (> (length inside) limit)))
            `((identifier . ,(substring-no-properties identifier))
              (root . ,root)
              (results . ,(vconcat
                           (mapcar (lambda (item)
                                     `((summary . ,(substring-no-properties
                                                    (xref-item-summary item)))
                                       (location . ,(emacs-ai-intelligence--xref-location-data
                                                     (xref-item-location item)))))
                                   (cl-subseq inside 0 (min limit (length inside))))))
              (truncated . ,(emacs-ai-intelligence--json-bool truncated))
              (omitted_outside_workspace . ,outside))))))))

(defun emacs-ai-intelligence-xref-definitions (buffer &optional arguments)
  "Return definitions of the identifier at BUFFER's point."
  (emacs-ai-intelligence--xref-results buffer arguments 'definitions))

(defun emacs-ai-intelligence-xref-references (buffer &optional arguments)
  "Return references to the identifier at BUFFER's point."
  (emacs-ai-intelligence--xref-results buffer arguments 'references))

(defun emacs-ai-intelligence--symbol-documentation (symbol)
  "Return a built-in documentation string for SYMBOL, if available."
  (or (and (fboundp symbol) (documentation symbol t))
      (let ((variable-doc (get symbol 'variable-documentation)))
        (cond ((stringp variable-doc) variable-doc)
              ((and (symbolp variable-doc) (fboundp variable-doc))
               (documentation variable-doc t))))))

(defun emacs-ai-intelligence--eldoc-now ()
  "Return immediate ElDoc output at point without waiting for async results."
  (when (boundp 'eldoc-documentation-functions)
    (catch 'documentation
      (run-hook-wrapped
       'eldoc-documentation-functions
       (lambda (function)
         (let ((result (condition-case nil
                           (funcall function
                                    (lambda (documentation &rest _properties)
                                      (throw 'documentation documentation)))
                         (error nil))))
           (when (stringp result)
             (throw 'documentation result))
           nil))))))

(defun emacs-ai-intelligence-documentation-at-point (buffer &optional arguments)
  "Return immediate documentation at point in BUFFER when Emacs knows it.
For language servers this returns synchronous ElDoc output only; it never
waits for, or writes, an asynchronous response."
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (widen)
        (emacs-ai-intelligence--position-from-arguments arguments)
        (let* ((name (thing-at-point 'symbol t))
               (symbol (and name (intern-soft name)))
               (builtin (and symbol (emacs-ai-intelligence--symbol-documentation symbol)))
               (eldoc (and (not builtin) (emacs-ai-intelligence--eldoc-now)))
               (documentation (or builtin eldoc))
               (limited (emacs-ai-intelligence--limit-string
                         documentation emacs-ai-intelligence-max-context-characters)))
          (append (emacs-ai-intelligence--buffer-data buffer)
                  `((symbol . ,(emacs-ai-intelligence--json-null name))
                    (documentation . ,(emacs-ai-intelligence--json-null (car limited)))
                    (source . ,(emacs-ai-intelligence--json-null
                                 (cond (builtin "emacs") (eldoc "eldoc"))))
                    (truncated . ,(emacs-ai-intelligence--json-bool (cdr limited))))))))))

(defun emacs-ai-intelligence--eww-links (limit)
  "Return up to LIMIT unique links and an accurate truncation flag.
The return value is a cons whose car is the links and cdr says whether one or
more additional unique links were present."
  (let ((position (point-min)) links
        (seen (make-hash-table :test #'equal)))
    ;; Read one extra link so `links_truncated' remains truthful without
    ;; collecting an unbounded page-wide list.
    (while (and (< position (point-max)) (<= (length links) limit))
      (let* ((url (get-text-property position 'shr-url))
             (next (next-single-property-change position 'shr-url nil (point-max))))
        (when (and (stringp url) (not (gethash url seen)))
          (puthash url t seen)
          (let ((label (string-trim
                        (replace-regexp-in-string
                         "[[:space:]\\n]+" " "
                         (buffer-substring-no-properties position next)))))
            (push `((text . ,label) (url . ,url)) links)))
        (setq position (if (= position next) (1+ position) next))))
    (setq links (nreverse links))
    (cons (cl-subseq links 0 (min limit (length links))) (> (length links) limit))))

(defun emacs-ai-intelligence-eww-context (buffer &optional arguments)
  "Return readable text and links from EWW BUFFER.
ARGUMENTS can contain `max_characters' and `max_links'.  Xwidget buffers are
intentionally excluded: their rendered contents are not reliably readable by
Emacs without browser automation."
  (with-current-buffer buffer
    (unless (derived-mode-p 'eww-mode)
      (user-error "Only EWW buffers expose readable browser context"))
    (let* ((text-limit (emacs-ai-intelligence--positive-integer
                        (emacs-ai-intelligence--argument arguments "max_characters")
                        emacs-ai-intelligence-max-context-characters))
           (link-limit (emacs-ai-intelligence--positive-integer
                        (emacs-ai-intelligence--argument arguments "max_links")
                        emacs-ai-intelligence-max-browser-links))
           (limited (emacs-ai-intelligence--limit-string
                     (buffer-substring-no-properties (point-min) (point-max)) text-limit))
           (link-result (emacs-ai-intelligence--eww-links link-limit))
           (links (car link-result)))
      `((buffer . ,(buffer-name))
        (url . ,(emacs-ai-intelligence--json-null (plist-get eww-data :url)) )
        (title . ,(emacs-ai-intelligence--json-null (plist-get eww-data :title)) )
        (text . ,(car limited))
        (text_truncated . ,(emacs-ai-intelligence--json-bool (cdr limited)) )
        (links . ,(vconcat links))
        (links_truncated . ,(emacs-ai-intelligence--json-bool (cdr link-result)))))))

(provide 'ai-intelligence)
;;; ai-intelligence.el ends here
