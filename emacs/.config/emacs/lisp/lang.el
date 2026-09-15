;;; lang.el --- tree-sitter, LSP, and formatting  -*- lexical-binding: t -*-

(use-package treesit
  :ensure nil
  :custom
  (treesit-enabled-modes t)
  (treesit-auto-install-grammar 'always)
  (treesit-font-lock-level 4)
  :config
  (let ((dir (expand-file-name "emacs/tree-sitter/" (xdg-data-home))))
    (make-directory dir t)
    (setq treesit-extra-load-path (list dir)
          treesit--install-language-grammar-out-dir-history (list dir))))

(use-package csv-mode
  :mode ("\\.[ct]sv\\'" . csv-mode)
  :hook (csv-mode . csv-align-mode)
  )

;; Give each project its mise-managed toolchain environment.
(use-package mise
  :hook (after-init . global-mise-mode))

(defconst lang-lsp-install-commands
  '((typescript-ts-mode . ("npm" "install" "--global" "typescript" "typescript-language-server"))
    (tsx-ts-mode        . ("npm" "install" "--global" "typescript" "typescript-language-server"))
    (js-ts-mode         . ("npm" "install" "--global" "typescript" "typescript-language-server"))
    (typescript-mode    . ("npm" "install" "--global" "typescript" "typescript-language-server"))
    (js-mode            . ("npm" "install" "--global" "typescript" "typescript-language-server"))
    (python-ts-mode     . ("npm" "install" "--global" "pyright"))
    (python-mode        . ("npm" "install" "--global" "pyright"))
    (go-ts-mode         . ("go" "install" "golang.org/x/tools/gopls@latest"))
    (go-mode            . ("go" "install" "golang.org/x/tools/gopls@latest"))
    (rust-ts-mode       . ("rustup" "component" "add" "rust-analyzer"))
    (rust-mode          . ("rustup" "component" "add" "rust-analyzer"))
    (lua-ts-mode        . ("brew" "install" "lua-language-server"))
    (lua-mode           . ("brew" "install" "lua-language-server"))))

(declare-function eglot-ensure "eglot")
(declare-function eldoc-box-help-at-point "eldoc-box")

(defun lang-show-documentation ()
  "Show documentation at point in a child frame."
  (interactive)
  (eldoc-box-help-at-point)
  (eldoc t))

(defun lang-install-lsp-server ()
  "Install the language server for the current major mode."
  (interactive)
  (let* ((mode major-mode)
         (args (alist-get mode lang-lsp-install-commands))
         (program (car args)))
    (unless args
      (user-error "No LSP installer is configured for %s" mode))
    (unless (executable-find program)
      (user-error "Cannot install the %s LSP: `%s' is not on PATH" mode program))
    (let* ((command (mapconcat #'shell-quote-argument args " "))
           (source-buffer (current-buffer))
           (buffer (compilation-start command 'compilation-mode
                                      (lambda (_mode) (format "*install LSP: %s*" mode)))))
      (with-current-buffer buffer
        (add-hook 'compilation-finish-functions
                  (lambda (_buffer status)
                    (when (and (string-prefix-p "finished" status)
                               (buffer-live-p source-buffer))
                      (with-current-buffer source-buffer
                        (eglot-ensure))))
                  nil t)))))

(use-package eglot
  :ensure nil
  :hook ((typescript-ts-mode tsx-ts-mode js-ts-mode python-ts-mode go-ts-mode rust-ts-mode lua-ts-mode) . eglot-ensure)
  :custom
  (eglot-autoshutdown t)
  (eglot-events-buffer-config '(:size 0))
  (eglot-code-action-indications '(left-fringe))
  :config
  (add-to-list 'eglot-server-programs '((lua-mode lua-ts-mode) . ("lua-language-server")))
  (setq evil-lookup-func (lambda () (eldoc t)))
  (evil-define-key 'normal eglot-mode-map
    "K" #'lang-show-documentation
    "gr" #'xref-find-references
    "]d" #'flymake-goto-next-error
    "[d" #'flymake-goto-prev-error))

;; Keep type information out of the echo area; K opens it at point.
(defun lang-hide-eldoc-echo-area ()
  "Hide automatic Eldoc messages in managed buffers."
  (setq-local eldoc-display-functions
              (remq 'eldoc-display-in-echo-area eldoc-display-functions)))

(use-package eldoc-box
  :after eglot
  :hook (eglot-managed-mode . lang-hide-eldoc-echo-area)
  :custom
  (eldoc-box-clear-with-C-g t)
  (eldoc-box-max-pixel-width 700)
  (eldoc-box-max-pixel-height 420))

;; SPC l f uses the language server; SPC f b uses Apheleia and Prettier for TS.
(use-package apheleia
  :commands (apheleia-format-buffer apheleia-mode)
  :config
  (setf (alist-get 'python-ts-mode apheleia-mode-alist) '(ruff-isort ruff))
  (setf (alist-get 'lua-ts-mode apheleia-mode-alist) 'stylua))

(defun toggle-format-on-save ()
  "Toggle format on save in the current buffer."
  (interactive)
  (apheleia-mode 'toggle)
  (message "Format on save %s" (if apheleia-mode "on" "off")))

;;; Keybindings

(leader
  "l"  '(:ignore t :wk "lsp")
  "lr" '(eglot-rename :wk "rename")
  "la" '(eglot-code-actions :wk "code action")
  "lf" '(eglot-format :wk "format (server)")
  "li" '(lang-install-lsp-server :wk "install server")
  "lR" '(eglot-reconnect :wk "reconnect"))
