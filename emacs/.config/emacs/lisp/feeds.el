;;; feeds.el --- Elfeed via Yarr's Fever API  -*- lexical-binding: t -*-

(defconst feeds-yarr-fever-url "https://rss.amazingefren.com/fever/"
  "Fever API endpoint for the Yarr instance.")

(defvar feeds-xwidget-buffer nil
  "The single embedded browser buffer used for feed entries.")

(defun feeds-refresh ()
  "Refresh feeds when no Elfeed curl requests are in progress."
  (interactive)
  (when (and (featurep 'elfeed-protocol)
             (zerop elfeed-curl-queue-active)
             (null elfeed-curl-queue))
    (elfeed-update)))

(defun feeds--parse-json-natively (orig &rest args)
  "Call ORIG with `json-read' bound to the native JSON parser.
The parser returns what `json-read' does with its default settings."
  (cl-letf (((symbol-function 'json-read)
             (lambda ()
               (json-parse-buffer :object-type 'alist :array-type 'array
                                  :null-object nil :false-object :json-false))))
    (apply orig args)))

(defun feeds-open-in-split (url &optional _new-window)
  "Show URL in the feed xwidget, reusing its existing WebKit session.
The first visit creates a browser split.  Later visits navigate that same
browser instead of creating more xwidget buffers and windows."
  (if (not (featurep 'xwidget-internal))
      (browser-open url)
    (let ((buffer
           (if (and (buffer-live-p feeds-xwidget-buffer)
                    (with-current-buffer feeds-xwidget-buffer
                      (derived-mode-p 'xwidget-webkit-mode)))
               (condition-case nil
                   (with-current-buffer feeds-xwidget-buffer
                     (xwidget-webkit-goto-uri
                      (xwidget-webkit-current-session) url)
                     (current-buffer))
                 ;; The WebKit session may be gone while its buffer survives.
                 (error nil))
             nil)))
      (unless buffer
        (setq feeds-xwidget-buffer
              (save-window-excursion
                (xwidget-webkit-browse-url url t)
                (current-buffer)))
        (setq buffer feeds-xwidget-buffer))
      (select-window
       (display-buffer buffer '((display-buffer-reuse-window)
                                (display-buffer-in-direction)
                                (direction . right)
                                (window-width . 0.5)))))))

(defun feeds-yarr-source ()
  "Build the Elfeed-protocol source for Yarr."
  (list (format "fever+https://%s@rss.amazingefren.com"
                (op-secret 'yarr-username))
        :api-url feeds-yarr-fever-url
        :password (op-secret 'yarr-password)))

(defun feeds-search-browse-in-split ()
  "Open selected feed entries in embedded-browser splits."
  (interactive)
  (let ((browse-url-browser-function #'feeds-open-in-split))
    (elfeed-search-browse-url)))

(defun feeds-search-browse-externally ()
  "Open selected feed entries in the external browser."
  (interactive)
  (let ((browse-url-secondary-browser-function #'browser-open-externally))
    (elfeed-search-browse-url t)))

(defun feeds-show-browse-in-split ()
  "Open the current feed entry in an embedded-browser split."
  (interactive)
  (let ((browse-url-browser-function #'feeds-open-in-split))
    (elfeed-show-visit)))

(defun feeds-show-browse-externally ()
  "Open the current feed entry in the external browser."
  (interactive)
  (let ((browse-url-secondary-browser-function #'browser-open-externally))
    (elfeed-show-visit t)))

(use-package elfeed
  :commands (elfeed elfeed-update)
  :custom
  (elfeed-search-filter "@2-weeks-ago +unread")
  (elfeed-search-title-max-width 90)
  (elfeed-curl-max-connections 8)
  (elfeed-feeds nil)
  :config
  (setq elfeed-feeds (list (feeds-yarr-source)))
  (defalias 'elfeed-toggle-star (elfeed-expose #'elfeed-search-toggle-all 'star))
  ;; evil-collection only covers tagging; evil would otherwise use b/r/s for motions.
  (evil-define-key 'normal elfeed-search-mode-map
    (kbd "RET") #'elfeed-search-show-entry
    "b" #'feeds-search-browse-in-split
    "B" #'feeds-search-browse-externally
    "r" #'elfeed-search-untag-unread
    "u" #'elfeed-search-tag-unread       ; evil-collection has r/u backwards
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
  ;; Yarr IDs have large gaps; otherwise only the next 50 IDs after the cursor are fetched.
  (elfeed-protocol-fever-update-unread-only t)
  :config
  (elfeed-protocol-enable)
  ;; json.el's `json-read' allocates enough for several GCs per sync.
  (advice-add 'elfeed-curl--call-callback :around #'feeds--parse-json-natively))

;; Yarr folders arrive as tags via Fever.
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
  (elfeed)
  (feeds-refresh))

(leader "or" '(feeds-open :wk "rss"))
