;;; packages.el --- package lifecycle and native compilation  -*- lexical-binding: t -*-

(require 'package)

(defun packages-prewarm-native-compilation ()
  "Queue native compilation for all installed packages."
  (interactive)
  (unless (native-comp-available-p)
    (user-error "This Emacs does not support native compilation"))
  (let ((dirs (delete-dups (mapcar (lambda (entry) (package-desc-dir (cadr entry))) package-alist)))
        (native-comp-async-jobs-number 1))
    (native-compile-async dirs t)
    (message "Queued native compilation for %d packages" (length dirs))))

(defun packages--compile-after-install (orig package &rest args)
  "Run ORIG and queue compilation of its installed package."
  (let ((desc (apply orig package args)))
    (when (and (native-comp-available-p) (package-desc-p desc))
      (let ((native-comp-async-jobs-number 1))
        (native-compile-async (package-desc-dir desc) t)))
    desc))

(advice-add 'package-install :around #'packages--compile-after-install)
(when (fboundp 'package-vc-install)
  (advice-add 'package-vc-install :around #'packages--compile-after-install))
