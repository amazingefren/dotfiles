;;; music.el --- Spotify via spot (consult-based)  -*- lexical-binding: t -*-
;;
;; spot (github.com/chiply/spot) searches Spotify through the same picker as
;; everything else: type, narrow, RET plays on your active device, C-. for
;; embark actions (play, queue, show album, add to playlist). It also puts the
;; current track in the mode line.
;;
;; Credentials come from 1Password the first time Spotify is used in a session
;; (see `secret-op'), never from this file. The refresh token is kept in an
;; encrypted plstore in the cache, so authorizing is a one-time thing.
;;
;;   SPC o s s   search tracks, albums, artists, playlists (shows etc. via -- --type=show)
;;   SPC o s l   my playlists          SPC o s +   add current track to a playlist
;;   SPC o s p   play    SPC o s P   pause    SPC o s n   next    SPC o s b   previous
;;   SPC o s d   pick the device to play on (asked automatically when none is active)
;;   In results: RET plays (or opens a playlist), C-. for more actions (queue, album, add to playlist)
;;   SPC o s a   authorize (first time only; paste the code from the browser's URL)
;;
;; In the search prompt, " -- --limit=10 --market=US" style args go after the query.

(use-package spot
  :vc (:url "https://github.com/chiply/spot" :rev :newest)
  :commands (spot-consult-search spot-consult-search-current-user-playlists
             spot-add-current-track-to-playlist spot-player-play spot-player-pause
             spot-player-next spot-player-previous spot-authorize spot-mode)
  :config
  ;; Spotify only allows plain http for the loopback IP; this is the URI
  ;; registered on the developer app. Nothing listens there: after approving,
  ;; the browser shows an error page whose address bar holds ?code=... to paste.
  (setq spot--redirect-uri (url-hexify-string "http://127.0.0.1:8080/smudge_api_callback"))

  ;; Development-mode apps get at most 10 results per type; spot asks for 20
  ;; and Spotify answers with nothing. Cap it unless the query sets its own.
  (define-advice spot--build-search-q-params (:filter-return (params) music-cap-limit)
    (if (string-match-p "limit=" params) params (concat params "&limit=10")))
  ;; Search only what I actually look for. Spotify's matching for shows,
  ;; episodes and audiobooks is loose enough to return "hospice care" for a
  ;; song title, and they crowd the list. "-- --type=show" still asks for them.
  (define-advice spot--build-search-q-params (:filter-return (params) music-default-types)
    (replace-regexp-in-string "&type=album,artist,playlist,track,show,episode,audiobook"
                              "&type=track,album,artist,playlist" params t t))

  ;; Spotify pads search results with null entries (half the playlists for some
  ;; queries) and spot trips over them. Drop them, and hand dash a list.
  (define-advice spot--union-search-items (:filter-return (items) music-drop-nulls)
    (seq-remove #'null (append items nil)))

  ;; Spotify now returns slimmed-down objects to development-mode apps (an
  ;; artist without followers/genres/popularity), and spot's annotators index
  ;; into the missing fields. A candidate with no annotation beats a broken
  ;; picker: swallow annotator errors.
  (dolist (fn '(spot--annotate-album spot--annotate-artist spot--annotate-playlist spot--annotate-track
                spot--annotate-show spot--annotate-episode spot--annotate-audiobook))
    (when (fboundp fn)
      (advice-add fn :around (lambda (orig &rest args) (condition-case nil (apply orig args) (error nil)))
                  '((name . music-safe-annotate)))))

  ;; RET in the picker. spot binds nothing to it (everything is an embark action
  ;; behind C-.), so RET just closed the picker. Make RET play tracks, albums
  ;; and artists, and open playlists as a list of their tracks.
  (dolist (src '(spot--consult-source-track spot--consult-source-album spot--consult-source-artist
                 spot--consult-source-playlists-tracks spot--consult-source-show spot--consult-source-episode
                 spot--consult-source-audiobook))
    (when (boundp src) (set src (plist-put (symbol-value src) :action #'spot-action--generic-play-uri))))
  (dolist (src '(spot--consult-source-playlist spot--consult-source-current-user-playlists))
    (when (boundp src) (set src (plist-put (symbol-value src) :action #'spot-action--list-playlist-tracks))))

  ;; Playback needs a target device. Spotify only accepts a play command when
  ;; some device is already active; otherwise it fails quietly. Remember a
  ;; device (SPC o s d) and pass it along whenever nothing is active.
  (defvar music--device-id nil "Spotify device id playback goes to when none is active.")
  (with-eval-after-load 'savehist (add-to-list 'savehist-additional-variables 'music--device-id))
  (defun music--devices ()
    (alist-get 'devices (spot-request :method "GET" :url (concat spot-player-url "/devices") :q-params "" :parse-json t)))
  (defun music-select-device ()
    "Pick the Spotify device playback should go to."
    (interactive)
    (music--ensure)
    (let* ((devices (append (music--devices) nil))
           (names (mapcar (lambda (d) (alist-get 'name d)) devices))
           (name (completing-read "Play on: " names nil t)))
      (setq music--device-id (alist-get 'id (seq-find (lambda (d) (equal (alist-get 'name d) name)) devices)))
      (message "Spotify playback -> %s" name)))
  (define-advice spot-action--generic-play-uri (:around (orig item) music-ensure-device)
    (let* ((devices (append (music--devices) nil))
           (active (seq-find (lambda (d) (eq (alist-get 'is_active d) t)) devices)))
      (unless (or active music--device-id) (music-select-device))
      (if active
          (funcall orig item)
        (cl-letf (((symbol-function 'spot--base-q-params) (lambda () (concat "?device_id=" music--device-id))))
          (funcall orig item)))))

  ;; Client id/secret from 1Password, on first need.
  (defun music--load-credentials ()
    (unless spot-client-id
      (setq spot-client-id (secret-op "op://Private/Spotify/Emacs Smudge Creds/Client ID")
            spot-client-secret (secret-op "op://Private/Spotify/Emacs Smudge Creds/Client Secret"))))
  (advice-add 'spot--id-secret :before #'music--load-credentials)      ; token exchange / refresh
  (advice-add 'spot--auth-url-full :before #'music--load-credentials)  ; the authorize URL

  ;; spot forgets to ask for the playlist-read scopes (403 "insufficient client
  ;; scope" on your own playlists) and the currently-playing one. Add them.
  (define-advice spot--auth-url-full (:filter-return (url) music-extra-scopes)
    (replace-regexp-in-string "&scope=" "&scope=playlist-read-private%20playlist-read-collaborative%20user-read-currently-playing%20" url t t))

  ;; Authorize in the real browser, where the password manager lives and the
  ;; address bar is easy to copy from, rather than in the embedded WebKit.
  (define-advice spot-authorize (:around (orig) music-external-browser)
    (let ((browse-url-browser-function #'browse-url-default-macosx-browser))
      (funcall orig)))

  ;; Refresh token persistence (spot itself keeps it only in memory).
  (require 'plstore)
  (defvar music--token-store (no-littering-expand-var-file-name "spot.plstore"))
  (defun music--save-refresh-token (token)
    (let ((store (plstore-open music--token-store)))
      (plstore-put store "spotify" nil `(:secret-refresh-token ,token))
      (plstore-save store)
      (plstore-close store)))
  (defun music--load-refresh-token ()
    (when (file-exists-p music--token-store)
      (let* ((store (plstore-open music--token-store))
             (token (plist-get (cdr (plstore-get store "spotify")) :secret-refresh-token)))
        (plstore-close store)
        token)))
  (add-variable-watcher 'spot-refresh-token
                        (lambda (_sym new op _where)
                          (when (and (eq op 'set) new (not (equal new (music--load-refresh-token))))
                            (music--save-refresh-token new))))
  (unless spot-refresh-token (setq spot-refresh-token (music--load-refresh-token)))

  ;; The mode-line poll fires every few seconds even while there is no token
  ;; yet (mid-authorization) and then errors in the echo area. Keep quiet then.
  (define-advice spot--check-for-modeline-update (:around (orig) music-quiet-without-token)
    (when (or spot-access-token spot-refresh-token)
      (condition-case err (funcall orig)
        (error (message "spot: %s" (error-message-string err))))))

  ;; Current track in the mode line (doom-modeline shows global-mode-string).
  (add-to-list 'global-mode-string '(:eval (and (bound-and-true-p spot-mode) (spot-mode-line-string))) t))

(defun music--ensure ()
  "Load spot and turn on `spot-mode' (embark/marginalia hooks, token refresh, mode line).
Done on first use rather than at startup so Spotify only asks 1Password when you use it."
  (require 'spot)
  (unless spot-mode (spot-mode 1)))

(defmacro music-defcommand (name doc &rest body)
  `(defun ,name () ,doc (interactive) (music--ensure) ,@body))

(music-defcommand music-search
  "Search Spotify. Results grouped tracks, albums, artists, playlists, in Spotify's relevance order."
  (let ((vertico-sort-function nil))          ; keep Spotify's ranking and the group order below
    (consult--multi '(spot--consult-source-track spot--consult-source-album
                      spot--consult-source-artist spot--consult-source-playlist)
                    :history '(:input spot--consult-search-search-history)
                    :sort nil)))
(music-defcommand music-playlists "My playlists." (call-interactively #'spot-consult-search-current-user-playlists))
(music-defcommand music-add-to-playlist "Add the current track to a playlist." (call-interactively #'spot-add-current-track-to-playlist))
(music-defcommand music-play "Play." (spot-player-play))
(music-defcommand music-pause "Pause." (spot-player-pause))
(music-defcommand music-next "Next track." (spot-player-next))
(music-defcommand music-previous "Previous track." (spot-player-previous))
(music-defcommand music-authorize "Authorize Spotify (one time)." (spot-authorize))

(leader
  "os"  '(:ignore t :wk "spotify")
  "oss" '(music-search :wk "search")
  "osl" '(music-playlists :wk "my playlists")
  "os+" '(music-add-to-playlist :wk "add current to playlist")
  "osp" '(music-play :wk "play")
  "osP" '(music-pause :wk "pause")
  "osn" '(music-next :wk "next")
  "osb" '(music-previous :wk "previous")
  "osd" '(music-select-device :wk "device")
  "osa" '(music-authorize :wk "authorize"))
