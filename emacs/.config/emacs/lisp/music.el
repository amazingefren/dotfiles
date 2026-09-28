;;; music.el --- Spotify via Spot  -*- lexical-binding: t -*-

(use-package spot
  :vc (:url "https://github.com/chiply/spot" :rev :newest)
  :commands (spot-consult-search spot-consult-search-current-user-playlists
             spot-add-current-track-to-playlist spot-player-play spot-player-pause
             spot-player-next spot-player-previous spot-authorize spot-mode)
  :config
  ;; Spotify allows plain http only on loopback. Nothing listens: paste the ?code= from the error page.
  (setq spot--redirect-uri (url-hexify-string "http://127.0.0.1:8080/smudge_api_callback"))

  ;; Development-mode apps get at most 10 results per type; spot asks for 20 and gets nothing.
  (define-advice spot--build-search-q-params (:filter-return (params) music-cap-limit)
    (if (string-match-p "limit=" params) params (concat params "&limit=10")))
  ;; Spotify's matching for shows, episodes and audiobooks is loose enough to crowd the list.
  (define-advice spot--build-search-q-params (:filter-return (params) music-default-types)
    (replace-regexp-in-string "&type=album,artist,playlist,track,show,episode,audiobook"
                              "&type=track,album,artist,playlist" params t t))

  ;; Spotify pads search results with null entries and spot trips over them.
  (define-advice spot--union-search-items (:filter-return (items) music-drop-nulls)
    (seq-remove #'null (append items nil)))

  ;; Development-mode apps get slimmed-down objects, and spot's annotators error on the missing fields.
  (dolist (fn '(spot--annotate-album spot--annotate-artist spot--annotate-playlist spot--annotate-track
                spot--annotate-show spot--annotate-episode spot--annotate-audiobook))
    (when (fboundp fn)
      (advice-add fn :around (lambda (orig &rest args) (condition-case nil (apply orig args) (error nil)))
                  '((name . music-safe-annotate)))))

  ;; spot binds nothing to RET in the picker (everything is an embark action).
  (dolist (src '(spot--consult-source-track spot--consult-source-album spot--consult-source-artist
                 spot--consult-source-playlists-tracks spot--consult-source-show spot--consult-source-episode
                 spot--consult-source-audiobook))
    (when (boundp src) (set src (plist-put (symbol-value src) :action #'spot-action--generic-play-uri))))
  (dolist (src '(spot--consult-source-playlist spot--consult-source-current-user-playlists))
    (when (boundp src) (set src (plist-put (symbol-value src) :action #'spot-action--list-playlist-tracks))))

  ;; Spotify quietly ignores a play command unless some device is active.
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

  (defun music--load-credentials ()
    (unless spot-client-id
      (setq spot-client-id (op-secret 'spotify-client-id)
            spot-client-secret (op-secret 'spotify-client-secret))))
  (advice-add 'spot--id-secret :before #'music--load-credentials)
  (advice-add 'spot--auth-url-full :before #'music--load-credentials)

  ;; spot omits these scopes (403 "insufficient client scope" on your own playlists).
  (define-advice spot--auth-url-full (:filter-return (url) music-extra-scopes)
    (replace-regexp-in-string "&scope=" "&scope=playlist-read-private%20playlist-read-collaborative%20user-read-currently-playing%20" url t t))

  ;; The real browser has the password manager and an easy-to-copy address bar.
  (define-advice spot-authorize (:around (orig) music-external-browser)
    (let ((browse-url-browser-function #'browse-url-default-macosx-browser))
      (funcall orig)))

  ;; spot keeps the refresh token only in memory.
  (require 'plstore)
  (defvar music--token-store (no-littering-expand-var-file-name "spot.plstore"))
  (defun music--save-refresh-token (token)
    (unless (security-plstore-key-available-p)
      (error "No local encryption key; run SPC o s a to create one before authorizing"))
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

  ;; The mode-line poll runs before there is a token and errors in the echo area.
  (define-advice spot--check-for-modeline-update (:around (orig) music-quiet-without-token)
    (when (or spot-access-token spot-refresh-token)
      (condition-case err (funcall orig)
        (error (message "spot: %s" (error-message-string err))))))

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
  (let ((vertico-sort-function nil))
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
(music-defcommand music-authorize "Authorize Spotify."
  (security-ensure-plstore-key)
  (spot-authorize))

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
