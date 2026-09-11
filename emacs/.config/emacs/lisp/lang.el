;;; lang.el --- LSP, tree-sitter, formatting  -*- lexical-binding: t -*-

;; Tree-sitter. Emacs 31 ships the *-ts-mode major modes and, since 31, can
;; install the grammars itself: the first file of a language triggers a
;; download + compile, then the -ts- mode becomes the default for that type.
;; (The treesit-auto package did this before; it re-probed every grammar on
;; every file open and cost ~2s per file.)
(use-package treesit
  :ensure nil
  :custom
  (treesit-enabled-modes t)                  ; prefer every built-in -ts- mode over its classic mode
  (treesit-auto-install-grammar 'always)     ; install missing grammars without asking
  (treesit-font-lock-level 4)                ; maximum highlighting detail
  :config
  ;; All grammars live in one place, under XDG data, never in the config dir.
  ;; Auto-install uses the first writable dir in `treesit-extra-load-path'; the
  ;; manual M-x treesit-install-language-grammar defaults to the last dir used,
  ;; so seed that too.
  (let ((dir (expand-file-name "emacs/tree-sitter/" (xdg-data-home))))
    (setq treesit-extra-load-path (list dir))
    (setq treesit--install-language-grammar-out-dir-history (list dir))))

;; Markdown. Emacs 31 has a built-in markdown-ts-mode but its authors call it
;; experimental, so markdown-mode it is. gfm = GitHub flavored.
;;   Editing: fenced code highlighted in its own language, bigger headings,
;;   tables aligned as you type (TAB / C-c C-c re-aligns).
;;   C-c C-x C-m hides the markup (* _ # `) for a cleaner read.
;;   SPC o m toggles a rendered preview in the embedded browser, styled like
;;   GitHub, refreshed on every save. Rendering is done by pandoc (brew).
(use-package markdown-mode
  :mode ("\\.md\\'" . gfm-mode)
  :custom
  (markdown-fontify-code-blocks-natively t)
  (markdown-header-scaling t)
  (markdown-enable-wiki-links t)
  (markdown-command "pandoc -f gfm -t html5 --wrap=none")
  (markdown-css-paths '("https://cdnjs.cloudflare.com/ajax/libs/github-markdown-css/5.8.1/github-markdown-dark.min.css"))
  (markdown-xhtml-header-content "<style>body{background:#0d1117;margin:0}</style>")
  (markdown-xhtml-body-preamble "<article class=\"markdown-body\" style=\"max-width:880px;margin:0 auto;padding:32px 40px\">")
  (markdown-xhtml-body-epilogue "</article>")
  (markdown-live-preview-window-function #'markdown-preview-in-xwidget)
  (markdown-live-preview-delete-export 'delete-on-destroy))

(defvar-local markdown-preview--buffer nil)

(defun markdown-preview-in-xwidget (file)
  "Show the exported FILE in the embedded browser, reusing the same page on refresh.
Used by `markdown-live-preview-mode' (SPC o m)."
  (let ((url (concat "file://" file)))
    (if (and (buffer-live-p markdown-preview--buffer) (featurep 'xwidget-internal))
        (with-current-buffer markdown-preview--buffer
          (xwidget-webkit-goto-uri (xwidget-webkit-current-session) url)
          (current-buffer))
      (setq markdown-preview--buffer
            (save-window-excursion
              (if (featurep 'xwidget-internal)
                  (xwidget-webkit-browse-url url t)
                (eww-open-file file))
              (current-buffer))))))

(leader "om" '(markdown-live-preview-mode :wk "markdown preview"))

;; mise.el: per-project tool versions and env from mise. Each buffer gets the
;; PATH mise would give a shell in that project dir, so eglot, apheleia, and
;; shells find the right node/python/go and the servers installed through mise.
(use-package mise
  :hook (after-init . global-mise-mode))

;; eglot: the built-in LSP client. It looks for the server binary on PATH;
;; nothing here installs servers. Install them once with mise/npm/go/brew:
;;   typescript-language-server, pyright, gopls, rust-analyzer, lua-language-server
(use-package eglot
  :ensure nil
  ;; Start eglot automatically in these modes.
  :hook ((typescript-ts-mode tsx-ts-mode js-ts-mode
          python-ts-mode go-ts-mode rust-ts-mode lua-ts-mode)
         . eglot-ensure)
  :custom
  (eglot-autoshutdown t)                    ; stop the server when its last buffer closes
  (eglot-events-buffer-config '(:size 0))   ; don't log every LSP message (faster)
  :config
  ;; eglot knows most servers already; lua-ts-mode needs to be told.
  (add-to-list 'eglot-server-programs
               '((lua-mode lua-ts-mode) . ("lua-language-server")))

  ;; Vim-style LSP keys. gd (go to definition) already works via evil.
  (setq evil-lookup-func (lambda () (eldoc t)))   ; K = show docs for symbol at point
  (evil-define-key 'normal eglot-mode-map
    "gr"  #'xref-find-references
    "]d"  #'flymake-goto-next-error                ; flymake = the diagnostics UI eglot feeds
    "[d"  #'flymake-goto-prev-error)

  (leader
    "l"  '(:ignore t :wk "lsp")
    "lr" '(eglot-rename :wk "rename")
    "la" '(eglot-code-actions :wk "code action")
    "lf" '(eglot-format :wk "format (lsp)")
    "lR" '(eglot-reconnect :wk "reconnect")))

;; apheleia: run external formatters (prettier, ruff, gofmt, rustfmt, stylua).
;; It already knows which formatter goes with which mode. Format-on-save is
;; OFF by default so untouched files don't produce surprise diffs.
;; SPC f b formats now; M-x toggle-format-on-save enables it for one buffer.
(use-package apheleia
  :commands (apheleia-format-buffer apheleia-mode)
  :config
  ;; Overrides for modes where apheleia's default isn't what I want.
  (setf (alist-get 'python-ts-mode apheleia-mode-alist) '(ruff-isort ruff))
  (setf (alist-get 'lua-ts-mode apheleia-mode-alist) 'stylua))

(defun toggle-format-on-save ()
  "Toggle format-on-save for the current buffer."
  (interactive)
  (apheleia-mode 'toggle)
  (message "Format on save %s" (if apheleia-mode "on" "off")))
