;;; editing.el --- indentation and basic editing behavior  -*- lexical-binding: t -*-

(use-package emacs
  :ensure nil
  :custom
  (indent-tabs-mode nil)
  (tab-width 2)
  (standard-indent 2)
  :config
  (electric-pair-mode 1)
  (delete-selection-mode 1)
  (pixel-scroll-precision-mode 1))

(use-package editorconfig
  :ensure nil
  :config
  (editorconfig-mode 1))

;; Infer an existing file's indentation when the project does not declare it.
(use-package dtrt-indent
  :custom
  (dtrt-indent-verbosity 0)
  (dtrt-indent-lighter nil)
  :config
  (add-to-list 'dtrt-indent-hook-generic-mapping-list '(t tab-width))
  (setf (alist-get 'typescript-ts-base-mode dtrt-indent-hook-mapping-list)
        '(javascript typescript-ts-indent-offset))
  (dtrt-indent-global-mode 1))

;; Eglot passes `tab-width' to TypeScript formatters as their tab size.
(defun editing-typescript-format-style (&optional _properties)
  "Use the TypeScript indentation width for formatter requests."
  (when (derived-mode-p 'typescript-ts-base-mode)
    (setq-local tab-width typescript-ts-indent-offset)))

(add-hook 'typescript-ts-mode-hook #'editing-typescript-format-style)
(add-hook 'tsx-ts-mode-hook #'editing-typescript-format-style)
(add-hook 'editorconfig-after-apply-functions #'editing-typescript-format-style)
