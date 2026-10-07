;;; dwm.el --- dwm-style master and stack tiling -*- lexical-binding: t -*-

;; `dwm-mode' tiles each frame's non-side windows: the master on the left
;; and the rest stacked on the right.  A new window becomes the master.
;; Side windows are left alone.
;;
;; Buffers that visit files or directories open in the most recently used
;; editing window: a tiled, undedicated window showing such a buffer.
;; Without one they open in the selected window, or a new one when the
;; selected window is dedicated.  With `dwm-pick-window', a command that
;; could use several tiled, undedicated windows asks which one.  Buffers matching `dwm-view-buffers' get
;; a new window dedicated to them.
;; Buffers matching `dwm-float-buffers' open in a floating child frame
;; that tiles on its own and closes on quit.

(require 'seq)

(defgroup dwm nil
  "Master and stack window tiling."
  :group 'windows
  :prefix "dwm-")

(defcustom dwm-master-factor 0.55
  "Fraction of the tiled area's width given to the master window."
  :type 'number)

(defcustom dwm-float-buffers nil
  "Condition, as for `buffer-match-p', for buffers shown in a floating frame."
  :type 'sexp)

(defcustom dwm-pick-window t
  "Non-nil: ask which window a file or directory opens in when several could take it.
Only commands ask, and not from a floating frame or a minibuffer.  Timers,
process output, `post-command-hook' and `dwm-pick-ignored-commands' take the
most recently used editing window."
  :type 'boolean)

(defcustom dwm-pick-ignored-commands
  '(compilation-display-error dired-display-file next-error-no-select occur-mode-display-occurrence
    org-agenda-next-line org-agenda-previous-line org-agenda-show org-agenda-show-and-scroll-up
    previous-error-no-select xref-next-group xref-next-line xref-prev-group xref-prev-line
    xref-show-location-at-point)
  "Commands that only preview a buffer, for which `dwm-pick-window' never asks."
  :type '(repeat symbol))

(defcustom dwm-pick-keys "asdfghjkl"
  "Keys labelling windows for `dwm-pick-window', in window order."
  :type 'string)

(defface dwm-pick-label '((t :inherit isearch :weight bold :height 2.5))
  "Label drawn on each window `dwm-pick-window' offers.")

(defcustom dwm-view-buffers nil
  "Condition, as for `buffer-match-p', for buffers shown in a dedicated window."
  :type 'sexp)

(defconst dwm--conditions '(dwm--editing-p dwm--float-p dwm--view-p)
  "The `display-buffer-alist' conditions that `dwm-mode' adds.")

(defvar dwm--in-command nil
  "Non-nil while `command-execute' runs a command.")

(defconst dwm--float-frame-parameters
  '((auto-hide-function . dwm--delete-selected-float)
    (child-frame-border-width . 2)
    (dwm-float . t)
    (keep-ratio . t)
    (menu-bar-lines . 0)
    (no-other-frame . t)
    (skip-taskbar . t)
    (tab-bar-lines . 0)
    (tool-bar-lines . 0)
    (undecorated . t)
    (vertical-scroll-bars . nil)
    (visibility . nil))
  "Frame parameters of a floating frame.")

;;;###autoload
(define-minor-mode dwm-mode
  "Tile windows as a master and a stack, and float `dwm-float-buffers'."
  :global t
  (let ((base-functions (remq #'dwm-display-buffer
                              (ensure-list (car display-buffer-base-action)))))
    (setq display-buffer-alist
          (seq-remove (lambda (entry) (memq (car entry) dwm--conditions)) display-buffer-alist))
    (remove-hook 'window-configuration-change-hook #'dwm--arrange-selected-frame)
    (remove-hook 'delete-frame-functions #'dwm--focus-float-parent)
    (advice-remove 'command-execute #'dwm--run-command)
    (when dwm-mode
      (push '(dwm--editing-p dwm-display-buffer-in-editing-window) display-buffer-alist)
      (push '(dwm--view-p dwm-display-buffer-in-view) display-buffer-alist)
      (push '(dwm--float-p dwm-display-buffer-in-float) display-buffer-alist)
      (setq base-functions (cons #'dwm-display-buffer base-functions))
      (add-hook 'window-configuration-change-hook #'dwm--arrange-selected-frame)
      (add-hook 'delete-frame-functions #'dwm--focus-float-parent)
      (advice-add 'command-execute :around #'dwm--run-command)
      (dwm--arrange (selected-frame)))
    (setq display-buffer-base-action (cons base-functions (cdr display-buffer-base-action)))))

(defun dwm-display-buffer (buffer alist)
  "Show BUFFER in a window that is visible, editing or new, per ALIST.
A buffer that visits a file or directory takes the most recently used
editing window.  A new window becomes the master.  Return the window, or
nil when the selected frame is not tiling or has no room for another."
  (or (display-buffer-reuse-window buffer alist)
      (and (dwm--editing-buffer-p buffer) (dwm--display-in-editing-window buffer alist))
      (dwm--display-in-new-window buffer alist)))

(defun dwm-display-buffer-in-editing-window (buffer alist)
  "Show BUFFER in an editing window of the selected frame, per ALIST.
Close a selected floating frame first and use its parent.  Without an
editing window, use the selected window unless it is dedicated or ALIST
inhibits it, and else a new window.  Return the window, or nil when
there is no room for one."
  (let ((from-float (frame-parameter nil 'dwm-float)))
    (when from-float
      (let ((float (selected-frame)))
        (select-frame-set-input-focus (frame-parent float))
        (delete-frame float)))
    ;; The float is gone by now, so a quit at the picker would show nothing.
    (let ((dwm-pick-window (and dwm-pick-window (not from-float))))
      (or (display-buffer-reuse-window buffer alist)
          (dwm--display-in-editing-window buffer alist)
          (and (dwm--free-window-p (selected-window))
               (not (alist-get 'inhibit-same-window alist))
               (window--display-buffer buffer (selected-window) 'reuse alist))
          (dwm--display-in-new-window buffer alist)))))

(defun dwm-display-buffer-in-float (buffer alist)
  "Show BUFFER in the selected frame's floating frame, per ALIST.
Make the floating frame when there is none.  Return its window."
  (let* ((parent (selected-frame))
         (float (seq-find (lambda (frame) (and (eq (frame-parent frame) parent)
                                               (frame-parameter frame 'dwm-float)))
                          (frame-list)))
         (window (if float
                     (frame-selected-window float)
                   (frame-selected-window (dwm--make-float parent)))))
    (prog1 (window--display-buffer buffer window (if float 'reuse 'frame) alist)
      (select-frame-set-input-focus (window-frame window)))))

(defun dwm-display-buffer-in-view (buffer alist)
  "Show BUFFER in a window of its own and dedicate the window to it, per ALIST.
Return the window, or nil when there is no room for a new one."
  (when-let* ((window (or (display-buffer-reuse-window buffer alist)
                          (dwm--display-in-new-window buffer alist))))
    (set-window-dedicated-p window t)
    window))

(defun dwm-focus-next (&optional count)
  "Select the COUNTth tiled window after the selected one, wrapping around.
From a window that is not tiled, count from before the master."
  (interactive "p")
  (let* ((count (or count 1))
         (windows (dwm--tiled-windows (selected-frame)))
         (position (seq-position windows (selected-window)))
         (target (cond (position (+ position count))
                       ((> count 0) (1- count))
                       (t count))))
    (select-window (nth (mod target (length windows)) windows))))

(defun dwm-focus-previous (&optional count)
  "Select the COUNTth tiled window before the selected one, wrapping around."
  (interactive "p")
  (dwm-focus-next (- (or count 1))))

(defun dwm-grow-master (&optional count)
  "Widen the master by COUNT twentieths of the tiled area and re-tile.
The master keeps between a tenth and nine tenths of the width.  Signal
a `user-error' when the selected frame is not tiling."
  (interactive "p")
  (let* ((count (or count 1))
         (frame (selected-frame))
         (windows (dwm--tiled-windows frame)))
    (when (dwm--suspended-p frame windows)
      (user-error "Frame %s is not tiling" frame))
    (setq dwm-master-factor (min 0.9 (max 0.1 (+ dwm-master-factor (* 0.05 count)))))
    (dwm--tile frame windows)))

(defun dwm-set-master (window)
  "Re-tile WINDOW's frame with WINDOW as the master, keeping the others' order.
Signal a `user-error' when WINDOW is not tiled or its frame is not tiling."
  (let* ((frame (window-frame window))
         (windows (dwm--tiled-windows frame)))
    (unless (memq window windows)
      (user-error "Window %s is not tiled" window))
    (when (dwm--suspended-p frame windows)
      (user-error "Frame %s is not tiling" frame))
    (dwm--tile frame (cons window (remq window windows)))))

(defun dwm-shrink-master (&optional count)
  "Narrow the master by COUNT twentieths of the tiled area and re-tile."
  (interactive "p")
  (dwm-grow-master (- (or count 1))))

(defun dwm-zoom ()
  "Swap the selected window with the master and select the new master.
From the master, swap with the window that last took the master's place,
or else the top of the stack.  Signal a `user-error' when the selected
window is not tiled or is alone."
  (interactive)
  (let* ((frame (selected-frame))
         (windows (dwm--tiled-windows frame))
         (master (car windows))
         (selected (selected-window))
         (last-swapped (frame-parameter frame 'dwm-last-swapped))
         (target (cond ((not (eq selected master)) selected)
                       ((memq last-swapped (cdr windows)) last-swapped)
                       (t (cadr windows)))))
    (unless (memq selected windows)
      (user-error "Window %s is not tiled" selected))
    (unless target
      (user-error "No window to swap with the master"))
    (dwm--tile frame (mapcar (lambda (window)
                               (cond ((eq window master) target)
                                     ((eq window target) master)
                                     (t window)))
                             windows))
    (set-frame-parameter frame 'dwm-last-swapped master)
    (select-window target)))

(defun dwm--float-p (buffer-name _action)
  "Return non-nil if BUFFER-NAME should open in a floating frame.
Inside a floating frame, buffers tile there instead."
  (and (not (frame-parameter nil 'dwm-float))
       (buffer-match-p dwm-float-buffers buffer-name)))

(defun dwm--view-p (buffer-name _action)
  "Return non-nil if BUFFER-NAME matches `dwm-view-buffers'."
  (buffer-match-p dwm-view-buffers buffer-name))

(defun dwm--editing-p (buffer-name _action)
  "Return non-nil if BUFFER-NAME visits a file or directory from elsewhere.
Elsewhere is any window that is not an editing window or an undedicated
side window."
  (let ((window (selected-window)))
    (and (dwm--editing-buffer-p (get-buffer buffer-name))
         (not (dwm--editing-window-p window))
         (not (and (window-parameter window 'window-side)
                   (not (window-dedicated-p window)))))))

(defun dwm--editing-buffer-p (buffer)
  "Return non-nil if BUFFER visits a file or a directory."
  (with-current-buffer buffer
    (or buffer-file-name (derived-mode-p 'dired-mode))))

(defun dwm--editing-window-p (window)
  "Return non-nil if WINDOW is free and shows a file or directory."
  (and (dwm--free-window-p window)
       (dwm--editing-buffer-p (window-buffer window))))

(defun dwm--free-window-p (window)
  "Return non-nil if WINDOW is tiled, undedicated and not in a floating frame."
  (not (or (window-minibuffer-p window)
           (window-parameter window 'window-side)
           (window-dedicated-p window)
           (frame-parameter (window-frame window) 'dwm-float))))

(defun dwm--display-in-editing-window (buffer alist)
  "Show BUFFER in the selected frame's most recently used editing window.
Skip the selected window when ALIST inhibits it.  When `dwm-pick-window'
applies and several tiled, undedicated windows could take BUFFER, ask
which.  Return the window, or nil when there is none."
  (let* ((selected (selected-window))
         (excluded (and (or (alist-get 'inhibit-same-window alist)
                            (not (dwm--editing-window-p selected)))
                        selected))
         (free (seq-filter (lambda (window) (and (not (eq window excluded)) (dwm--free-window-p window)))
                           (dwm--tiled-windows (selected-frame))))
         (recent (car (seq-sort-by #'window-use-time #'>
                                   (seq-filter #'dwm--editing-window-p free))))
         (window (if (and (cdr free) (dwm--asking-p))
                     (dwm--pick-window free (or recent (car free)))
                   recent)))
    (when window
      (window--display-buffer buffer window 'reuse alist))))

(defun dwm--asking-p ()
  "Returns non-nil when a window choice may be asked of the user now."
  (and dwm-pick-window dwm--in-command
       ;; Timers and process output run with quitting inhibited.
       (not inhibit-quit)
       (not (memq this-command dwm-pick-ignored-commands))
       (zerop (minibuffer-depth))))

(defun dwm--pick-window (windows default)
  "Labels WINDOWS with `dwm-pick-keys' and returns the one whose key is pressed.
RET or SPC returns DEFAULT.  Windows beyond the available keys are not
offered.  Signals `quit' on C-g or ESC."
  (let* ((pairs (seq-mapn #'cons dwm-pick-keys windows))
         (overlays (mapcar (lambda (pair) (dwm--pick-label (car pair) (cdr pair))) pairs))
         (prompt (format "Open in window (%s, RET default): "
                         (mapconcat (lambda (pair) (string (car pair))) pairs " ")))
         choice)
    (unwind-protect
        (while (not choice)
          (let ((key (read-key prompt)))
            (cond ((memq key '(?\r ?\s return)) (setq choice default))
                  ((memq key '(?\C-g ?\e escape)) (signal 'quit nil))
                  (t (setq choice (alist-get key pairs))))))
      (mapc #'delete-overlay overlays))
    choice))

(defun dwm--pick-label (key window)
  "Draws KEY over the top of WINDOW and returns the overlay."
  (with-current-buffer (window-buffer window)
    (let ((overlay (make-overlay (window-start window) (window-start window))))
      (overlay-put overlay 'window window)
      (overlay-put overlay 'before-string (propertize (format " %c " key) 'face 'dwm-pick-label))
      overlay)))

(defun dwm--run-command (command-execute &rest args)
  "Calls COMMAND-EXECUTE with ARGS while marking that a command runs."
  (let ((dwm--in-command t))
    (apply command-execute args)))

(defun dwm--display-in-new-window (buffer alist)
  "Show BUFFER in a new tiled window that becomes the master, per ALIST.
Return the window, or nil when the selected frame is not tiling or has
no room for another window."
  (let* ((frame (selected-frame))
         (windows (dwm--tiled-windows frame)))
    (unless (or (dwm--suspended-p frame windows)
                (not (dwm--room-p frame (1+ (length windows)))))
      (let ((window (split-window (window-main-window frame) (- window-min-height) 'below)))
        (prog1 (window--display-buffer buffer window 'window alist)
          (dwm--arrange frame window))))))

(defun dwm--make-float (parent)
  "Show a new floating frame over PARENT, centered at 80% of its size.
Return the frame."
  (let* ((frame (make-frame `((minibuffer . ,(minibuffer-window parent))
                              (parent-frame . ,parent)
                              ,@dwm--float-frame-parameters)))
         (edges (frame-edges frame 'outer-edges))
         (decoration-width (- (nth 2 edges) (nth 0 edges) (frame-text-width frame)))
         (decoration-height (- (nth 3 edges) (nth 1 edges) (frame-text-height frame)))
         (width (round (* 0.8 (frame-native-width parent))))
         (height (round (* 0.8 (frame-native-height parent)))))
    (set-frame-size frame (- width decoration-width) (- height decoration-height) t)
    (set-frame-position frame
                        (/ (- (frame-native-width parent) width) 2)
                        (/ (- (frame-native-height parent) height) 2))
    (make-frame-visible frame)
    frame))

(defun dwm--delete-selected-float ()
  "Delete the selected frame if it is floating."
  (when (frame-parameter nil 'dwm-float)
    (delete-frame)))

(defun dwm--focus-float-parent (frame)
  "Select FRAME's parent if FRAME is a selected floating frame being deleted."
  (when (and (frame-parameter frame 'dwm-float) (eq frame (selected-frame)))
    (select-frame-set-input-focus (frame-parent frame))))

(defun dwm--arrange-selected-frame ()
  "Arrange the selected frame, which `window-configuration-change-hook' binds."
  (dwm--arrange (selected-frame)))

(defun dwm--arrange (frame &optional master)
  "Tile FRAME's windows unless they already are and none is new.
MASTER, or else any window not tiled before, goes first.  Leave FRAME
alone while it is suspended or too small."
  (let* ((windows (dwm--tiled-windows frame))
         (known (frame-parameter frame 'dwm-windows))
         (fresh (cond (master (list master))
                      (known (seq-difference windows known)))))
    (cond ((or (dwm--suspended-p frame windows)
               (not (dwm--room-p frame (length windows)))))
          ((and (null fresh) (dwm--tiled-p windows))
           (unless (equal windows known)
             (set-frame-parameter frame 'dwm-windows windows)))
          (t (dwm--tile frame (append fresh (seq-difference windows fresh)))))))

(defun dwm--tile (frame order)
  "Rebuild FRAME's tiled area from the live windows in ORDER.
The first is the master on the left, the rest stack top to bottom on
the right.  Windows keep their identity, buffers and parameters."
  (let ((selected (frame-selected-window frame))
        (master (car order))
        (stack (cdr order))
        (window-combination-resize nil)
        (window-combination-limit nil))
    (dolist (window stack)
      (delete-window window))
    (when stack
      (let ((above (split-window master (round (* dwm-master-factor (window-total-width master)))
                                 'right nil (car stack)))
            (remaining (length stack)))
        (dolist (window (cdr stack))
          (setq above (split-window above (/ (window-total-height above) remaining)
                                    'below nil window))
          (setq remaining (1- remaining)))))
    (set-frame-selected-window frame selected 'norecord)
    (set-frame-parameter frame 'dwm-windows order)))

(defun dwm--tiled-windows (frame)
  "Return FRAME's non-side windows, master first, then the stack from the top."
  (seq-remove (lambda (window) (window-parameter window 'window-side))
              (window-list frame 'nomini (frame-first-window frame))))

(defun dwm--tiled-p (windows)
  "Return non-nil if WINDOWS form a master beside a vertical stack."
  (let* ((master (car windows))
         (stack (window-next-sibling master))
         (parent (window-parent master)))
    (or (null (cdr windows))
        (and (window-combined-p master t)
             (eq (window-child parent) master)
             (= (window-child-count parent) 2)
             (if (window-live-p stack)
                 (null (cddr windows))
               (and (window-combined-p (window-child stack))
                    (= (window-child-count stack) (length (cdr windows)))
                    (seq-every-p #'window-live-p (cdr windows))
                    (seq-every-p (lambda (window) (eq (window-parent window) stack))
                                 (cdr windows))))))))

(defun dwm--suspended-p (frame windows)
  "Return non-nil if FRAME's tiled WINDOWS must keep their layout.
That is when FRAME is unsplittable or a window is atomic, fixed-size or
shows a buffer that `display-buffer-alist' places."
  (or (frame-parameter frame 'unsplittable)
      (seq-some (lambda (window)
                  (or (window-parameter window 'window-atom)
                      (window-fixed-size-p window)
                      (dwm--placed-p (window-buffer window))))
                windows)))

(defun dwm--placed-p (buffer)
  "Return non-nil if a `display-buffer-alist' entry not from dwm matches BUFFER."
  (seq-some (lambda (entry)
              (and (not (memq (car entry) dwm--conditions))
                   (buffer-match-p (car entry) (buffer-name buffer) nil)))
            display-buffer-alist))

(defun dwm--room-p (frame count)
  "Return non-nil if FRAME's tiled area fits COUNT windows."
  (let ((main (window-main-window frame)))
    (or (< count 2)
        (and (<= (* 2 window-min-width) (window-total-width main))
             (<= (* (1- count) window-min-height) (window-total-height main))))))

(provide 'dwm)
;;; dwm.el ends here
