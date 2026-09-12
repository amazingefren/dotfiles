;;; feeds.el --- Elfeed via Yarr's Fever API  -*- lexical-binding: t -*-

(defconst feeds-yarr-fever-url "https://rss.amazingefren.com/fever/"
  "Fever API endpoint for the Yarr instance.")

(defun feeds-yarr-source ()
  "Build the Elfeed-protocol source for Yarr."
  (list (format "fever+https://%s@rss.amazingefren.com"
                (op-secret 'yarr-username))
        :api-url feeds-yarr-fever-url
        :password (op-secret 'yarr-password)))

(defun feeds-search-browse-in-split ()
  "Open selected feed entries in embedded-browser splits."
  (interactive)
  (let ((browse-url-browser-function #'browser-open))
    (elfeed-search-browse-url)))

(defun feeds-search-browse-externally ()
  "Open selected feed entries in the external browser."
  (interactive)
  (let ((browse-url-secondary-browser-function #'browser-open-externally))
    (elfeed-search-browse-url t)))

(defun feeds-show-browse-in-split ()
  "Open the current feed entry in an embedded-browser split."
  (interactive)
  (let ((browse-url-browser-function #'browser-open))
    (elfeed-show-visit)))

(defun feeds-show-browse-externally ()
  "Open the current feed entry in the external browser."
  (interactive)
  (let ((browse-url-secondary-browser-function #'browser-open-externally))
    (elfeed-show-visit t)))

(use-package elfeed
  :commands (elfeed elfeed-update)
  :custom
  (elfeed-search-filter "@2-weeks-ago +unread")     ; default view: unread from the last two weeks
  (elfeed-search-title-max-width 90)
  (elfeed-curl-max-connections 8)
  (elfeed-feeds nil)
  :config
  ;; Resolve the 1Password references only when Elfeed is initialized.
  (setq elfeed-feeds (list (feeds-yarr-source)))
  ;; Keep the existing starred-entry keybinding.
  (defalias 'elfeed-toggle-star (elfeed-expose #'elfeed-search-toggle-all 'star))
  ;; evil-collection only covers tagging; give the rest of elfeed's own keys
  ;; back their meaning in normal state (evil would otherwise use b/r/s for motions).
  (evil-define-key 'normal elfeed-search-mode-map
    (kbd "RET") #'elfeed-search-show-entry
    "b" #'feeds-search-browse-in-split
    "B" #'feeds-search-browse-externally
    "r" #'elfeed-search-untag-unread     ; mark read
    "u" #'elfeed-search-tag-unread       ; mark unread (evil-collection had these backwards)
    "s" #'elfeed-search-live-filter
    "R" #'elfeed-update
    "*" #'elfeed-toggle-star
    "F" #'feeds-pick-filter
    "q" #'elfeed-search-quit-window)
  (evil-define-key 'normal elfeed-show-mode-map
    "n" #'elfeed-show-next
    "p" #'elfeed-show-prev
    "b" #'feeds-show-browse-in-split
    "B" #'feeds-show-browse-externally
    "r" #'elfeed-show-refresh
    "*" (lambda () (interactive) (elfeed-show-tag 'star))
    "q" #'elfeed-kill-buffer))

(use-package elfeed-protocol
  :after elfeed
  :custom
  (elfeed-protocol-enabled-protocols '(fever))
  (elfeed-protocol-fever-fetch-category-as-tag t)
  (elfeed-protocol-fever-update-unread-only nil)
  :config
  (elfeed-protocol-enable))

;; Saved Elfeed filters. Yarr folders arrive as tags via Fever.
(defvar feeds-filters
  '(("all unread"     . "@2-weeks-ago +unread")
    ("starred"        . "+star")
    ("unsorted"       . "@2-weeks-ago +unread +unsorted")
    ("core"           . "@2-weeks-ago +unread +core")
    ("labs"           . "@2-weeks-ago +unread +labs")
    ("claude & tools" . "@2-weeks-ago +unread +tools")
    ("anthropic"      . "@1-month-ago +anthropic")
    ("practitioners"  . "@2-weeks-ago +unread +practitioners")
    ("research"       . "@3-days-ago +unread +research")
    ("community"      . "@2-days-ago +unread +community")
    ("today"          . "@1-day-ago")
    ("everything"     . "@1-month-ago")))

(defun feeds-pick-filter ()
  "Set the elfeed search filter to one of `feeds-filters'."
  (interactive)
  (let ((name (completing-read "Filter: " (mapcar #'car feeds-filters) nil t)))
    (elfeed-search-set-filter (alist-get name feeds-filters nil nil #'equal))))

(defun feeds-open ()
  "Open RSS in the home workspace."
  (interactive)
  (persp-switch "home")
  (elfeed))

;;; Keybindings

(leader "or" '(feeds-open :wk "rss"))
