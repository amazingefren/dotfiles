;;; writing.el --- Org and Markdown  -*- lexical-binding: t -*-

(use-package org
  :ensure nil
  :commands (org-agenda org-capture)
  :custom
  (org-directory "~/org")
  (org-agenda-files '("~/org/todo.org" "~/org/inbox.org"))
  (org-default-notes-file "~/org/inbox.org")
  (org-capture-templates
   '(("t" "Task" entry (file+headline "todo.org" "Tasks") "* TODO %?\n  %U")
     ("n" "Note" entry (file "notes.org") "* %?\n  %U")
     ("m" "Meeting" entry (file+olp+datetree "meetings.org") "* %^{Meeting}\n  %U\n  - %?")))
  (org-startup-indented t)
  (org-hide-emphasis-markers t)
  :config
  (make-directory org-directory t))

(use-package org-modern
  :hook (org-mode . org-modern-mode))

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
  "om" '(markdown-live-preview-mode :wk "markdown preview"))
