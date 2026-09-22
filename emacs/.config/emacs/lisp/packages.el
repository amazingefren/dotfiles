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

;; Upgrades come from MELPA, which changes daily, and package.el has no
;; lockfile.  Snapshot the package directory first so a bad upgrade can be
;; undone.
(defvar packages-snapshot-directory
  (expand-file-name "emacs/elpa-snapshots/" (xdg-data-home))
  "Where `packages-upgrade-with-rollback' keeps copies of `package-user-dir'.")

(defvar packages-snapshot-keep 3
  "How many package snapshots to keep.")

(defun packages--snapshots ()
  "Snapshot directories, newest first."
  (when (file-directory-p packages-snapshot-directory)
    (reverse (directory-files packages-snapshot-directory t "\\`[0-9]"))))

(defun packages--snapshot (&optional keep-all)
  "Copy `package-user-dir' into a new timestamped snapshot; return its path.
Older snapshots beyond `packages-snapshot-keep' are deleted unless KEEP-ALL."
  (let ((target (expand-file-name (format-time-string "%Y%m%d-%H%M%S-%3N")
                                  packages-snapshot-directory)))
    (make-directory packages-snapshot-directory t)
    (unless (zerop (call-process "cp" nil nil nil "-a"
                                 (directory-file-name package-user-dir) target))
      (user-error "Could not snapshot %s" package-user-dir))
    (unless keep-all
      (dolist (old (nthcdr packages-snapshot-keep (packages--snapshots)))
        (delete-directory old t)))
    target))

(defun packages-upgrade-with-rollback ()
  "Snapshot the installed packages, then upgrade them all.
If an upgrade breaks something, `packages-rollback' restores the snapshot."
  (interactive)
  (let ((snapshot (packages--snapshot)))
    (message "Packages saved to %s" (abbreviate-file-name snapshot))
    (call-interactively #'package-upgrade-all)
    (message "Upgrade done; M-x packages-rollback restores %s if needed"
             (file-name-nondirectory snapshot))))

(defun packages-rollback (snapshot)
  "Replace the installed packages with SNAPSHOT, then offer to restart Emacs.
The packages being replaced are kept as a snapshot of their own."
  (interactive
   (let ((snapshots (packages--snapshots)))
     (unless snapshots (user-error "No package snapshots in %s" packages-snapshot-directory))
     (list (completing-read "Restore packages from: "
                            (mapcar #'file-name-nondirectory snapshots) nil t nil nil
                            (file-name-nondirectory (car snapshots))))))
  (let ((source (expand-file-name snapshot packages-snapshot-directory))
        (current (directory-file-name package-user-dir)))
    (when (yes-or-no-p (format "Replace installed packages with snapshot %s? " snapshot))
      (packages--snapshot t)   ; pruning now could delete SNAPSHOT itself
      (delete-directory current t)
      (unless (zerop (call-process "cp" nil nil nil "-a" source current))
        (user-error "Restore failed; the previous packages are in the newest snapshot"))
      (if (yes-or-no-p "Packages restored.  Restart Emacs now to load them? ")
          (restart-emacs)
        (message "Packages restored; restart Emacs to load them")))))
