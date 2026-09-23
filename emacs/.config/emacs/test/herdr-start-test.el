;;; herdr-start-test.el --- Herdr agent launch tests  -*- lexical-binding: t -*-

(require 'ert)
(defvar herdr-start-test--dir
  (file-name-directory (or load-file-name buffer-file-name)))
(load-file (expand-file-name "../site-lisp/herdr/herdr.el" herdr-start-test--dir))

(defun herdr-start-test--fake-herdr (output &optional delay)
  "Return a fake herdr executable that prints OUTPUT after DELAY seconds."
  (let ((file (make-temp-file "fake-herdr")))
    (with-temp-file file
      (insert "#!/bin/sh\n"
              (format "sleep %s\n" (or delay 0))
              (format "printf '%%s' %s\n" (shell-quote-argument output))))
    (set-file-modes file #o755)
    file))

(defun herdr-start-test--wait (predicate)
  (with-timeout (5 (error "Timed out"))
    (while (not (funcall predicate))
      (accept-process-output nil 0.05))))

(ert-deftest herdr-run-async-does-not-block-and-parses-result ()
  (let* ((herdr-program (herdr-start-test--fake-herdr
                         "{\"result\":{\"ok\":true}}" 0.5))
         (herdr-config-file nil)
         result
         (start (float-time)))
    (herdr--run-async "s" '("agent" "start") (lambda (r) (setq result r)) #'ignore)
    (should (< (- (float-time) start) 0.2))
    (herdr-start-test--wait (lambda () result))
    (should (equal result '((ok . t))))))

(ert-deftest herdr-run-async-reports-herdr-errors ()
  (let* ((herdr-program (herdr-start-test--fake-herdr
                         "{\"error\":{\"code\":\"agent_pane_busy\",\"message\":\"busy\"}}"))
         (herdr-config-file nil)
         err)
    (herdr--run-async "s" '("agent" "start") #'ignore (lambda (e) (setq err e)))
    (herdr-start-test--wait (lambda () err))
    (should (equal err '(herdr-error "agent_pane_busy" "busy")))))

(ert-deftest herdr-start-agent-retries-while-pane-busy ()
  (let ((calls 0) started)
    (cl-letf (((symbol-function 'herdr--run-async)
               (lambda (_session _args on-success on-error)
                 (if (< (cl-incf calls) 3)
                     (funcall on-error '(herdr-error "agent_pane_busy" "busy"))
                   (funcall on-success nil))))
              ((symbol-function 'run-at-time)
               (lambda (_time _repeat fn &rest args) (apply fn args)))
              ((symbol-function 'herdr--poll) #'ignore)
              ((symbol-function 'herdr--run)
               (lambda (&rest args) (setq started args))))
      (herdr--start-agent "s" "w1:p1" "demo" '("agent" "start") 1)
      (should (= calls 3))
      (should (equal started '("s" "agent" "focus" "w1:p1"))))))

(ert-deftest agents-claude-launch-command-fits-a-terminal-line ()
  (let* ((user-emacs-directory (expand-file-name "../" herdr-start-test--dir))
         (var (make-temp-file "agents-var" t)))
    ;; agents.el's package and key setup needs the full config; only its
    ;; functions are under test.
    (defmacro use-package (&rest _))
    (defmacro leader (&rest _))
    (load-file (expand-file-name "../lisp/agents.el" herdr-start-test--dir))
    (cl-letf (((symbol-function 'no-littering-expand-var-file-name)
               (lambda (name) (expand-file-name name var))))
      (let* ((agents--mcp-launch-context
              (list :root temporary-file-directory :name "laya-eplot-demo"
                    :session "-dotfiles" :pane "w6:p2"))
             (args (agents--claude-emacs-mcp-arguments))
             (command (mapconcat #'shell-quote-argument (cons "claude" args) " ")))
        (should (< (string-bytes command) 1024))
        (should (string-match-p "HERDR_PANE_ID=w6"
                                (with-temp-buffer
                                  (insert-file-contents (nth 1 args))
                                  (buffer-string))))
        (should (file-readable-p (nth 3 args)))))))
