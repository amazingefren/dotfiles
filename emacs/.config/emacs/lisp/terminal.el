;;; terminal.el --- Ghostel and the workspace terminal panel  -*- lexical-binding: t -*-

(use-package ghostel
  :commands (ghostel ghostel-project ghostel-exec)
  :custom
  (ghostel-module-auto-install 'download)
  (ghostel-module-directory (no-littering-expand-var-file-name "ghostel/"))
  (ghostel-max-scrollback (* 20 1024 1024))
  (ghostel-keymap-exceptions '("C-c" "C-x" "C-u" "C-h" "C-l" "M-x" "M-:" "C-\\"))
  :config
  (define-key ghostel-mode-map (kbd "C-h") #'evil-window-left)
  (define-key ghostel-mode-map (kbd "C-l") #'evil-window-right))

(defun terminal-enable-evil-ghostel ()
  "Enable terminal-first Evil behavior in the current Ghostel buffer."
  (require 'evil-ghostel)
  (evil-ghostel-mode 1)
  (setq-local evil-ghostel--escape-mode 'terminal)
  (evil-local-set-key 'insert (kbd "<escape>") #'evil-ghostel--escape)
  (evil-local-set-key 'emacs (kbd "<escape>") #'evil-ghostel--escape))

(use-package evil-ghostel
  :after (ghostel evil)
  :custom
  (evil-ghostel-escape 'terminal)
  :hook
  (ghostel-mode . terminal-enable-evil-ghostel)
  :config
  (evil-define-key* 'insert evil-ghostel-mode-map (kbd "C-l") #'evil-window-right)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'ghostel-mode)
        (terminal-enable-evil-ghostel)))))

(defun terminal--buffers ()
  "Return shell buffers in the current workspace."
  (seq-filter (lambda (buffer)
                (and (eq (buffer-local-value 'major-mode buffer) 'ghostel-mode)
                     (not (string-prefix-p "*herdr: " (buffer-name buffer)))
                     (memq buffer (persp-buffers (persp-curr)))))
              (buffer-list)))

(defun terminal--panel-window ()
  "Return the visible terminal panel window, if any."
  (seq-find (lambda (window)
              (and (eq (window-parameter window 'window-side) 'bottom)
                   (eq (buffer-local-value 'major-mode (window-buffer window)) 'ghostel-mode)))
            (window-list)))

(defun terminal--show (buffer)
  "Show BUFFER in the bottom terminal panel."
  (with-current-buffer buffer
    (evil-local-set-key 'insert (kbd "C-k") #'evil-window-up)
    (evil-local-set-key 'emacs (kbd "C-k") #'evil-window-up))
  (select-window
   (display-buffer buffer '((display-buffer-in-side-window)
                            (side . bottom) (slot . 0)
                            (window-height . 0.3)
                            (preserve-size . (nil . t))))))

(defun terminal-new ()
  "Start a shell in the workspace root."
  (interactive)
  (require 'ghostel)
  (let* ((default-directory (workspace-root))
         (name (format "*shell: %s*" (file-name-nondirectory (directory-file-name default-directory))))
         (buffer (save-window-excursion
                   (let ((ghostel-buffer-name name))
                     (ghostel '(4))))))
    (terminal--show buffer)))

(defun terminal-toggle ()
  "Show or hide the terminal panel."
  (interactive)
  (if-let* ((window (terminal--panel-window)))
      (delete-window window)
    (if-let* ((buffer (car (terminal--buffers))))
        (terminal--show buffer)
      (terminal-new))))

(defun terminal--cycle (step)
  "Select the terminal STEP positions from the current panel terminal."
  (let* ((buffers (terminal--buffers))
         (current (and (terminal--panel-window) (window-buffer (terminal--panel-window))))
         (index (or (seq-position buffers current) -1)))
    (unless buffers
      (user-error "No shells in this workspace"))
    (terminal--show (nth (mod (+ index step) (length buffers)) buffers))))

(defun terminal-next () "Select the next terminal." (interactive) (terminal--cycle 1))
(defun terminal-previous () "Select the previous terminal." (interactive) (terminal--cycle -1))

(defun terminal-pick ()
  "Select a terminal by name."
  (interactive)
  (let ((names (mapcar #'buffer-name (terminal--buffers))))
    (unless names
      (user-error "No shells in this workspace"))
    (terminal--show (get-buffer (completing-read "Shell: " names nil t)))))

(defun terminal-kill ()
  "Kill the visible terminal and show the next one."
  (interactive)
  (when-let* ((window (terminal--panel-window)))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer (window-buffer window)))
    (if-let* ((next (car (terminal--buffers))))
        (terminal--show next)
      (when (window-live-p window)
        (delete-window window)))))

;;; Keybindings

(leader
  "t"  '(:ignore t :wk "terminal")
  "tt" '(terminal-toggle :wk "panel")
  "tn" '(terminal-new :wk "new")
  "t]" '(terminal-next :wk "next")
  "t[" '(terminal-previous :wk "previous")
  "tl" '(terminal-pick :wk "pick")
  "tk" '(terminal-kill :wk "kill"))
