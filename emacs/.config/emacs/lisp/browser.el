;;; browser.el --- embedded WebKit, EWW, and the system browser  -*- lexical-binding: t -*-

(defun browser-resize-xwidgets (frame)
  "Resize WebKit views after a window layout change in FRAME."
  (walk-windows
   (lambda (window)
     (with-current-buffer (window-buffer window)
       (when (derived-mode-p 'xwidget-webkit-mode)
         (xwidget-webkit-auto-adjust-size window))))
   nil frame))

(use-package xwidget
  :ensure nil
  :if (featurep 'xwidget-internal)          ; only if this Emacs was built with xwidgets
  :commands (xwidget-webkit-browse-url)
  :custom
  (browse-url-browser-function #'xwidget-webkit-browse-url)             ; links open inside Emacs...
  (browse-url-secondary-browser-function #'browse-url-default-macosx-browser) ; ...C-u to force Safari
  :config
  (add-hook 'window-size-change-functions #'browser-resize-xwidgets))

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
  (let ((buffer (save-window-excursion       ; both browsers switch buffers themselves; capture instead
                  (if (featurep 'xwidget-internal)
                      (xwidget-webkit-browse-url url t)   ; t = new session, own buffer per SPC o b
                    (eww url))
                  (current-buffer))))
    (select-window
     (display-buffer buffer '((display-buffer-in-direction)
                              (direction . right)
                              (window-width . 0.5))))))

(defun browser-current-url ()
  "URL of the page in the current buffer, or the URL at point, or nil."
  (cond ((derived-mode-p 'xwidget-webkit-mode)
         (xwidget-webkit-uri (xwidget-webkit-current-session)))
        ((derived-mode-p 'eww-mode)
         (plist-get eww-data :url))
        (t (thing-at-point 'url t))))

(defun browser-open-externally (url &optional _new-window)
  "Open URL in the macOS default browser. Defaults to the current page or URL at point."
  (interactive (list (read-string "URL: " (browser-current-url))))
  (browse-url-default-macosx-browser url))

;;; Keybindings

(leader
  "ob" '(browser-open :wk "browser")
  "oB" '(browser-open-externally :wk "browser (external)")
  "oe" '(eww :wk "eww"))
