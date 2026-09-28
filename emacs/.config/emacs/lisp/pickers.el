;;; pickers.el --- minibuffer navigation and completion  -*- lexical-binding: t -*-

(use-package vertico
  :custom (vertico-cycle t)
  :bind (:map vertico-map
              ("C-j" . vertico-next)
              ("C-k" . vertico-previous))
  :init (vertico-mode 1))

(use-package orderless
  :custom
  (completion-styles '(orderless basic))
  (completion-category-defaults nil)
  (completion-category-overrides '((file (styles partial-completion))
                                   (project-file (styles orderless-fuzzy))))
  :config
  ;; Project files only; elsewhere flex matching is too noisy.
  (orderless-define-completion-style orderless-fuzzy
    (orderless-matching-styles '(orderless-flex))))

(use-package marginalia
  :init (marginalia-mode 1))

(use-package project
  :ensure nil
  :custom
  (project-vc-extra-root-markers '(".project")))

;; consult-fd runs nothing until you type a pattern.
(defun consult-fd-list-all-when-empty (orig paths)
  (let ((builder (funcall orig paths)))
    (lambda (input)
      (pcase-let ((`(,arg . ,opts) (consult--command-split input)))
        (if (string-empty-p arg)
            (cons (append (consult--build-args consult-fd-args) opts
                          (mapcan (lambda (x) `("--search-path" ,x)) paths))
                  nil)
          (funcall builder input))))))
(advice-add 'consult--fd-make-builder :around #'consult-fd-list-all-when-empty)

(defun find-file-dwim ()
  "Find a file under the workspace root (see `workspace-root').
Inside a git repo: the full file list, fuzzy-matched (\"vmel\" finds
lisp/vim.el). Elsewhere, e.g. $HOME: fd, streaming asynchronously so a huge
tree never blocks Emacs. C-u asks for a directory instead."
  (interactive)
  (let ((root (workspace-root)))
    (cond
     (current-prefix-arg (call-interactively #'consult-fd))
     ((let ((project-find-functions '(project-try-vc))) (project-current nil root))
      (let ((default-directory root))
        (project-find-file-in nil (list root) (project-current nil root))))
     (t (consult-fd root)))))

(use-package consult
  :commands (consult-fd consult-ripgrep consult-buffer consult-line)
  :custom
  (consult-async-min-input 0)
  ;; "#pattern#filter": the tool gets pattern, Emacs filters its results by filter.
  (consult-async-split-style 'perl)
  ;; --hidden because this config lives under emacs/.config/.
  (consult-ripgrep-args "rg --null --line-buffered --color=never --max-columns=1000 --path-separator / --smart-case --no-heading --with-filename --line-number --search-zip --hidden --glob !.git")
  (consult-fd-args '("fd" "--full-path" "--color=never" "--hidden" "--exclude" ".git" "--exclude" "Library" "--exclude" "node_modules"))
  (consult-narrow-key "<")
  (xref-show-xrefs-function #'consult-xref)
  (xref-show-definitions-function #'consult-xref)
  :config
  (defun project-ripgrep ()
    "Ripgrep the workspace root. In visual state the selection is the initial query.
C-u asks for a directory instead."
    (interactive)
    (let ((initial (when (use-region-p)
                     (buffer-substring-no-properties (region-beginning) (region-end)))))
      (deactivate-mark)
      (consult-ripgrep (if current-prefix-arg nil (workspace-root)) initial))))

(use-package embark
  :bind (("C-." . embark-act)
         ("C-;" . embark-dwim))
  :custom (prefix-help-command #'embark-prefix-help-command))

(use-package embark-consult
  :after (embark consult)
  :hook (embark-collect-mode . consult-preview-at-point-mode))

(use-package corfu
  :custom
  (corfu-auto t)
  (corfu-auto-prefix 2)
  (corfu-auto-delay 0.1)
  (corfu-cycle t)
  :bind (:map corfu-map
              ("TAB"     . corfu-next)
              ([tab]     . corfu-next)
              ("S-TAB"   . corfu-previous)
              ([backtab] . corfu-previous))
  :init
  (global-corfu-mode 1)
  :config
  (corfu-popupinfo-mode 1))

(use-package cape
  :init
  (add-hook 'completion-at-point-functions #'cape-file)
  (add-hook 'completion-at-point-functions #'cape-dabbrev))
