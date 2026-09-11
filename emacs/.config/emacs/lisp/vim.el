;;; vim.el --- evil (vim emulation) and the SPC leader key  -*- lexical-binding: t -*-

;; evil: vim modes, motions, operators, text objects, registers, ex commands.
(use-package evil
  :pin melpa                          ; GNU ELPA release lags; 1.15.0 breaks on Emacs 31
  :demand t                           ; load immediately
  :init
  ;; These must be set BEFORE evil loads, hence :init.
  (setq evil-want-integration t         ; load evil's built-in integrations
        evil-want-keybinding nil        ; don't bind keys in other modes; evil-collection does that better
        evil-want-C-u-scroll t          ; C-u scrolls up like vim (instead of Emacs prefix arg)
        evil-want-Y-yank-to-eol t       ; Y yanks to end of line (like nvim default)
        evil-undo-system 'undo-redo     ; use Emacs 28+ built-in undo/redo for u and C-r
        evil-respect-visual-line-mode t ; j/k move by screen line when lines wrap
        evil-split-window-below t       ; :split opens below
        evil-vsplit-window-right t)     ; :vsplit opens right
  :config
  (evil-mode 1)

  ;; Esc gets out of everything: prompts, prefix keys, the minibuffer.
  (global-set-key [escape] #'keyboard-escape-quit)
  (dolist (map (list minibuffer-local-map
                     minibuffer-local-ns-map
                     minibuffer-local-completion-map
                     minibuffer-local-must-match-map
                     minibuffer-local-isearch-map))
    (define-key map [escape] #'abort-minibuffers))

  ;; Windows: C-h/j/k/l to move between splits, C-arrows to resize.
  ;; (motion-state-map is inherited by normal state and by read-only buffers.)
  (define-key evil-motion-state-map (kbd "C-h") #'evil-window-left)
  (define-key evil-motion-state-map (kbd "C-j") #'evil-window-down)
  (define-key evil-motion-state-map (kbd "C-k") #'evil-window-up)
  (define-key evil-motion-state-map (kbd "C-l") #'evil-window-right)
  (global-set-key (kbd "C-<up>")    #'enlarge-window)
  (global-set-key (kbd "C-<down>")  #'shrink-window)
  (global-set-key (kbd "C-<left>")  #'enlarge-window-horizontally)
  (global-set-key (kbd "C-<right>") #'shrink-window-horizontally)

  ;; M-h / M-l: start / end of line.
  (define-key evil-motion-state-map (kbd "M-h") #'evil-first-non-blank)
  (define-key evil-motion-state-map (kbd "M-l") #'evil-end-of-line)

  ;; < and > in visual mode indent and keep the selection, like `<gv' / `>gv'.
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
  (define-key evil-visual-state-map (kbd ">") #'visual-shift-right))

;; evil-collection: vim keys in every other mode (magit, dired, help, terminals...).
(use-package evil-collection
  :pin melpa
  :after evil
  :config
  (evil-collection-init))

;; ys / cs / ds to add, change, delete surrounding quotes and brackets.
(use-package evil-surround
  :after evil
  :config
  (global-evil-surround-mode 1))

;; gcc / gc<motion> to toggle comments.
(use-package evil-commentary
  :after evil
  :config
  (evil-commentary-mode 1))

;; Visual undo tree (SPC s u).
(use-package vundo
  :commands vundo)

;; Centered, distraction-free writing (SPC z).
(use-package olivetti
  :commands olivetti-mode)

;; which-key: after pressing SPC (or any prefix), pop up what keys come next.
;; Built in since Emacs 30.
(use-package which-key
  :ensure nil
  :custom (which-key-idle-delay 0.4)   ; seconds before the popup appears
  :config (which-key-mode 1))

;; general: a nicer way to define keybinds. Creates the `leader' macro used
;; here and in every other lisp/ file to bind SPC keys.
(use-package general
  :demand t
  :config
  (general-create-definer leader
    :states '(normal visual motion)   ; leader works in these evil states
    :keymaps 'override                ; ...and beats any mode's own bindings
    :prefix "SPC")

  (defun config-reload ()
    "Re-evaluate init.el and every lisp/ file in the running Emacs.
Nothing restarts: buffers, terminals, agent sessions, and workspaces stay.
For one file, `M-x eval-buffer' in it does the same thing faster."
    (interactive)
    (let ((t0 (float-time)))
      ;; My own packages under site-lisp/ are already `provide'd, so a plain
      ;; require would skip them. Load their files outright first.
      (dolist (file (file-expand-wildcards (expand-file-name "site-lisp/*/*.el" user-emacs-directory)))
        (load file nil 'nomessage))
      (load (expand-file-name "init.el" user-emacs-directory) nil 'nomessage)
      (message "Config reloaded in %.2fs" (- (float-time) t0))))

  (defun find-config-file ()
    "Find a file in this Emacs config."
    (interactive)
    (let ((default-directory user-emacs-directory))
      (call-interactively #'find-file)))

  ;; Top-level and general leader binds. :wk is the label which-key shows.
  ;; Other prefixes live with their feature: SPC l lang.el, SPC g git.el,
  ;; SPC o notes/browser/feeds/music.el, SPC TAB workspaces.el + home.el,
  ;; SPC e tree.el, SPC t and SPC w shell.el, SPC a agents.el.
  (leader
    "SPC" '(find-file-dwim :wk "find file")
    ":"   '(consult-complex-command :wk "command history")
    "y"   '(clipboard-kill-ring-save :wk "yank to clipboard")
    "z"   '(zen-toggle :wk "zen")
    "o"   '(:ignore t :wk "open")        ; org, browser, rss, spotify: notes/browser/feeds/music.el

    "f"  '(:ignore t :wk "find")
    "ff" '(find-file-dwim :wk "file")
    "fg" '(project-ripgrep :wk "grep")
    "fr" '(consult-recent-file :wk "recent")
    "fc" '(find-config-file :wk "config")
    "fp" '(project-switch-project :wk "project")
    "fb" '(apheleia-format-buffer :wk "format buffer")

    "b"  '(:ignore t :wk "buffer")
    "bb" '(consult-buffer :wk "switch")
    "bd" '(kill-current-buffer :wk "kill")

    ;; Help, Doom-style. SPC h r r reloads the config.
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
    "hrp" '(package-upgrade-all :wk "upgrade packages")

    "s"  '(:ignore t :wk "search")
    "sb" '(consult-line :wk "buffer lines")
    "sB" '(consult-line-multi :wk "all buffer lines")
    "sd" '(consult-flymake :wk "diagnostics")
    "ss" '(consult-imenu :wk "symbols")
    "sS" '(xref-find-apropos :wk "workspace symbols")
    "su" '(vundo :wk "undo tree")
    "sh" '(describe-symbol :wk "help")
    "sk" '(embark-bindings :wk "keys")
    "sm" '(consult-mark :wk "marks")
    "s\"" '(consult-register :wk "registers")
    "sM" '(consult-man :wk "man")))
