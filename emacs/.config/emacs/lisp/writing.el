;;; writing.el --- Org and Markdown  -*- lexical-binding: t -*-

(use-package org
  :ensure nil
  :commands (org-agenda org-capture)
  :custom
  (org-directory "~/org")
  ;; Every .org file in ~/org, skipping dated copies like x.backup-2026-09-23.org.
  (org-agenda-files '("~/org"))
  (org-agenda-file-regexp "\\`[^.][^.]*\\.org\\'")
  (org-agenda-window-setup 'current-window)
  ;; Tags right after the title, so they stay visible in a narrow window.
  (org-agenda-tags-column 0)
  ;; Cut the file-name column at 12 characters so long names keep lines aligned.
  (org-agenda-prefix-format
   '((agenda . " %i %-12.12:c%?-12t% s")
     (todo . " %i %-12.12:c")
     (tags . " %i %-12.12:c")
     (search . " %i %-12.12:c")))
  (org-agenda-custom-commands
   '(("h" "This week and someday, then undated TODOs"
      ;; Deadlines show on their own day; a week view needs no early warning.
      ((agenda "" ((org-agenda-span 'week)
                   (org-deadline-warning-days 0)))
       ;; Someday reads as one more day after Sunday.
       (tags-todo "someday" ((org-agenda-overriding-header (writing-agenda-day-header "Someday"))
                             (org-agenda-block-separator nil)
                             (org-agenda-hide-tags-regexp "\\`someday\\'")
                             (org-agenda-prefix-format " %i %-12.12:cSomeday:    ")))
       (alltodo "" ((org-agenda-overriding-header "TODOs without a date")
                    (org-agenda-skip-function #'writing-agenda-skip-someday)
                    (org-agenda-todo-ignore-scheduled 'all)
                    (org-agenda-todo-ignore-deadlines 'all)))))))
  ;; C-c C-t offers these by letter.  WAITING and CANCELLED ask for a short
  ;; note (who you're waiting on, why it was dropped), kept in a folded drawer.
  (org-todo-keywords
   '((sequence "TODO(t)" "WAITING(w@)" "|" "DONE(d)" "CANCELLED(c@)")))
  (org-log-into-drawer t)
  (org-default-notes-file "~/org/inbox.org")
  ;; Tasks go to todo.org; notes and meetings under this week in weekly.org.
  (org-capture-templates
   '(("t" "Task" entry (file+headline "todo.org" "Tasks") "* TODO %?\n  %U")
     ("n" "Note" item (file+function "weekly.org" writing-weekly-notes) "%?")
     ("m" "Meeting" entry (file+function "weekly.org" writing-weekly-meetings) "* %^{Meeting}\n  %U\n  - %?")))
  ;; M-RET adds the new heading after the whole entry (its dates and notes
  ;; stay put) instead of splitting the heading at point.
  (org-insert-heading-respect-content t)
  (org-M-RET-may-split-line '((default . nil)))
  (org-startup-indented t)
  (org-hide-emphasis-markers t)
  :config
  (make-directory org-directory t)
  ;; << and >> (and < / > on a visual selection) promote and demote the
  ;; headings they cover; away from headings they shift lines as usual.
  (evil-define-operator writing-org-shift-left (beg end)
    "Promote the headings in BEG..END, or shift the lines left."
    :type line
    (if (writing-org--headings-p beg end)
        (org-map-region #'org-promote beg end)
      (evil-shift-left beg end)))
  (evil-define-operator writing-org-shift-right (beg end)
    "Demote the headings in BEG..END, or shift the lines right."
    :type line
    (if (writing-org--headings-p beg end)
        (org-map-region #'org-demote beg end)
      (evil-shift-right beg end)))
  (evil-define-key '(normal visual) org-mode-map
    "<" #'writing-org-shift-left
    ">" #'writing-org-shift-right))

(defun writing-agenda-day-header (name)
  "A block header for the agenda that looks like a day named NAME."
  (lambda () (concat (propertize name 'face 'org-agenda-date) "\n")))

;; Someday is a "when", like a date, kept as a :someday: tag so it goes with
;; any state.  An entry has a schedule or the tag, never both: tagging drops
;; the schedule, and scheduling drops the tag.
(defun writing-someday-toggle ()
  "Toggle the :someday: tag on the entry at point, in an Org file or the agenda."
  (interactive)
  (if (derived-mode-p 'org-agenda-mode)
      (progn (org-agenda-with-point-at-orig-entry nil (org-toggle-tag "someday"))
             (org-agenda-redo))
    (org-toggle-tag "someday")))

(defun writing-someday-unschedule ()
  "Drop the schedule of an entry that was just tagged :someday:."
  (when (and (member "someday" (org-get-tags nil t)) (org-get-scheduled-time (point)))
    (org-remove-timestamp-with-keyword org-scheduled-string)))

(defun writing-someday-commit (what &optional time &rest _)
  "After scheduling (WHAT is `scheduled' with a TIME) an entry, drop its :someday: tag."
  (when (and (eq what 'scheduled) time (member "someday" (org-get-tags nil t)))
    (org-toggle-tag "someday" 'off)))

(defun writing-agenda-skip-someday ()
  "Agenda skip function: skip entries tagged :someday:."
  (when (member "someday" (org-get-tags))
    (or (outline-next-heading) (point-max))))

(add-hook 'org-after-tags-change-hook #'writing-someday-unschedule)
(advice-add 'org-add-planning-info :after #'writing-someday-commit)
(with-eval-after-load 'org
  (define-key org-mode-map (kbd "C-c s") #'writing-someday-toggle))
(with-eval-after-load 'org-agenda
  (define-key org-agenda-mode-map (kbd "C-c s") #'writing-someday-toggle))

;; Deadlines in orange, whatever the theme: its `warning' color.
(custom-set-faces
 '(org-imminent-deadline ((t :inherit warning)))
 '(org-upcoming-deadline ((t :inherit warning)))
 '(org-upcoming-distant-deadline ((t :inherit warning))))

;;; Calendar: a read-only copy of the next weeks of one Calendar.app calendar,
;;; written to calendar.org by icalBuddy (brew install ical-buddy), so the
;;; agenda shows meetings next to tasks.  Edit events in Calendar, not here.

(defvar writing-calendar-name "efren@measuringu.com"
  "The Calendar.app calendar copied into calendar.org.")

(defvar writing-calendar-days 28
  "How many days ahead to copy.")

(defun writing-calendar--timestamp (when)
  "WHEN as icalBuddy prints it (2026-09-28, 2026-09-28 at 10:00 - 10:30, ...) as an Org timestamp."
  (let ((d "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)")
        (tm "\\([0-9]\\{2\\}:[0-9]\\{2\\}\\)"))
    (cl-flet ((m (i) (match-string i when)))
      (cond
       ((string-match (concat "\\`" d " at " tm " - " tm "\\'") when)
        (format "<%s %s-%s>" (m 1) (m 2) (m 3)))
       ((string-match (concat "\\`" d " at " tm " - " d " at " tm "\\'") when)
        (format "<%s %s>--<%s %s>" (m 1) (m 2) (m 3) (m 4)))
       ((string-match (concat "\\`" d " at " tm "\\'") when)
        (format "<%s %s>" (m 1) (m 2)))
       ((string-match (concat "\\`" d " - " d "\\'") when)
        (format "<%s>--<%s>" (m 1) (m 2)))
       ((string-match (concat "\\`" d "\\'") when)
        (format "<%s>" (m 1)))))))

(defun writing-calendar-sync ()
  "Copy the next `writing-calendar-days' of `writing-calendar-name' into calendar.org."
  (interactive)
  (condition-case err
      (let* ((file (expand-file-name "calendar.org" org-directory))
             (lines (process-lines "icalBuddy" "-ic" writing-calendar-name "-nc" "-nrd"
                                   "-b" "@@ " "-df" "%Y-%m-%d" "-tf" "%H:%M"
                                   "-iep" "title,datetime,location" "-po" "title,datetime,location"
                                   "-ps" "| ~~ |" "eventsFrom:today"
                                   (format "to:today+%d" writing-calendar-days)))
             (text (with-temp-buffer
                     (insert "# -*- buffer-read-only: t -*-\n#+TITLE: Calendar\n#+CATEGORY: cal\n"
                             "# Copied from Calendar.app by writing-calendar-sync; edits are overwritten.\n\n")
                     (dolist (line lines)
                       (when (string-prefix-p "@@ " line)
                         (pcase-let ((`(,title ,when . ,rest) (split-string (substring line 3) " ~~ ")))
                           (when-let* ((stamp (and when (writing-calendar--timestamp when))))
                             (insert "* " title "\n" stamp "\n")
                             (dolist (r rest) (insert r "\n"))))))
                     (buffer-string))))
        (unless (and (file-exists-p file)
                     (equal text (with-temp-buffer (insert-file-contents file) (buffer-string))))
          (with-temp-file file (insert text))
          (when-let* ((buffer (find-buffer-visiting file)))
            (with-current-buffer buffer (revert-buffer t t t)))))
    (error (message "Calendar sync failed: %s" (error-message-string err)))))

(defvar writing-calendar-timer nil)
(when (timerp writing-calendar-timer) (cancel-timer writing-calendar-timer))
(when (executable-find "icalBuddy")
  (setq writing-calendar-timer (run-with-timer 0 900 #'writing-calendar-sync)))

;; ? in the agenda lists its keys (evil ones included) in a searchable picker.
(with-eval-after-load 'org-agenda
  (evil-define-key 'normal org-agenda-mode-map "?" #'embark-bindings))

(defun writing-agenda-waiting-note ()
  "The latest WAITING or C-c C-z note of the entry at point, or nil."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (outline-next-heading) (point))))
      ;; The logbook lists newest first, so the first match is the latest.
      (when (re-search-forward "^[ \t]*- \\(?:State \"WAITING\"\\|Note taken on\\).*\\\\\n[ \t]*\\(.+\\)" end t)
        (match-string-no-properties 1)))))

(defun writing-agenda-show-waiting-notes ()
  "Show each WAITING entry's latest note after its keyword in the agenda."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((marker (get-text-property (point) 'org-hd-marker)))
          (when (and marker (equal (get-text-property (point) 'todo-state) "WAITING"))
            (when-let* ((note (org-with-point-at marker (writing-agenda-waiting-note))))
              (when (re-search-forward "WAITING" (line-end-position) t)
                (insert (propertize (format " (%s)" note) 'face 'shadow))))))
        (forward-line 1)))))

(defun writing-agenda-style-someday ()
  "Gray out the Someday lines, leaving the TODO keyword its own color."
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (when (and (eq (get-text-property (point) 'org-agenda-type) 'tags)
                 (member "someday" (get-text-property (point) 'tags)))
        ;; Put the color ahead of the plain text's `default'.
        (let ((pos (point)) (eol (line-end-position)))
          (while (< pos eol)
            (let ((next (next-single-property-change pos 'face nil eol)))
              (unless (memq 'org-todo (ensure-list (get-text-property pos 'face)))
                (add-face-text-property pos next 'shadow))
              (setq pos next)))))
      (forward-line 1))))

(add-hook 'org-agenda-finalize-hook #'writing-agenda-show-waiting-notes)
(add-hook 'org-agenda-finalize-hook #'writing-agenda-style-someday)
;; Badges for tags, states and priorities in the agenda too, after the above.
(add-hook 'org-agenda-finalize-hook #'org-modern-agenda 90)

(defun writing-org--headings-p (beg end)
  "Non-nil if there is an Org heading between BEG and END."
  (save-excursion
    (goto-char beg)
    (re-search-forward org-outline-regexp-bol end t)))

;; Org shows its menus and capture buffers with `org-display-buffer-split',
;; which deletes the other windows and splits the largest one left.  With
;; herdr in the right side window that splits herdr, or finds nothing it may
;; split and opens a new frame.  Split the main (non-side) area instead.
(add-to-list 'display-buffer-alist
             '("\\`\\(?: ?\\*\\(?:Agenda Commands\\|Org \\(?:Select\\|Note\\|todo\\|tags\\)\\)\\*\\|CAPTURE-\\)"
               (display-buffer-reuse-window display-buffer-in-direction)
               (window . main) (direction . below) (window-height . 0.4)
               (body-function . writing-org-menu-tint)))

(defun writing-org-menu-tint (window)
  "Tint WINDOW's buffer if it is one of Org's menus rather than a capture."
  (with-current-buffer (window-buffer window)
    (unless (string-prefix-p "CAPTURE-" (buffer-name))
      (themes-popup-tint))))

(use-package org-modern
  :hook (org-mode . org-modern-mode))

;;; Weekly notes: weekly.org is an Org date tree by ISO week (* 2026 / ** 2026-W40),
;;; and each week has the same sections.  Tasks live in todo.org; the agenda
;;; is the list of what's open.

(defconst writing-weekly-sections '("Notes" "Meetings")
  "The headings every week in weekly.org gets, in order.")

(defun writing-weekly-section (section)
  "Move to SECTION under this week's heading, creating the week if needed."
  (org-datetree-find-create-entry '(year week) (calendar-current-date))
  (let ((week (point-marker))
        (stars (make-string (1+ (org-current-level)) ?*)))
    (dolist (s writing-weekly-sections)
      (goto-char week)
      (unless (re-search-forward (format "^%s %s[ \t]*$" stars (regexp-quote s))
                                 (save-excursion (org-end-of-subtree t t)) t)
        (org-end-of-subtree t t)
        (unless (bolp) (insert "\n"))
        (insert stars " " s "\n")))
    (goto-char week)
    (re-search-forward (format "^%s %s[ \t]*$" stars (regexp-quote section)))
    (beginning-of-line)))

(defun writing-weekly-notes () (writing-weekly-section "Notes"))
(defun writing-weekly-meetings () (writing-weekly-section "Meetings"))

(defun writing-weekly-open ()
  "Open weekly.org at this week."
  (interactive)
  (require 'org)
  (find-file (expand-file-name "weekly.org" org-directory))
  (writing-weekly-section "Notes")
  (outline-up-heading 1)
  (org-fold-show-subtree)
  (recenter 0))

(defun writing-open-org-directory ()
  "Open the Org directory in Dired."
  (interactive)
  (require 'org)
  (dired org-directory))

(defun writing-find-org-file ()
  "Find a file in the Org directory."
  (interactive)
  (require 'org)
  (consult-fd org-directory))

;; PDFs open in xwidget (WebKit's PDF viewer): smooth continuous scrolling
;; and selectable text, driven by mouse/trackpad (keys don't reach it).
;; Visiting a .pdf returns an xwidget buffer instead of a file buffer, so
;; C-x C-f, dired, SPC f r and friends all open it there.
(defun writing-pdf-in-xwidget (orig filename &optional nowarn rawfile wildcards)
  "Visit FILENAME in xwidget if it is a PDF, else call ORIG."
  (if (and (not rawfile)
           (featurep 'xwidget-internal)
           (display-graphic-p)
           (string-match-p "\\.pdf\\'" filename)
           (file-exists-p filename))
      (save-window-excursion
        (xwidget-webkit-browse-url (concat "file://" (expand-file-name filename)) t)
        (current-buffer))
    (funcall orig filename nowarn rawfile wildcards)))
(advice-add 'find-file-noselect :around #'writing-pdf-in-xwidget)

(use-package markdown-mode
  :mode ("\\.md\\'" . gfm-mode)
  :custom
  (markdown-fontify-code-blocks-natively t)
  (markdown-header-scaling t)
  (markdown-enable-wiki-links t)
  (markdown-command "pandoc -f gfm -t html5 --wrap=none")
  (markdown-css-paths '("https://cdnjs.cloudflare.com/ajax/libs/github-markdown-css/5.8.1/github-markdown-dark.min.css"))
  (markdown-xhtml-header-content "<style>body{background:#0d1117;margin:0}</style>")
  (markdown-xhtml-body-preamble "<article class=\"markdown-body\" style=\"max-width:880px;margin:0 auto;padding:32px 40px\">")
  (markdown-xhtml-body-epilogue "</article>")
  (markdown-live-preview-window-function #'writing-markdown-preview))

(defvar-local writing-markdown-preview--buffer nil)

(defun writing-markdown-preview (file)
  "Preview FILE in xwidget or EWW."
  (let ((url (concat "file://" file)))
    (if (and (buffer-live-p writing-markdown-preview--buffer) (featurep 'xwidget-internal))
        (with-current-buffer writing-markdown-preview--buffer
          (xwidget-webkit-goto-uri (xwidget-webkit-current-session) url)
          (current-buffer))
      (setq writing-markdown-preview--buffer
            (save-window-excursion
              (if (featurep 'xwidget-internal)
                  (xwidget-webkit-browse-url url t)
                (eww-open-file file))
              (current-buffer))))))

;;; Keybindings

(leader
  "oa" '(org-agenda :wk "agenda")
  "oc" '(org-capture :wk "capture")
  "oo" '(writing-open-org-directory :wk "org directory")
  "of" '(writing-find-org-file :wk "org file")
  "ow" '(writing-weekly-open :wk "weekly notes")
  "om" '(markdown-live-preview-mode :wk "markdown preview"))
