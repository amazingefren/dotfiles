;;; notes.el --- org-mode basics  -*- lexical-binding: t -*-

;; org: outliner, todo lists, agenda. Built in; :ensure nil.
(use-package org
  :ensure nil
  :commands (org-agenda org-capture)
  :custom
  (org-directory "~/org")                                     ; all org files live here
  (org-agenda-files '("~/org/todo.org" "~/org/inbox.org"))    ; files the agenda reads TODOs from
  (org-default-notes-file "~/org/inbox.org")
  ;; SPC o c then t or n. %? = where the cursor lands, %U = inactive timestamp.
  (org-capture-templates
   '(("t" "Task" entry (file+headline "todo.org" "Tasks")
      "* TODO %?\n  %U")
     ("n" "Note" entry (file "notes.org")
      "* %?\n  %U")))
  (org-startup-indented t)          ; indent body text under headings
  (org-hide-emphasis-markers t)     ; show *bold* as bold, without the asterisks
  :config
  (make-directory org-directory t))

;; Prettier bullets, tags, and tables.
(use-package org-modern
  :hook (org-mode . org-modern-mode))

(defun open-org-directory ()
  "Open the org directory in dired."
  (interactive)
  (dired org-directory))

(leader
  "oa" '(org-agenda :wk "agenda")
  "oc" '(org-capture :wk "capture")
  "oo" '(open-org-directory :wk "directory"))
