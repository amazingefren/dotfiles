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

(use-package mise
  :hook (after-init . global-mise-mode))

(declare-function eglot-ensure "eglot")
(declare-function mise-update-dir "mise")
(declare-function eldoc-box-help-at-point "eldoc-box")
(declare-function eldoc-box-quit-frame "eldoc-box")

(defun lang-show-documentation ()
  "Show documentation at point in a child frame, or focus it when shown."
  (interactive)
  (eldoc-box-help-at-point)
  ;; Non-interactive: refreshes the popup without opening the *eldoc* split.
  (eldoc))

(defun lang-eldoc-box-quit-keys (_source-buffer)
  "Bind q, Escape and C-g in the documentation popup to close it."
  (dolist (key '("q" "<escape>" "C-g"))
    (evil-local-set-key 'normal (kbd key) #'eldoc-box-quit-frame)))

(defun lang-install-lsp-servers ()
  "Install the language servers in mise's conf.d/emacs.toml with `mise install'.
Then refreshes every buffer's mise environment and starts Eglot in this buffer."
  (interactive)
  (let ((source-buffer (current-buffer))
        (buffer (compilation-start "mise install" 'compilation-mode (lambda (_mode) "*mise install*"))))
    (with-current-buffer buffer
      (add-hook 'compilation-finish-functions
                (lambda (_buffer status)
                  (when (string-prefix-p "finished" status)
                    (mise-update-dir t)
                    (when (buffer-live-p source-buffer)
                      (with-current-buffer source-buffer
                        (eglot-ensure)))))
                nil t))))

(define-derived-mode lang-vue-mode mhtml-ts-mode "Vue"
  "Major mode for Vue single-file components.")

(add-to-list 'auto-mode-alist '("\\.vue\\'" . lang-vue-mode))

(defun lang-vue-server-contact (&rest _)
  "Return the Eglot contact for vue-language-server with the project's TypeScript.
Signals a `user-error' when the project has no node_modules/typescript."
  (let ((tsdk (expand-file-name "node_modules/typescript/lib" (project-root (project-current t)))))
    (unless (file-directory-p tsdk)
      (user-error "vue-language-server needs TypeScript at %s" tsdk))
    `("vue-language-server" "--stdio"
      :initializationOptions (:typescript (:tsdk ,tsdk) :vue (:hybridMode :json-false)))))

(use-package eglot
  :ensure nil
  :hook ((typescript-ts-mode tsx-ts-mode js-ts-mode python-ts-mode go-ts-mode rust-ts-mode lua-ts-mode
          bash-ts-mode php-ts-mode css-ts-mode scss-mode json-ts-mode
          mhtml-ts-mode)                ; lang-vue-mode derives from it
         . eglot-ensure)
  :custom
  (eglot-autoshutdown t)
  (eglot-events-buffer-config '(:size 0))
  (eglot-code-action-indications '(left-fringe))
  :config
  (add-to-list 'eglot-server-programs '((lua-mode lua-ts-mode) . ("lua-language-server")))
  (add-to-list 'eglot-server-programs '((php-mode php-ts-mode) . ("intelephense" "--stdio")))
  (add-to-list 'eglot-server-programs '((scss-mode :language-id "scss") . ("vscode-css-language-server" "--stdio")))
  (add-to-list 'eglot-server-programs '((mhtml-ts-mode html-ts-mode) . ("vscode-html-language-server" "--stdio")))
  ;; After the HTML entry: Eglot takes the first match, and lang-vue-mode derives from mhtml-ts-mode.
  (add-to-list 'eglot-server-programs '(lang-vue-mode . lang-vue-server-contact))
  (setq evil-lookup-func #'lang-show-documentation)
  (evil-define-key 'normal eglot-mode-map
    "K" #'lang-show-documentation
    "gr" #'xref-find-references
    "]d" #'flymake-goto-next-error
    "[d" #'flymake-goto-prev-error))

(defun lang-hide-eldoc-echo-area ()
  "Hide automatic Eldoc messages in managed buffers."
  (setq-local eldoc-display-functions
              (remq 'eldoc-display-in-echo-area eldoc-display-functions)))

(use-package eldoc-box
  :after eglot
  :hook ((eglot-managed-mode . lang-hide-eldoc-echo-area)
         (eldoc-box-buffer-setup . lang-eldoc-box-quit-keys))
  :custom
  (eldoc-box-clear-with-C-g t)
  (eldoc-box-max-pixel-width 700)
  (eldoc-box-max-pixel-height 420)
  :config
  ;; global-tab-line-mode turns tab-line-mode on in each new buffer, and this hook deletes the popup.
  (remove-hook 'tab-line-mode-hook #'eldoc-box-reset-frame)
  (setf (alist-get 'cursor-type eldoc-box-frame-parameters) 'box))

(use-package flymake
  :ensure nil
  :custom
  (flymake-show-diagnostics-at-end-of-line 'short))

(use-package apheleia
  :commands (apheleia-format-buffer apheleia-mode)
  :config
  (setf (alist-get 'python-ts-mode apheleia-mode-alist) '(ruff-isort ruff))
  (setf (alist-get 'lua-ts-mode apheleia-mode-alist) 'stylua)
  ;; mhtml-ts-mode also derives from css-mode, which apheleia would match first.
  (setf (alist-get 'mhtml-ts-mode apheleia-mode-alist) 'prettier-html)
  (setf (alist-get 'lang-vue-mode apheleia-mode-alist) 'prettier))

(defun toggle-format-on-save ()
  "Toggle format on save in the current buffer."
  (interactive)
  (apheleia-mode 'toggle)
  (message "Format on save %s" (if apheleia-mode "on" "off")))

(leader
  "l"  '(:ignore t :wk "lsp")
  "lr" '(eglot-rename :wk "rename")
  "la" '(eglot-code-actions :wk "code action")
  "lf" '(eglot-format :wk "format (server)")
  "li" '(lang-install-lsp-servers :wk "install servers")
  "lR" '(eglot-reconnect :wk "reconnect"))
