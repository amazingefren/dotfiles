;;; vim.el --- evil (vim emulation) and the SPC leader key  -*- lexical-binding: t -*-

(use-package evil
  :pin melpa                          ; GNU ELPA's 1.15.0 breaks on Emacs 31
  :demand t
  :init
  ;; Must be set before evil loads.
  (setq evil-want-integration t
        evil-want-keybinding nil
        evil-want-C-u-scroll t
        evil-want-Y-yank-to-eol t
        evil-undo-system 'undo-redo
        evil-respect-visual-line-mode t
        evil-split-window-below t
        evil-vsplit-window-right t)
  :config
  (evil-mode 1)

  (global-set-key [escape] #'keyboard-escape-quit)
  (dolist (map (list minibuffer-local-map
                     minibuffer-local-ns-map
                     minibuffer-local-completion-map
                     minibuffer-local-must-match-map
                     minibuffer-local-isearch-map))
    (define-key map [escape] #'abort-minibuffers))

  ;; motion-state-map is inherited by normal state and by read-only buffers.
  (define-key evil-motion-state-map (kbd "C-h") #'evil-window-left)
  (define-key evil-motion-state-map (kbd "C-j") #'dwm-focus-next)
  (define-key evil-motion-state-map (kbd "C-k") #'dwm-focus-previous)
  (define-key evil-motion-state-map (kbd "C-l") #'evil-window-right)
  ;; evil-visual-state-map's C-S-l, sending to agents, outranks this.
  (define-key evil-motion-state-map (kbd "C-S-h") #'dwm-shrink-master)
  (define-key evil-motion-state-map (kbd "C-S-l") #'dwm-grow-master)
  (global-set-key (kbd "C-<up>")    #'enlarge-window)
  (global-set-key (kbd "C-<down>")  #'shrink-window)
  (global-set-key (kbd "C-<left>")  #'enlarge-window-horizontally)
  (global-set-key (kbd "C-<right>") #'shrink-window-horizontally)

  (define-key evil-motion-state-map (kbd "M-h") #'evil-first-non-blank)
  (define-key evil-motion-state-map (kbd "M-l") #'evil-end-of-line)

  (defun visual-shift-left ()
    (interactive)
    (evil-shift-left (region-beginning) (region-end))
    (evil-normal-state)
    (evil-visual-restore))
  (defun visual-shift-right ()
    (interactive)
    (evil-shift-right (region-beginning) (region-end))
    (evil-normal-state)
    (evil-visual-restore))
  (define-key evil-visual-state-map (kbd "<") #'visual-shift-left)
  (define-key evil-visual-state-map (kbd ">") #'visual-shift-right)

  ;; Vim's two clipboards: y, d, c, x and p use the kill ring (vim's unnamed
  ;; register), and only the Cmd keys reach the system clipboard (vim's "+).
  (setq select-enable-clipboard nil)

  (evil-define-operator vim-yank-to-system (beg end type)
    "Copy the text moved over to the system clipboard."
    :move-point nil
    :repeat nil
    (evil-yank beg end type ?+))

  (evil-define-operator vim-cut-to-system (beg end type)
    "Cut the text moved over to the system clipboard."
    (evil-delete beg end type ?+))

  (defun vim-copy-region-to-system (beg end)
    "Copy the region to the system clipboard."
    (interactive "r")
    (gui-set-selection 'CLIPBOARD (buffer-substring-no-properties beg end))
    (deactivate-mark))

  (defun vim-cut-region-to-system (beg end)
    "Cut the region to the system clipboard."
    (interactive "r")
    (gui-set-selection 'CLIPBOARD (buffer-substring-no-properties beg end))
    (delete-region beg end))

  (defun vim-paste-from-system ()
    "Paste the system clipboard, leaving vim's registers alone."
    (interactive)
    (let ((text (gui-get-selection 'CLIPBOARD 'UTF8_STRING)))
      (unless text (user-error "The system clipboard is empty"))
      (cond ((and (derived-mode-p 'ghostel-mode) (fboundp 'ghostel--paste-text))
             (ghostel--paste-text (substring-no-properties text)))
            ((and (bound-and-true-p evil-local-mode) (evil-visual-state-p))
             (evil-visual-paste 1 ?+))
            ((and (bound-and-true-p evil-local-mode) (memq evil-state '(normal motion)))
             (evil-paste-after 1 ?+))
            (t (insert-for-yank text)))))

  (global-set-key (kbd "s-c") #'vim-copy-region-to-system)
  (global-set-key (kbd "s-y") #'vim-copy-region-to-system)
  (global-set-key (kbd "s-x") #'vim-cut-region-to-system)
  (global-set-key (kbd "s-v") #'vim-paste-from-system)
  (evil-define-key '(normal visual) 'global (kbd "s-y") #'vim-yank-to-system)
  (evil-define-key 'visual 'global
    (kbd "s-c") #'vim-yank-to-system
    (kbd "s-x") #'vim-cut-to-system)

  ;; Deleting while typing, as vim's insert-mode C-w and C-u do, fills no register.
  (defun vim-delete-word-backward (arg)
    "Delete ARG words before point."
    (interactive "p")
    (delete-region (point) (progn (backward-word arg) (point))))

  (defun vim-delete-word (arg)
    "Delete ARG words after point."
    (interactive "p")
    (delete-region (point) (progn (forward-word arg) (point))))

  (defun vim-delete-line-backward ()
    "Delete from the line's start to point, or join the line above at its start."
    (interactive)
    (if (bolp) (delete-char -1) (delete-region (line-beginning-position) (point))))

  (defun vim-delete-backward-word ()
    "Delete the word before point, as `evil-delete-backward-word' does."
    (interactive)
    (if (bolp) (delete-char -1)
      (delete-region (max (save-excursion (evil-backward-word-begin) (point))
                          (line-beginning-position))
                     (point))))

  (global-set-key [remap backward-kill-word] #'vim-delete-word-backward)
  (global-set-key [remap kill-word] #'vim-delete-word)
  (global-set-key [remap evil-delete-backward-word] #'vim-delete-backward-word)
  (global-set-key (kbd "s-<backspace>") #'vim-delete-line-backward))

(use-package evil-collection
  :pin melpa
  :after evil
  :custom
  (evil-collection-binding-overrides '((next-section-2 :enabled nil)
                                       (prev-section-2 :enabled nil)))
  :config
  (evil-collection-init))

(use-package evil-surround
  :after evil
  :config
  (global-evil-surround-mode 1))

(use-package evil-commentary
  :after evil
  :config
  (evil-commentary-mode 1))

(use-package vundo
  :commands vundo)

(use-package which-key
  :ensure nil
  :custom (which-key-idle-delay 0.4)
  :config
  (add-hook 'which-key-init-buffer-hook #'themes-popup-tint)
  (which-key-mode 1))

(use-package general
  :demand t
  :config
  (general-create-definer leader
    :states '(normal visual motion)
    :keymaps 'override
    :prefix "SPC")

  (define-advice evil-quit-all (:around (orig &optional bang) vim-confirm-quit)
    (if (and bang (not (yes-or-no-p "Quit Emacs and discard unsaved changes? ")))
        (message "Quit cancelled")
      (funcall orig bang)))
  (define-advice evil-quit-all-with-error-code (:around (orig &rest args) vim-confirm-quit)
    (when (yes-or-no-p "Quit Emacs? ")
      (apply orig args)))

  (defun config-reload ()
    "Re-evaluate init.el and every lisp/ file in the running Emacs.
Nothing restarts: buffers, terminals, agent sessions, and workspaces stay.
For one file, `M-x eval-buffer' in it does the same thing faster."
    (interactive)
    (let ((t0 (float-time)))
      ;; site-lisp packages are already `provide'd, so require would skip them.
      (dolist (file (append (file-expand-wildcards (expand-file-name "site-lisp/*/*.el" user-emacs-directory))
                            (file-expand-wildcards (expand-file-name "private/*/*.el" user-emacs-directory))))
        (load file nil 'nomessage))
      (load (expand-file-name "init.el" user-emacs-directory) nil 'nomessage)
      (message "Config reloaded in %.2fs" (- (float-time) t0))))

  (defun find-config-file ()
    "Find a file in this Emacs config."
    (interactive)
    (let ((default-directory user-emacs-directory))
      (call-interactively #'find-file)))

  (leader
    "SPC" '(find-file-dwim :wk "find file")
    ":"   '(consult-complex-command :wk "command history")
    "y"   '(vim-yank-to-system :wk "yank to clipboard")
    "o"   '(:ignore t :wk "open")

    "f"  '(:ignore t :wk "find")
    "ff" '(find-file-dwim :wk "file")
    "fg" '(consult-ripgrep :wk "grep")
    "fr" '(consult-recent-file :wk "recent")
    "fc" '(find-config-file :wk "config")
    "fp" '(project-switch-project :wk "project")
    "fb" '(apheleia-format-buffer :wk "format buffer")

    "b"  '(:ignore t :wk "buffer")
    "bb" '(consult-buffer :wk "switch")
    "bn" '(next-buffer :wk "next")
    "bp" '(previous-buffer :wk "previous")
    "bd" '(kill-current-buffer :wk "kill")

    "h"   '(:ignore t :wk "help")
    "hk"  '(describe-key :wk "key")
    "hv"  '(describe-variable :wk "variable")
    "hf"  '(describe-function :wk "function")
    "hm"  '(describe-mode :wk "mode")
    "hb"  '(embark-bindings :wk "bindings")
    "hp"  '(describe-package :wk "package")
    "hr"  '(:ignore t :wk "reload")
    "hrr" '(config-reload :wk "config")
    "hrt" '(themes-pick :wk "theme (live preview, remembered)")
    "hrp" '(packages-upgrade-with-rollback :wk "upgrade packages (snapshot first)")
    "hrP" '(packages-rollback :wk "roll back packages")

    "s"  '(:ignore t :wk "search")
    "sb" '(consult-line :wk "buffer lines")
    "sB" '(consult-line-multi :wk "all buffer lines")
    "sd" '(consult-flymake :wk "diagnostics")
    "ss" '(consult-imenu :wk "symbols")
    "sS" '(xref-find-apropos :wk "workspace symbols")
    "sh" '(describe-symbol :wk "help")
    "sk" '(embark-bindings :wk "keys")
    "sm" '(consult-mark :wk "marks")
    "s\"" '(consult-register :wk "registers")
    "sM" '(consult-man :wk "man")
    "su" '(vundo :wk "undo tree")

    "u" '(universal-argument :wk "prefix arg (C-u)")))
