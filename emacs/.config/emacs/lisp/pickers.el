;;; pickers.el --- minibuffer navigation and completion  -*- lexical-binding: t -*-

;; Vertical candidate list in the minibuffer.
(use-package vertico
  :custom (vertico-cycle t)                    ; wrap around at the ends
  :bind (:map vertico-map
              ("C-j" . vertico-next)
              ("C-k" . vertico-previous))
  :init (vertico-mode 1))

;; Fuzzy matching: type space-separated words in any order.
(use-package orderless
  :custom
  (completion-styles '(orderless basic))
  (completion-category-defaults nil)
  ;; File paths at a plain find-file prompt still complete segment by segment;
  ;; project file lists are fuzzy (see `orderless-fuzzy' below).
  (completion-category-overrides '((file (styles partial-completion))
                                   (project-file (styles orderless-fuzzy))))
  :config
  ;; fzf-style matching: "vmel" finds lisp/vim.el. Characters in order,
  ;; anything in between. Used for project file picking only; elsewhere the
  ;; default space-separated substrings are less noisy.
  (orderless-define-completion-style orderless-fuzzy
    (orderless-matching-styles '(orderless-flex))))

;; Annotations next to candidates (docstrings, file sizes, key bindings...).
(use-package marginalia
  :init (marginalia-mode 1))

;; A .project marker makes a directory a project.
(use-package project
  :ensure nil
  :custom
  (project-vc-extra-root-markers '(".project")))

;; consult-fd runs nothing until you type a pattern. Make an empty pattern
;; list every file, like a Neovim file picker, so SPC f f shows results at once.
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

;; The search commands: consult-buffer, consult-line, consult-ripgrep, consult-fd.
(use-package consult
  :commands (consult-fd consult-ripgrep consult-buffer consult-line)
  :custom
  (consult-async-min-input 0)                  ; list results before anything is typed (fd streams the whole tree)
  ;; consult's default: type plainly and the whole line goes to the tool (rg, fd,
  ;; Spotify). Optionally "#pattern#filter" sends the first part to the tool and
  ;; filters the results in Emacs with the second.
  (consult-async-split-style 'perl)
  ;; Search hidden files too (the emacs config lives under emacs/.config/), but
  ;; never inside .git. .gitignore is still respected.
  (consult-ripgrep-args "rg --null --line-buffered --color=never --max-columns=1000 --path-separator / --smart-case --no-heading --with-filename --line-number --search-zip --hidden --glob !.git")
  (consult-fd-args '("fd" "--full-path" "--color=never" "--hidden" "--exclude" ".git" "--exclude" "Library" "--exclude" "node_modules"))
  (consult-narrow-key "<")                     ; press < then a letter to filter by type
  (xref-show-xrefs-function #'consult-xref)    ; go-to-definition / references results in the picker
  (xref-show-definitions-function #'consult-xref)
  :config
  ;; SPC f g. In visual mode the selection becomes the initial query.
  (defun project-ripgrep ()
    "Ripgrep the workspace root. In visual state the selection is the initial query.
C-u asks for a directory instead."
    (interactive)
    (let ((initial (when (use-region-p)
                     (buffer-substring-no-properties (region-beginning) (region-end)))))
      (deactivate-mark)
      (consult-ripgrep (if current-prefix-arg nil (workspace-root)) initial))))

;; Context actions on the thing at point or the current picker candidate.
;; C-. in a picker shows what you can do with the highlighted item.
(use-package embark
  :bind (("C-." . embark-act)
         ("C-;" . embark-dwim))
  :custom (prefix-help-command #'embark-prefix-help-command)) ; C-h after a prefix lists keys in a picker

;; Glue so embark actions understand consult results.
(use-package embark-consult
  :after (embark consult)
  :hook (embark-collect-mode . consult-preview-at-point-mode))

;; corfu: the in-buffer completion popup (what blink.cmp / nvim-cmp do).
;; Sources come from LSP (via eglot) plus whatever cape adds below.
(use-package corfu
  :custom
  (corfu-auto t)                    ; pop up automatically...
  (corfu-auto-prefix 2)             ; ...after 2 characters...
  (corfu-auto-delay 0.1)            ; ...and 0.1s
  (corfu-cycle t)
  :bind (:map corfu-map
              ("TAB"     . corfu-next)
              ([tab]     . corfu-next)
              ("S-TAB"   . corfu-previous)
              ([backtab] . corfu-previous))
  :init
  (global-corfu-mode 1)
  :config
  (corfu-popupinfo-mode 1))         ; show docs for the selected candidate

;; Extra completion sources for corfu.
(use-package cape
  :init
  (add-hook 'completion-at-point-functions #'cape-file)     ; file paths
  (add-hook 'completion-at-point-functions #'cape-dabbrev)) ; words from open buffers
