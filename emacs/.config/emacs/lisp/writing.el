;;; writing.el --- Org and Markdown  -*- lexical-binding: t -*-

(use-package org
  :ensure nil
  :commands (org-agenda org-capture)
  :custom
  (org-directory "~/org")
  (org-export-backends '(ascii html icalendar latex md odt))
  (org-agenda-files '("~/org"))
  (org-agenda-file-regexp "\\`[^.][^.]*\\.org\\'")
  (org-agenda-window-setup 'current-window)
  (org-agenda-tags-column 0)
  (org-agenda-time-grid '((daily today require-timed) () "" ""))
  (org-agenda-current-time-string "← now ─────────")
  (org-agenda-scheduled-leaders '("Scheduled: " "Late %2dd:  "))
  (org-agenda-prefix-format
   '((agenda . " %i %-12.12:c%?-12t% s")
     (todo . " %i %-12.12:c")
     (tags . " %i %-12.12:c")
     (search . " %i %-12.12:c")))
  (org-agenda-custom-commands
   '(("h" "This week and someday, then undated TODOs"
      ((agenda "" ((org-agenda-span 'week)
                   (org-deadline-warning-days 0)))
       (tags-todo "someday" ((org-agenda-overriding-header (writing-agenda-day-header "Someday"))
                             (org-agenda-block-separator nil)
                             (org-agenda-hide-tags-regexp "\\`someday\\'")
                             (org-agenda-prefix-format " %i %-12.12:cSomeday:    ")))
       (alltodo "" ((org-agenda-overriding-header "TODOs without a date")
                    (org-agenda-skip-function #'writing-agenda-skip-someday)
                    (org-agenda-todo-ignore-scheduled 'all)
                    (org-agenda-todo-ignore-deadlines 'all)))))))
  (org-todo-keywords
   '((sequence "TODO(t)" "WAITING(w@)" "|" "DONE(d)" "CANCELLED(c@)")))
  (org-log-into-drawer t)
  (org-default-notes-file "~/org/inbox.org")
  (org-capture-templates
   '(("t" "Task" entry (file+headline "todo.org" "Tasks") "* TODO %?\n  %U")
     ("n" "Note" item (file+function "weekly.org" writing-weekly-notes) "%?")
     ("m" "Meeting" entry (file+function "weekly.org" writing-weekly-meetings) "* %^{Meeting}\n  %U\n  - %?")
     ("d" "Document" plain (file writing-org-doc-file) "#+TITLE: %(identity writing-org-doc-title)\n\n* "
      :immediate-finish t :jump-to-captured t)))
  (org-insert-heading-respect-content t)
  (org-M-RET-may-split-line '((default . nil)))
  (org-startup-indented t)
  (org-hide-emphasis-markers t)
  :config
  (make-directory org-directory t)
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

(custom-set-faces
 '(org-imminent-deadline ((t :inherit warning)))
 '(org-upcoming-deadline ((t :inherit warning)))
 '(org-upcoming-distant-deadline ((t :inherit warning))))

;; calendar.org is written by icalBuddy (brew install ical-buddy).

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
                     (insert "# -*- buffer-read-only: t -*-\n#+TITLE: Calendar\n#+CATEGORY: meeting\n"
                             "# Copied from Calendar.app by writing-calendar-sync; edits are overwritten.\n\n")
                     (dolist (line lines)
                       (when (string-prefix-p "@@ " line)
                         (pcase-let ((`(,title ,when . ,rest) (split-string (substring line 3) " ~~ ")))
                           (when-let* ((stamp (and when (writing-calendar--timestamp when))))
                             (insert "* " title "\n" stamp "\n")
                             (dolist (r rest) (insert r "\n"))))))
                     (buffer-string))))
        ;; An empty result is Calendar.app not syncing, not an empty month.
        (unless (or (not (seq-some (lambda (l) (string-prefix-p "@@ " l)) lines))
                    (and (file-exists-p file)
                         (equal text (with-temp-buffer (insert-file-contents file) (buffer-string)))))
          (with-temp-file file (insert text))
          (when-let* ((buffer (find-buffer-visiting file)))
            (with-current-buffer buffer (revert-buffer t t t)))))
    (error (message "Calendar sync failed: %s" (error-message-string err)))))

(defvar writing-calendar-timer nil)
(when (timerp writing-calendar-timer) (cancel-timer writing-calendar-timer))
(when (executable-find "icalBuddy")
  (setq writing-calendar-timer (run-with-timer 0 900 #'writing-calendar-sync)))

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
        (let ((pos (point)) (eol (line-end-position)))
          (while (< pos eol)
            (let ((next (next-single-property-change pos 'face nil eol)))
              (unless (memq 'org-todo (ensure-list (get-text-property pos 'face)))
                (add-face-text-property pos next 'shadow))
              (setq pos next)))))
      (forward-line 1))))

(add-hook 'org-agenda-finalize-hook #'writing-agenda-show-waiting-notes)
(add-hook 'org-agenda-finalize-hook #'writing-agenda-style-someday)
(add-hook 'org-agenda-finalize-hook #'org-modern-agenda 90)

(defvar writing-agenda--refresh-timer nil)

(defun writing-agenda-refresh-soon (&rest _)
  "Rebuild the agendas on screen once Emacs is idle, so edits show without gr."
  (unless (timerp writing-agenda--refresh-timer)
    (setq writing-agenda--refresh-timer (run-with-idle-timer 0.3 nil #'writing-agenda--refresh))))

(defun writing-agenda--refresh ()
  (setq writing-agenda--refresh-timer nil)
  (if (active-minibuffer-window)
      (writing-agenda-refresh-soon)
    (dolist (window (window-list-1 nil 'nomini 'visible))
      (when (with-current-buffer (window-buffer window) (derived-mode-p 'org-agenda-mode))
        (with-selected-window window (org-agenda-redo t))))))

(defun writing-agenda-refresh-after-save ()
  (when (derived-mode-p 'org-mode) (writing-agenda-refresh-soon)))

(dolist (hook '(org-after-todo-state-change-hook org-after-tags-change-hook org-after-note-stored-hook))
  (add-hook hook #'writing-agenda-refresh-soon))
(add-hook 'after-save-hook #'writing-agenda-refresh-after-save)
(advice-add 'org-add-planning-info :after #'writing-agenda-refresh-soon)
(advice-add 'org-priority :after #'writing-agenda-refresh-soon)

(defun writing-org--headings-p (beg end)
  "Non-nil if there is an Org heading between BEG and END."
  (save-excursion
    (goto-char beg)
    (re-search-forward org-outline-regexp-bol end t)))

;; `org-display-buffer-split' deletes other windows and splits into the herdr side window.
(add-to-list 'display-buffer-alist
             '("\\`\\(?: ?\\*\\(?:Agenda Commands\\|Org \\(?:Select\\|Note\\|todo\\|tags\\|Export Dispatcher\\)\\)\\*\\|CAPTURE-\\)"
               (display-buffer-reuse-window display-buffer-in-direction)
               (window . main) (direction . below) (window-height . 0.4)
               (body-function . writing-org-menu-tint)))

(defun writing-org-menu-tint (window)
  "Tint WINDOW's buffer if it is one of Org's menus rather than a capture."
  (with-current-buffer (window-buffer window)
    (unless (string-prefix-p "CAPTURE-" (buffer-name))
      (themes-popup-tint))))

(use-package org-modern
  :hook (org-mode . org-modern-mode)
  :custom
  ;; Berkeley Mono has only these arrows; the defaults for levels 3+ show as boxes.
  (org-modern-fold-stars '(("▶" . "▼") ("▷" . "▽")))
  (org-modern-cycle-stars t))

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

(defvar writing-org-doc-title nil)

(defun writing-org-doc-file ()
  "Ask for a document title and return its new file in ~/org/docs/."
  (setq writing-org-doc-title
        (string-remove-suffix ".org" (string-trim (read-string "Document title: "))))
  (let* ((slug (string-trim (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase writing-org-doc-title)) "-" "-"))
         (file (expand-file-name (concat slug ".org") (expand-file-name "docs" org-directory))))
    (when (file-exists-p file)
      (user-error "%s already exists; open it with SPC o f" (abbreviate-file-name file)))
    (make-directory (file-name-directory file) t)
    file))

(defun writing-org-copy-markdown ()
  "Copy the buffer, or the active region, as Markdown for pasting into a ticket."
  (interactive)
  (require 'ox-md)
  (let ((md (org-export-as 'md nil nil t '(:with-toc nil :section-numbers nil))))
    (setq md (replace-regexp-in-string "^\\( *[-+*]\\) +" "\\1 " md))
    (setq md (replace-regexp-in-string "\n\\{3,\\}" "\n\n" md))
    (kill-new (string-trim md))
    (gui-set-selection 'CLIPBOARD (string-trim md))
    (when (and (fboundp 'evil-visual-state-p) (evil-visual-state-p))
      (evil-exit-visual-state))
    (message "Copied as Markdown")))

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

;; Keys don't reach the xwidget PDF view; it is driven by mouse/trackpad.
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

(leader
  "oa" '(org-agenda :wk "agenda")
  "oc" '(org-capture :wk "capture")
  "oo" '(writing-open-org-directory :wk "org directory")
  "of" '(writing-find-org-file :wk "org file")
  "ow" '(writing-weekly-open :wk "weekly notes")
  "oy" '(writing-org-copy-markdown :wk "copy as markdown")
  "om" '(markdown-live-preview-mode :wk "markdown preview"))
