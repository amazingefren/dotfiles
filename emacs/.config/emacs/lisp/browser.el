;;; browser.el --- embedded WebKit, EWW, and the system browser  -*- lexical-binding: t -*-

(defun browser-resize-xwidgets (frame)
  "Resize WebKit views after a window layout change in FRAME."
  (walk-windows
   (lambda (window)
     (with-current-buffer (window-buffer window)
       (when (derived-mode-p 'xwidget-webkit-mode)
         (xwidget-webkit-auto-adjust-size window))))
   nil frame))

(defun browser-split-window (split &rest args)
  "Call SPLIT with ARGS; replace duplicated WebKit buffers in newly created windows.
Restored windows retain their buffers. Return the split window.
On macOS a WebKit view renders in one window only."
  (let ((window (apply split args))
        (restored-window (nth 4 args)))
    (unless restored-window
      (with-current-buffer (window-buffer window)
        (when (derived-mode-p 'xwidget-webkit-mode)
          (set-window-buffer window (other-buffer (current-buffer) t)))))
    window))

(use-package xwidget
  :ensure nil
  :if (featurep 'xwidget-internal)
  :commands (xwidget-webkit-browse-url)
  :custom
  (xwidget-webkit-user-agent
   (when (eq system-type 'darwin)
     (let ((safari-version
            (car (process-lines "/usr/libexec/PlistBuddy" "-c" "Print :CFBundleShortVersionString"
                                "/Applications/Safari.app/Contents/Info.plist"))))
       (format "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/%s Safari/605.1.15"
               safari-version))))
  (browse-url-browser-function #'browser-ask)
  (browse-url-secondary-browser-function #'browse-url-default-macosx-browser)
  (browse-url-handlers '(("\\`https?://\\([^/]+\\.\\)?github\\.com" . browse-url-default-macosx-browser))) ; GitHub needs your logged-in browser
  :config
  (add-hook 'window-size-change-functions #'browser-resize-xwidgets)
  (advice-add 'split-window :around #'browser-split-window))

(use-package webkit-agent-mcp
  :load-path "site-lisp/webkit-agent"
  :ensure nil
  :demand t
  :commands (webkit-agent-mcp-dispatch))

(use-package eww
  :ensure nil
  :commands (eww)
  :custom
  (eww-search-prefix "https://duckduckgo.com/html/?q="))

(defvar browser-url-history nil)

(defun browser-open (url &optional _new-window)
  "Open URL in the embedded browser, in a split to the right of the current window."
  (interactive
   (list (read-string "URL: " (or (car browser-url-history) "http://localhost:3000")
                      'browser-url-history)))
  (let ((buffer (save-window-excursion   ; both browsers switch buffers themselves
                  (if (featurep 'xwidget-internal)
                      (xwidget-webkit-browse-url url t)
                    (eww url))
                  (current-buffer))))
    (select-window
     (display-buffer buffer '((display-buffer-in-direction)
                              (direction . right)
                              (window-width . 0.5))))))

(defun browser-ask (url &rest _)
  "Ask whether to open URL embedded, in the system browser, in EWW, or copy it.
Callers that bind `browse-url-browser-function' themselves (feeds b/B) and
URLs matching `browse-url-handlers' (GitHub) skip the question."
  (pcase (car (read-multiple-choice
               (format "Open %s" (truncate-string-to-width url 60 nil nil "…"))
               '((?x "xwidget" "Embedded WebKit, in a split")
                 (?b "browser" "macOS default browser")
                 (?e "eww"     "Text browser")
                 (?c "copy"    "Copy the URL"))))
    (?x (browser-open url))
    (?b (browse-url-default-macosx-browser url))
    (?e (eww url))
    (?c (kill-new url) (gui-set-selection 'CLIPBOARD url) (message "Copied %s" url))))

(defun browser-current-url ()
  "URL of the page in the current buffer, or the URL at point, or nil."
  (cond ((derived-mode-p 'xwidget-webkit-mode)
         (xwidget-webkit-uri (xwidget-webkit-current-session)))
        ((derived-mode-p 'eww-mode)
         (plist-get eww-data :url))
        (t (thing-at-point 'url t))))

(defun browser-set-viewport (width height)
  "Set the current WebKit page's WIDTH and HEIGHT in CSS pixels.
With a prefix argument, restore pane sizing. Signal `user-error' outside WebKit
or when the native viewport API is unavailable."
  (interactive (if current-prefix-arg '(nil nil)
                 (list (read-number "Viewport width: " 1920)
                       (read-number "Viewport height: " 1080))))
  (unless (derived-mode-p 'xwidget-webkit-mode) (user-error "Select a WebKit pane first"))
  (unless (fboundp 'xwidget-webkit-set-viewport) (user-error "Viewport controls need the native patch; rebuild Emacs"))
  (xwidget-webkit-set-viewport (xwidget-webkit-current-session) width height))

(defun browser-set-user-agent (user-agent)
  "Set USER-AGENT on the current WebKit page and reload it.
With a prefix argument, restore the native user agent. Signal `user-error'
outside WebKit or when the native user-agent API is unavailable."
  (interactive (list (unless current-prefix-arg
                       (read-string "User agent: " xwidget-webkit-user-agent))))
  (unless (derived-mode-p 'xwidget-webkit-mode) (user-error "Select a WebKit pane first"))
  (unless (fboundp 'xwidget-webkit-set-user-agent) (user-error "User-agent controls need the native patch; rebuild Emacs"))
  (xwidget-webkit-set-user-agent (xwidget-webkit-current-session) user-agent)
  (xwidget-webkit-reload))

(defun browser-open-profile (url name persistent)
  "Open URL in profile NAME; non-nil PERSISTENT retains its website data across restarts.
Return the page. Signal `user-error' for invalid settings or missing native support."
  (interactive (list (read-string "URL: " "https://www.google.com" 'browser-url-history)
                     (read-string "Profile: " "qa") current-prefix-arg))
  (require 'webkit-agent)
  (let ((settings (make-hash-table :test #'equal))
        (profile (make-hash-table :test #'equal)))
    (puthash "name" name profile)
    (puthash "persistent" (if persistent t :false) profile)
    (puthash "profile" profile settings)
    (webkit-agent-open url nil settings)))

(defun browser-open-externally (url &optional _new-window)
  "Open URL in the macOS default browser. Defaults to the current page or URL at point."
  (interactive (list (read-string "URL: " (browser-current-url))))
  (browse-url-default-macosx-browser url))

(leader
  "ob" '(browser-open :wk "browser")
  "oB" '(browser-open-externally :wk "browser (external)")
  "oU" '(browser-set-user-agent :wk "browser user agent")
  "ov" '(browser-set-viewport :wk "browser viewport")
  "oe" '(eww :wk "eww"))

(defun browser-open-url ()
  "Prompts for an empty URL and navigates the current browser page."
  (interactive)
  (xwidget-webkit-browse-url (read-string "xwidget-webkit URL: ")))

(defun browser-bind-open-url ()
  "Binds URL navigation and tab closing in the current WebKit buffer."
  (evil-local-set-key 'normal (kbd "o") #'browser-open-url)
  (evil-local-set-key 'normal (kbd "q") #'browser-close-tab))

(defun browser-close-tab ()
  "Closes the current browser tab and keeps remaining workspace tabs visible."
  (interactive)
  (webkit-agent-pages)
  (webkit-agent-close (webkit-agent--page-for-buffer (current-buffer))))

(add-hook 'xwidget-webkit-mode-hook #'browser-bind-open-url)
