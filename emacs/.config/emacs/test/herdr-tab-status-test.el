;;; herdr-tab-status-test.el --- Herdr tab status tests  -*- lexical-binding: t -*-

(require 'ert)
(load-file (expand-file-name "../site-lisp/herdr/herdr.el"
                             (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest herdr-tab-status-follows-agent-and-preserves-tab-name ()
  (let ((tabs (list '((tab_id . "t1") (label . "build"))
                    '((tab_id . "t2") (label . "shell"))))
        (panes '(((pane_id . "p1") (tab_id . "t1"))
                 ((pane_id . "p2") (tab_id . "t2"))))
        renames)
    (cl-letf (((symbol-function 'herdr--run)
               (lambda (_session &rest args)
                 (pcase args
                   (`("pane" "list") `((panes . ,panes)))
                   (`("tab" "list") `((tabs . ,tabs)))
                   (`("tab" "rename" ,id ,label)
                    (setf (alist-get 'label
                                     (seq-find (lambda (tab)
                                                 (equal (alist-get 'tab_id tab) id))
                                               tabs))
                          label)
                    (push (cons id label) renames))))))
      (herdr--sync-tab-status "test" '(((pane_id . "p1") (agent_status . "working"))))
      (should (equal (alist-get 'label (car tabs)) "● build"))
      (should (equal (alist-get 'label (cadr tabs)) "shell"))
      (herdr--sync-tab-status "test" '(((pane_id . "p1") (agent_status . "working"))))
      (should (= (length renames) 1))
      (setf (alist-get 'label (car tabs)) "● my build")
      (herdr--sync-tab-status "test" '(((pane_id . "p1") (agent_status . "blocked"))))
      (should (equal (alist-get 'label (car tabs)) "◆ my build"))
      (herdr--sync-tab-status "test" '(((pane_id . "p1") (agent_status . "done"))))
      (should (equal (alist-get 'label (car tabs)) "✓ my build"))
      (herdr--sync-tab-status "test" nil)
      (should (equal (alist-get 'label (car tabs)) "my build")))))

(ert-deftest herdr-tab-status-rolls-up-split-agent-panes ()
  (should (equal (herdr--tab-status-symbol
                  '(((agent_status . "working")) ((agent_status . "blocked"))))
                 "◆"))
  (should (equal (herdr--tab-status-symbol
                  '(((agent_status . "idle")) ((agent_status . "done"))))
                 "✓"))
  (should (equal (herdr--tab-status-symbol '(((agent_status . "idle")))) "○"))
  (should (equal (herdr--tab-status-symbol '(((agent_status . "unknown")))) "·"))
  (should-not (herdr--tab-status-symbol nil)))

(ert-deftest herdr-rename-keeps-status-on-agent-tab ()
  (let (renamed)
    (cl-letf (((symbol-function 'herdr--agent)
               (lambda (&rest _) '((name . "old") (workspace_id . "w1"))))
              ((symbol-function 'herdr--run)
               (lambda (_session &rest args)
                 (pcase args
                   (`("pane" "list" "--workspace" "w1")
                    '((panes . (((pane_id . "p1") (tab_id . "t1"))))))
                   (`("tab" "list" "--workspace" "w1")
                    '((tabs . (((tab_id . "t1") (label . "◆ old"))))))
                   (`("agent" "rename" "p1" "new") nil)
                   (`("tab" "rename" "t1" ,label)
                    (setq renamed label)))))
              ((symbol-function 'herdr--poll) #'ignore))
      (herdr--rename "test" "p1" "new")
      (should (equal renamed "new")))))

(provide 'herdr-tab-status-test)
;;; herdr-tab-status-test.el ends here
