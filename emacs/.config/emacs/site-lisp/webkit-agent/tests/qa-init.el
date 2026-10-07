;;; qa-init.el --- Isolated WebKit QA server -*- lexical-binding: t; -*-

;;; Commentary:
;; Loads the browser MCP in a separate Emacs server.

;;; Code:

(let* ((directory (file-name-directory load-file-name))
       (emacs-directory (expand-file-name "../../.." directory)))
  (setq server-name "webkit-qa"
        user-emacs-directory (make-temp-file "webkit-qa-config-" t))
  (add-to-list 'load-path (expand-file-name "lisp" emacs-directory))
  (add-to-list 'load-path (expand-file-name "site-lisp/webkit-agent" emacs-directory))
  (load "mcp" nil t)
  (require 'webkit-agent-mcp)
  (setq xwidget-webkit-user-agent
        (format "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/%s Safari/605.1.15"
                (car (process-lines "/usr/libexec/PlistBuddy" "-c" "Print :CFBundleShortVersionString"
                                    "/Applications/Safari.app/Contents/Info.plist"))))
  (require 'server)
  (unless (daemonp) (server-start)))

(provide 'webkit-agent-qa-init)
;;; qa-init.el ends here
