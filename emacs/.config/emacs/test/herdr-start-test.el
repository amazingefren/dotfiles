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

(ert-deftest herdr-session-name-fits-socket-path ()
  ;; herdr's socket lives at ~/.config/herdr/sessions/NAME/herdr-client.sock,
  ;; and macOS caps socket paths at 104 bytes: long names must be shortened.
  (should (equal (herdr--session-name-for "muiq-web-app") "muiq-web-app"))
  (should (equal (herdr--session-name-for ".dotfiles") "-dotfiles"))
  (let ((a (herdr--session-name-for "muiq-web-app@jev-natural-lang-study-results-filter"))
        (b (herdr--session-name-for "muiq-web-app@jev-natural-lang-study-results-filter2")))
    (should (<= (length a) herdr-session-name-max))
    (should (string-prefix-p "muiq-web-app-jev" a))
    (should-not (equal a b))
    (should (equal a (herdr--session-name-for "muiq-web-app@jev-natural-lang-study-results-filter")))))

(ert-deftest herdr-workspace-children-reads-stopped-sessions ()
  ;; A stopped session is read from its session.json; others are skipped by name.
  (let* ((dir (make-temp-file "herdr-session" t))
         (herdr-program (make-temp-file "fake-herdr"))
         (herdr-config-file nil))
    (with-temp-file (expand-file-name "session.json" dir)
      (insert "{\"version\":3,\"workspaces\":[{\"custom_name\":\"web@notes\",\"identity_cwd\":\"/src/web\"},"
              "{\"custom_name\":\"other\",\"identity_cwd\":\"/x\"}]}"))
    (with-temp-file herdr-program
      (insert "#!/bin/sh\ncat <<'X'\nname status directory socket\n"
              (format "web-notes stopped %s %s/herdr.sock\n" dir dir)
              "api stopped /nowhere /nowhere/herdr.sock\nX\n"))
    (set-file-modes herdr-program #o755)
    (should (equal (herdr-workspace-children "web")
                   '(("web@notes" "/src/web" "web-notes"))))))

(ert-deftest herdr-overview-formats-stats ()
  (let ((herdr-context-window 1000000))
    (should (equal (substring-no-properties (herdr-overview--context 239468)) "239k ▰▱▱▱▱ 24%"))
    (should (equal (herdr-overview--context nil) "")))
  (should (equal (herdr-overview--model "claude-opus-5-5") "opus 5.5"))
  (should (equal (herdr-overview--model "gpt-5") "gpt-5"))
  (should (equal (substring-no-properties
                  (herdr-overview--age (* (- (float-time) 7200) 1e9)))
                 "2h")))

(ert-deftest herdr-overview-git-branch-reads-worktrees ()
  (let* ((main (make-temp-file "main" t))
         (tree (make-temp-file "tree" t))
         (default-directory main))
    (call-process "git" nil nil nil "init" "-q" "-b" "trunk")
    (call-process "git" nil nil nil "-c" "user.name=t" "-c" "user.email=t@t"
                  "commit" "-q" "--allow-empty" "-m" "i")
    (delete-directory tree)
    (call-process "git" nil nil nil "worktree" "add" "-q" "-b" "feature/x" tree)
    (should (equal (herdr--git-branch main) "trunk"))
    (should (equal (herdr--git-branch tree) "feature/x"))
    (should-not (herdr--git-branch (make-temp-file "plain" t)))))

(ert-deftest herdr-overview-nests-children-under-project ()
  (let ((herdr--workspace-sessions (make-hash-table :test #'equal))
        (herdr--agents (make-hash-table :test #'equal))
        (herdr--claude-stats (make-hash-table :test #'equal))
        (herdr--claude-sessions (make-hash-table :test #'equal))
        (herdr-overview--scope 'all)
        (herdr-overview--collapsed (make-hash-table :test #'equal)))
    (puthash "web" "web" herdr--workspace-sessions)
    (puthash "web@notes" "web-notes" herdr--workspace-sessions)
    (puthash "api" "api" herdr--workspace-sessions)
    (puthash "web" '(((pane_id . "w1:p1") (agent . "claude") (agent_status . "working") (name . "fix")))
             herdr--agents)
    (puthash '("web" . "w1:p1") "sid" herdr--claude-sessions)
    (puthash "sid" '((context_tokens . 500000) (model . "claude-opus-5-5")) herdr--claude-stats)
    (cl-letf (((symbol-function 'herdr-overview--subagents) (lambda () (make-hash-table :test #'equal)))
              ((symbol-function 'herdr--session-running-p) (lambda (_) t))
              ((symbol-function 'herdr--overview-process) (lambda (&rest _) nil))
              ((symbol-function 'herdr--run)
               (lambda (session &rest args)
                 (pcase args
                   (`("workspace" "list")
                    `((workspaces ((workspace_id . "w1") (label . ,(pcase session ("web-notes" "web@notes") (_ session)))))))
                   (`("pane" "list" . ,_)
                    `((panes ((pane_id . ,(if (equal session "web") "w1:p1" "w1:p9")) (tab_id . "w1:t1")))))
                   (_ nil)))))
      (let* ((rows (herdr--overview-entries))
             (names (mapcar (lambda (r) (string-trim (substring-no-properties (car (aref (cadr r) 0))))) rows)))
        (should (equal (mapcar #'car (mapcar #'car rows))
                       '(space terminal project space agent space terminal)))
        ;; Without the tab bar loaded, workspaces sort by name.
        (should (equal (car names) "▾ api"))             ; no children: no project row
        (should (equal (nth 2 names) "▾ web"))
        (should (equal (nth 3 names) "▾ base"))
        (should (equal (nth 5 names) "▾ notes"))
        ;; The agent row carries its transcript stats.
        (should (string-prefix-p "500k" (substring-no-properties (aref (cadr (nth 4 rows)) 3))))
        (should (equal (aref (cadr (nth 4 rows)) 4) "opus 5.5"))
        ;; Folding the project hides its workspaces.
        (puthash '(project "web") t herdr-overview--collapsed)
        (should (equal (mapcar #'car (mapcar #'car (herdr--overview-entries)))
                       '(space terminal project)))))))
