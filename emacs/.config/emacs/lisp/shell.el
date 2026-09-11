;;; shell.el --- terminal panel, and window layout helpers  -*- lexical-binding: t -*-
;;
;; Shells live in a panel along the bottom, like VS Code's terminal panel or a
;; tmux split. One panel per workspace; it can hold several shells (dev
;; server, ssh, ...) and you cycle through them in place. The shells are
;; ordinary ghostel buffers, so SPC b b also finds them.
;;
;;   SPC t t   show/hide the panel (starts a shell the first time)
;;   SPC t n   new shell in the panel
;;   SPC t ]   next shell      SPC t [   previous shell
;;   SPC t l   pick a shell by name
;;   SPC t k   kill the current shell
;; From an editor window C-j drops into the panel; C-k comes straight back up,
;; even while typing in the shell (C-c ESC first for anything else).

(defun shell--buffers ()
  "Shell buffers of this workspace, in ghostel's name order."
  (seq-filter (lambda (b)
                (and (eq (buffer-local-value 'major-mode b) 'ghostel-mode)
                     (not (string-prefix-p "*herdr: " (buffer-name b)))   ; agent terminals aren't shells
                     (memq b (persp-buffers (persp-curr)))))
              (buffer-list)))

(defun shell--panel-window ()
  "The bottom panel window if it is showing a shell, else nil."
  (seq-find (lambda (w) (and (eq (window-parameter w 'window-side) 'bottom)
                             (eq (buffer-local-value 'major-mode (window-buffer w)) 'ghostel-mode)))
            (window-list)))

(defun shell--show (buffer)
  "Show BUFFER in the bottom panel and select it."
  ;; The panel is at the bottom, so the way out is up. Give C-k that job here
  ;; (readline's C-k is covered by C-u / C-w); agent terminals keep theirs.
  (with-current-buffer buffer
    (evil-local-set-key 'insert (kbd "C-k") #'evil-window-up)
    (evil-local-set-key 'emacs  (kbd "C-k") #'evil-window-up))
  (select-window
   (display-buffer buffer '((display-buffer-in-side-window)
                            (side . bottom) (slot . 0)
                            (window-height . 0.3)
                            (preserve-size . (nil . t))))))

(defun shell-new ()
  "Start a new shell in the workspace root and show it in the panel."
  (interactive)
  (require 'ghostel)
  (let* ((default-directory (workspace-root))
         (name (format "*shell: %s*" (file-name-nondirectory (directory-file-name default-directory))))
         (buffer (save-window-excursion
                   (let ((ghostel-buffer-name name)) (ghostel '(4))))))   ; C-u: always a new buffer
    (shell--show buffer)))

(defun shell-toggle ()
  "Show the shell panel, or hide it if it is showing. Starts a shell the first time."
  (interactive)
  (if-let* ((w (shell--panel-window)))
      (delete-window w)
    (if-let* ((buffer (car (shell--buffers))))
        (shell--show buffer)
      (shell-new))))

(defun shell--cycle (step)
  (let* ((buffers (shell--buffers))
         (cur (and (shell--panel-window) (window-buffer (shell--panel-window))))
         (i (or (seq-position buffers cur) -1)))
    (unless buffers (user-error "No shells in this workspace"))
    (shell--show (nth (mod (+ i step) (length buffers)) buffers))))

(defun shell-next () "Next shell in the panel." (interactive) (shell--cycle 1))
(defun shell-previous () "Previous shell in the panel." (interactive) (shell--cycle -1))

(defun shell-pick ()
  "Pick one of this workspace's shells by name."
  (interactive)
  (let ((names (mapcar #'buffer-name (shell--buffers))))
    (unless names (user-error "No shells in this workspace"))
    (shell--show (get-buffer (completing-read "Shell: " names nil t)))))

(defun shell-kill ()
  "Kill the shell showing in the panel and show the next one, if any."
  (interactive)
  (when-let* ((w (shell--panel-window)))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer (window-buffer w)))
    (if-let* ((next (car (shell--buffers))))
        (shell--show next)
      (when (window-live-p w) (delete-window w)))))

(leader
  "t"  '(:ignore t :wk "terminal")
  "tt" '(shell-toggle :wk "panel")
  "tn" '(shell-new :wk "new shell")
  "t]" '(shell-next :wk "next")
  "t[" '(shell-previous :wk "previous")
  "tl" '(shell-pick :wk "pick")
  "tk" '(shell-kill :wk "kill"))

;;; Windows -------------------------------------------------------------------
;;
;; SPC w: layout undo/redo (winner), maximize toggle, zen, resize with repeat.
(use-package winner
  :ensure nil
  :config (winner-mode 1))

(defvar window-maximize--saved nil "Layout to restore when un-maximizing.")

(defun window-toggle-maximize ()
  "Focus on this window alone (tree, panels, and splits hidden); again restores the layout."
  (interactive)
  (if window-maximize--saved
      (progn (set-window-configuration window-maximize--saved)
             (setq window-maximize--saved nil))
    (setq window-maximize--saved (current-window-configuration))
    (when (window-with-parameter 'window-side) (window-toggle-side-windows))
    (delete-other-windows)))

(defvar zen--saved nil)

(defun zen-toggle ()
  "Zen: this window alone, text centered, no line numbers, no tab bar. Again restores everything."
  (interactive)
  (if zen--saved
      (progn (set-window-configuration (car zen--saved))
             (setq tab-bar-show t)
             (with-current-buffer (cadr zen--saved)
               (olivetti-mode -1)
               (when (derived-mode-p 'prog-mode 'text-mode) (display-line-numbers-mode 1)))
             (setq zen--saved nil))
    (setq zen--saved (list (current-window-configuration) (current-buffer)))
    (when (window-with-parameter 'window-side) (window-toggle-side-windows))
    (delete-other-windows)
    (setq tab-bar-show nil)
    (display-line-numbers-mode -1)
    (olivetti-mode 1)))

;; Resizing. SPC w + then keep pressing + / - / < / > to continue (repeat-mode).
(defvar-keymap window-resize-repeat-map
  :repeat t
  "+" #'enlarge-window
  "-" #'shrink-window
  ">" #'enlarge-window-horizontally
  "<" #'shrink-window-horizontally
  "=" #'balance-windows)
(repeat-mode 1)

(leader
  "w"  '(:ignore t :wk "window")
  "wm" '(window-toggle-maximize :wk "maximize toggle")
  "w=" '(balance-windows :wk "balance")
  "w+" '(enlarge-window :wk "taller")
  "w-" '(shrink-window :wk "shorter")
  "w>" '(enlarge-window-horizontally :wk "wider")
  "w<" '(shrink-window-horizontally :wk "narrower")
  "wu" '(winner-undo :wk "undo layout")
  "wr" '(winner-redo :wk "redo layout")
  "wv" '(evil-window-vsplit :wk "split right")
  "ws" '(evil-window-split :wk "split below")
  "wq" '(evil-window-delete :wk "close")
  "wo" '(delete-other-windows :wk "only this"))
