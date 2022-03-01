(setq inhibit-startup-message t)
(scroll-bar-mode -1)
(tool-bar-mode -1)
(tooltip-mode -1)
(set-fringe-mode 10)
(menu-bar-mode -1)
(column-number-mode)
(global-display-line-numbers-mode t)
(tab-bar-mode -1)
(completion-at-point)
(electric-pair-mode)
(setq tab-always-indent 'complete)
(setq backup-directory-alist `(("." . "~/.emacs.d/backups/")))

;; Pulse highlight current line on switch window
(defun pulse-line (&rest _)
  "Pulse the current line."
  (pulse-momentary-highlight-one-line (point)))
(dolist (command '(scroll-up-command scroll-down-command
                                     recenter-top-bottom other-window))
  (advice-add command :after #'pulse-line))


(global-set-key (kbd "<escape>") 'keyboard-escape-quit)


; Bootstrap Straight Package Manager
(setq package-enable-at-startup nil) ; disable use-package
(defvar bootstrap-version)
(let ((bootstrap-file
      (expand-file-name "straight/repos/straight.el/bootstrap.el" user-emacs-directory))
      (bootstrap-version 5))
  (unless (file-exists-p bootstrap-file)
    (with-current-buffer
        (url-retrieve-synchronously
        "https://raw.githubusercontent.com/raxod502/straight.el/develop/install.el"
        'silent 'inhibit-cookies)
      (goto-char (point-max))
      (eval-print-last-sexp)))
  (load bootstrap-file nil 'nomessage))

(straight-use-package 'use-package)
(setq straight-use-package-by-default t)

; Packages --------------------------------------
; Org Mode
(use-package org :straight t)

(use-package better-defaults)

(use-package dtrt-indent)
;------------------------------------------------
; Evil Mode
(use-package evil 
             :ensure t
             :straight t
             :init
             (setq evil-want-integration t)
             (setq evil-want-keybinding nil)
             (setq evil-want-C-u-scroll t)
             (setq evil-want-C-i-jump nil)
             :config
	     (define-key evil-normal-state-map (kbd "C-h") 'evil-window-left)
	     (define-key evil-normal-state-map (kbd "C-j") 'evil-window-down)
	     (define-key evil-normal-state-map (kbd "C-k") 'evil-window-up)
	     (define-key evil-normal-state-map (kbd "C-l") 'evil-window-right)
             (evil-mode 1)
             (evil-set-undo-system 'undo-tree))
(use-package evil-collection
             :after evil
             :ensure t
             :config
             (evil-collection-init))

(use-package evil-smartparens)
(add-hook 'smartparens-enabled-hook #'evil-smartparens-mode)
(use-package smartparens)
(require 'smartparens-config)
(add-hook 'js-mode-hook #'smartparens-mode)
;------------------------------------------------
; Evil Mode > Undo Tree
(use-package undo-tree :straight t)
(global-undo-tree-mode)
;------------------------------------------------
; LSP
(use-package lsp-mode
  :config
  (setq gc-cons-threshold 100000000)
  (setq read-process-output-max (* 1024 1024)))

(use-package lsp-ui
    :commands lsp-ui-mode
    :ensure t
    :config
    (setq lsp-ui-doc-enable t
          lsp-ui-doc-header t
          lsp-ui-doc-include-signature t
          lsp-ui-doc-border (face-foreground 'default)
          lsp-ui-sideline-show-code-actions t
          lsp-ui-sideline-delay 0.05))

(use-package flycheck
    :ensure t
    ;:init (global-flycheck-mode)
    )

(use-package evil-nerd-commenter
    :ensure t
    :config
    (define-key evil-normal-state-map "gc" 'evilnc-comment-or-uncomment-lines))

(use-package typescript-mode)
(add-hook 'typescript-mode-hook 'lsp-deferred)
(use-package web-mode)
(add-hook 'web-mode-hook 'lsp-deferred)
(add-hook 'js-mode-hook 'lsp-deferred)
(use-package php-mode)
(add-hook 'php-mode-hook 'lsp-deferred)
(use-package which-key)

(use-package company
    :ensure t
    :config
    (setq company-minimum-prefix-length 0)
    (setq company-idle-delay
      (lambda () (if (company-in-string-or-comment) nil 0)))
  
  )
(add-hook 'after-init-hook 'global-company-mode)

;------------------------------------------------
; Completion
(use-package vertico
  :init
  (vertico-mode))

(use-package orderless
  :init
  (setq completion-styles '(orderless)
        completion-category-defaults nil
        completion-category-overrides '((file (styles partial-completion)))))
(use-package consult
  :ensure t
  :init)

(use-package consult-company)
;; Persist history over Emacs restarts. Vertico sorts by history position.
(use-package savehist
  :init
  (savehist-mode))

;; A few more useful configurations...
(use-package emacs
  :init
  (defun crm-indicator (args)
    (cons (concat "[CRM] " (car args)) (cdr args)))
  (advice-add #'completing-read-multiple :filter-args #'crm-indicator)
  (setq minibuffer-prompt-properties
        '(read-only t cursor-intangible t face minibuffer-prompt))
  (add-hook 'minibuffer-setup-hook #'cursor-intangible-mode)

  ;; Enable recursive minibuffers
  (setq enable-recursive-minibuffers t))

(use-package savehist 
    :init
    (savehist-mode))

(use-package marginalia
    :after vertico
    :ensure t
    :custom
    (marginalia-annotators '(marginalia-annotators-heavy marginalia-annotators-light nil))
    :init
    (marginalia-mode))

; Doom Stuff
(use-package doom-modeline 
    :ensure t 
    :hook (after-init . doom-modeline-mode)
    :config (setq doom-modeline-height 22))

(use-package doom-themes
    :ensure t
    :config
    (setq doom-themes-enable-bold t)
    (setq doom-themes-enable-italic t)
    (setq doom-themes-treemacs-theme "doom-atom")
    (doom-themes-treemacs-config)
    (load-theme 'doom-palenight t))

(use-package all-the-icons
  :if (display-graphic-p))

(use-package rainbow-delimiters
    :hook (prog-mode . rainbow-delimiters-mode))

(use-package sublimity
    :ensure t
    :config
    (require 'sublimity-scroll)
    (setq sublimity-scroll-weight 10
	  sublimity-scroll-drift-length 5
	  sublimity-scroll-vertical-frame-delay 0.001
	  )
    :init
    (sublimity-mode 1))

(use-package zoom
    :ensure t
    :config
    (zoom-mode t))

(use-package centaur-tabs
    :demand
    :config
    (centaur-tabs-mode t)
    :bind
    ("C-<prior>" . centaur-tabs-backward)
    ("C-<next>" . centaur-tabs-forward)
    :init
    (define-key evil-normal-state-map (kbd "g t") 'centaur-tabs-forward)
    (define-key evil-normal-state-map (kbd "g T") 'centaur-tabs-backward))

(use-package treemacs
  :ensure t
  :defer t
  :init
  (with-eval-after-load 'winum
    (define-key winum-keymap (kbd "M-0") #'treemacs-select-window))
  :config
  (progn
    (setq treemacs-width 22)
    (treemacs-resize-icons 20)
    )
  :bind (
    :map global-map
    ("M-0"       . treemacs-select-window)
    ("C-x t 1"   . treemacs-delete-other-windows)
    ("C-s"   . treemacs)
    ("C-x t d"   . treemacs-select-directory)
    ("C-x t B"   . treemacs-bookmark)
    ("C-x t C-t" . treemacs-find-file)
    ("C-h" . evil-window-left)
    ("C-j" . evil-window-down)
    ("C-k" . evil-window-up)
    ("C-l" . evil-window-right)
    ("C-x t M-t" . treemacs-find-tag))
  )

(use-package treemacs-evil
  :after (treemacs evil)
  :ensure t)

(use-package magit
  :ensure t
  :commands (magit-status magit-get-current-branch))

(use-package evil-magit
  :after magit)

;; (defun xah-insert-bracket-pair (@left-bracket @right-bracket &optional @wrap-method)
;;   "Insert brackets around selection, word, at point, and maybe move cursor in between.

;;  *left-bracket and *right-bracket are strings. *wrap-method must be either 'line or 'block. 'block means between empty lines.

;; • if there's a region, add brackets around region.
;; • If *wrap-method is 'line, wrap around line.
;; • If *wrap-method is 'block, wrap around block.
;; • if cursor is at beginning of line and its not empty line and contain at least 1 space, wrap around the line.
;; • If cursor is at end of a word or buffer, one of the following will happen:
;;  xyz▮ → xyz(▮)
;;  xyz▮ → (xyz▮)       if in one of the lisp modes.
;; • wrap brackets around word if any. e.g. xy▮z → (xyz▮). Or just (▮)

;; URL `http://xahlee.info/emacs/emacs/elisp_insert_brackets_by_pair.html'
;; Version 2017-01-17"
;;   (if (use-region-p)
;;       (progn ; there's active region
;;         (let (
;;               ($p1 (region-beginning))
;;               ($p2 (region-end)))
;;           (goto-char $p2)
;;           (insert @right-bracket)
;;           (goto-char $p1)
;;           (insert @left-bracket)
;;           (goto-char (+ $p2 2))))
;;     (progn ; no text selection
;;       (let ($p1 $p2)
;;         (cond
;;          ((eq @wrap-method 'line)
;;           (setq $p1 (line-beginning-position) $p2 (line-end-position))
;;           (goto-char $p2)
;;           (insert @right-bracket)
;;           (goto-char $p1)
;;           (insert @left-bracket)
;;           (goto-char (+ $p2 (length @left-bracket))))
;;          ((eq @wrap-method 'block)
;;           (save-excursion
;;             (progn
;;               (if (re-search-backward "\n[ \t]*\n" nil 'move)
;;                   (progn (re-search-forward "\n[ \t]*\n")
;;                          (setq $p1 (point)))
;;                 (setq $p1 (point)))
;;               (if (re-search-forward "\n[ \t]*\n" nil 'move)
;;                   (progn (re-search-backward "\n[ \t]*\n")
;;                          (setq $p2 (point)))
;;                 (setq $p2 (point))))
;;             (goto-char $p2)
;;             (insert @right-bracket)
;;             (goto-char $p1)
;;             (insert @left-bracket)
;;             (goto-char (+ $p2 (length @left-bracket)))))
;;          ( ;  do line. line must contain space
;;           (and
;;            (eq (point) (line-beginning-position))
;;            ;; (string-match " " (buffer-substring-no-properties (line-beginning-position) (line-end-position)))
;;            (not (eq (line-beginning-position) (line-end-position))))
;;           (insert @left-bracket )
;;           (end-of-line)
;;           (insert  @right-bracket))
;;          ((and
;;            (or ; cursor is at end of word or buffer. i.e. xyz▮
;;             (looking-at "[^-_[:alnum:]]")
;;             (eq (point) (point-max)))
;;            (not (or
;;                  (string-equal major-mode "xah-elisp-mode")
;;                  (string-equal major-mode "emacs-lisp-mode")
;;                  (string-equal major-mode "lisp-mode")
;;                  (string-equal major-mode "lisp-interaction-mode")
;;                  (string-equal major-mode "common-lisp-mode")
;;                  (string-equal major-mode "clojure-mode")
;;                  (string-equal major-mode "xah-clojure-mode")
;;                  (string-equal major-mode "scheme-mode"))))
;;           (progn
;;             (setq $p1 (point) $p2 (point))
;;             (insert @left-bracket @right-bracket)
;;             (search-backward @right-bracket )))
;;          (t (progn
;;               ;; wrap around “word”. basically, want all alphanumeric, plus hyphen and underscore, but don't want space or punctuations. Also want chinese chars
;;               (skip-chars-backward "-_[:alnum:]")
;;               (setq $p1 (point))
;;               (skip-chars-forward "-_[:alnum:]")
;;               (setq $p2 (point))
;;               (goto-char $p2)
;;               (insert @right-bracket)
;;               (goto-char $p1)
;;               (insert @left-bracket)
;;               (goto-char (+ $p2 (length @left-bracket))))))))))

;; (defun xah-insert-paren () (interactive) (xah-insert-bracket-pair "(" ")") )
;; (defun xah-insert-bracket () (interactive) (xah-insert-bracket-pair "[" "]") )
;; (defun xah-insert-brace () (interactive) (xah-insert-bracket-pair "{" "}") )
;; (defun xah-insert-double-curly-quote () (interactive) (xah-insert-bracket-pair "“" "”") )
;; (defun xah-insert-curly-single-quote () (interactive) (xah-insert-bracket-pair "‘" "’") )
;; (defun xah-insert-single-angle-quote () (interactive) (xah-insert-bracket-pair "‹" "›") )
;; (defun xah-insert-double-angle-quote () (interactive) (xah-insert-bracket-pair "«" "»") )
;; (defun xah-insert-ascii-double-quote () (interactive) (xah-insert-bracket-pair "\"" "\"") )
;; (defun xah-insert-ascii-single-quote () (interactive) (xah-insert-bracket-pair "'" "'") )
;; (defun xah-insert-emacs-quote () (interactive) (xah-insert-bracket-pair "`" "'") )
;; (defun xah-insert-corner-bracket () (interactive) (xah-insert-bracket-pair "「" "」") )
;; (defun xah-insert-white-corner-bracket () (interactive) (xah-insert-bracket-pair "『" "』") )
;; (defun xah-insert-angle-bracket () (interactive) (xah-insert-bracket-pair "〈" "〉") )
;; (defun xah-insert-double-angle-bracket () (interactive) (xah-insert-bracket-pair "《" "》") )
;; (defun xah-insert-white-lenticular-bracket () (interactive) (xah-insert-bracket-pair "〖" "〗") )
;; (defun xah-insert-black-lenticular-bracket () (interactive) (xah-insert-bracket-pair "【" "】") )
;; (defun xah-insert-tortoise-shell-bracket () (interactive) (xah-insert-bracket-pair "〔" "〕") )
