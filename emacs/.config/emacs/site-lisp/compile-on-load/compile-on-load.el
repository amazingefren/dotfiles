;;; compile-on-load.el --- byte-compile config Lisp as it loads  -*- lexical-binding: t -*-

;; `compile-on-load-mode' byte-compiles a .el file under
;; `user-emacs-directory' when `load' or `require' is about to read it and
;; its .elc is missing or older.  A file compiles after everything loaded
;; before it, so it sees those files' macros.  Set `load-prefer-newer' so
;; an edited .el wins over its stale .elc when compiling fails.
;;
;; The mode keeps these files out of native compilation: its async workers
;; compile without the config loaded, so macros from it become calls.

(require 'comp-run)
(require 'seq)

(defgroup compile-on-load nil
  "Byte-compile config Lisp as it loads."
  :group 'lisp
  :prefix "compile-on-load-")

(defcustom compile-on-load-excluded '("/init\\.el\\'" "/early-init\\.el\\'" "/tests/")
  "Regexps for files under `user-emacs-directory' that stay uncompiled."
  :type '(repeat regexp))

(defconst compile-on-load--file (or load-file-name buffer-file-name)
  "The file this library was loaded from.")

(defvar compile-on-load--compiling nil
  "Sources being compiled, outermost last.")

;;;###autoload
(define-minor-mode compile-on-load-mode
  "Byte-compile stale Lisp under `user-emacs-directory' before it loads."
  :global t
  (let ((native-deny (concat "\\`" (regexp-quote (expand-file-name user-emacs-directory)))))
    (if compile-on-load-mode
        (progn
          (add-to-list 'native-comp-jit-compilation-deny-list native-deny)
          (advice-add 'load :around #'compile-on-load--load)
          (advice-add 'require :around #'compile-on-load--require)
          (compile-on-load--compile (concat (file-name-sans-extension compile-on-load--file) ".el")))
      (setq native-comp-jit-compilation-deny-list (delete native-deny native-comp-jit-compilation-deny-list))
      (advice-remove 'load #'compile-on-load--load)
      (advice-remove 'require #'compile-on-load--require))))

(defun compile-on-load--load (orig file &rest args)
  "Compile FILE's source if stale, then call ORIG on FILE with ARGS.
An explicit .el FILE loads as its .elc when that is current."
  (let* ((nosuffix (nth 2 args))
         (explicit (string-suffix-p ".el" file))
         (source (locate-file (if explicit file (concat file ".el")) load-path)))
    (if (and source (compile-on-load--compile source) explicit (not nosuffix))
        (apply orig (file-name-sans-extension file) args)
      (apply orig file args))))

(defun compile-on-load--require (orig feature &optional filename noerror)
  "Compile FEATURE's source if stale, then call ORIG with FEATURE, FILENAME and NOERROR."
  (unless (featurep feature)
    (when-let* ((library (locate-library (or filename (symbol-name feature)))))
      (compile-on-load--compile (concat (file-name-sans-extension library) ".el"))))
  (funcall orig feature filename noerror))

(defun compile-on-load--compile (source)
  "Byte-compile SOURCE, an absolute .el path, when it is managed and stale.
Warnings go to *Compile-Log* without displaying it; a failure messages.
Returns non-nil when SOURCE is managed and its .elc is current."
  (when (compile-on-load--managed-p source)
    (let ((elc (concat source "c")))
      (when (and (file-newer-than-file-p source elc)
                 (not (member source compile-on-load--compiling)))
        (let ((compile-on-load--compiling (cons source compile-on-load--compiling))
              (load-path (cons (file-name-directory source) load-path))
              (display-buffer-overriding-action '(display-buffer-no-window (allow-no-window . t))))
          (unless (byte-compile-file source)
            (message "Compiling %s failed; see *Compile-Log*" source))))
      (file-newer-than-file-p elc source))))

(defun compile-on-load--managed-p (source)
  "Non-nil when SOURCE is an .el file under `user-emacs-directory' and not excluded."
  (and (string-suffix-p ".el" source)
       (string-prefix-p (expand-file-name user-emacs-directory) source)
       (not (seq-some (lambda (regexp) (string-match-p regexp source)) compile-on-load-excluded))))

(provide 'compile-on-load)
;;; compile-on-load.el ends here
