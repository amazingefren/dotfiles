;;; feeds.el --- RSS with elfeed  -*- lexical-binding: t -*-
;;
;; Feeds imported from ~/.newsboat/urls, same tags. elfeed lives in the home
;; workspace: SPC o r switches there and opens it. Database in ~/.cache.
;;
;; In the article list (vim keys via evil-collection):
;;   RET open   b open in browser   r/u mark read/unread   R fetch all feeds
;;   s live filter   S set filter   c clear filter   F saved filters   * star
;;   y copy link   q quit
;;   In an article: n/p next/previous, b browser, q back to the list.

(use-package elfeed
  :commands (elfeed elfeed-update)
  :custom
  (elfeed-search-filter "@2-weeks-ago +unread")     ; default view: unread from the last two weeks
  (elfeed-search-title-max-width 90)
  (elfeed-curl-max-connections 8)
  (elfeed-feeds
   '(
    ;; Labs / official
    ("https://raw.githubusercontent.com/Olshansk/rss-feeds/main/feeds/feed_anthropic_news.xml" core labs anthropic)   ; Anthropic News
    ("https://raw.githubusercontent.com/Olshansk/rss-feeds/main/feeds/feed_anthropic_engineering.xml" core labs anthropic)   ; Anthropic Engineering
    ("https://raw.githubusercontent.com/Olshansk/rss-feeds/main/feeds/feed_anthropic_research.xml" core labs anthropic)   ; Anthropic Research
    ("https://raw.githubusercontent.com/Olshansk/rss-feeds/main/feeds/feed_claude.xml" core labs anthropic)   ; Claude Blog
    ("https://openai.com/news/rss.xml" core labs)   ; OpenAI News
    ("https://raw.githubusercontent.com/Olshansk/rss-feeds/main/feeds/feed_openai_developer.xml" labs)   ; OpenAI Developers
    ("https://deepmind.google/blog/rss.xml" core labs)   ; Google DeepMind
    ("https://blog.google/technology/ai/rss/" labs)   ; Google AI Blog
    ("https://raw.githubusercontent.com/Olshansk/rss-feeds/main/feeds/feed_meta_ai.xml" core labs)   ; Meta AI
    ("https://raw.githubusercontent.com/Olshansk/rss-feeds/main/feeds/feed_mistral.xml" labs)   ; Mistral
    ("https://raw.githubusercontent.com/Olshansk/rss-feeds/main/feeds/feed_xainews.xml" labs)   ; xAI
    ("https://huggingface.co/blog/feed.xml" core labs)   ; Hugging Face
    ("https://www.microsoft.com/en-us/research/feed/" labs)   ; Microsoft Research

    ;; Tools / changelogs
    ("https://github.com/anthropics/claude-code/releases.atom" core tools)   ; Claude Code Releases
    ("https://cursor.com/changelog/rss.xml" tools)   ; Cursor Changelog
    ("https://github.blog/ai-and-ml/feed/" tools)   ; GitHub AI Blog
    ("https://blog.cloudflare.com/tag/ai/rss/" tools)   ; Cloudflare AI
    ("https://developers.googleblog.com/feeds/posts/default" tools)   ; Google Developers

    ;; Practitioners / commentary
    ("https://simonwillison.net/atom/everything/" core practitioners)   ; Simon Willison
    ("https://www.latent.space/feed" core practitioners)   ; Latent Space
    ("https://www.interconnects.ai/feed" core practitioners)   ; Interconnects (Lambert)
    ("https://magazine.sebastianraschka.com/feed" practitioners)   ; Sebastian Raschka
    ("https://www.oneusefulthing.org/feed" practitioners)   ; One Useful Thing (Mollick)
    ("https://thezvi.substack.com/feed" practitioners)   ; Zvi
    ("https://eugeneyan.com/rss/" practitioners)   ; Eugene Yan
    ("https://hamel.dev/index.xml" practitioners)   ; Hamel Husain
    ("https://www.philschmid.de/rss" practitioners)   ; Phil Schmid
    ("https://lilianweng.github.io/index.xml" practitioners)   ; Lilian Weng
    ("https://karpathy.bearblog.dev/feed/" practitioners)   ; Karpathy
    ("https://www.answer.ai/index.xml" practitioners)   ; Answer.AI
    ("https://newsletter.pragmaticengineer.com/feed" practitioners)   ; Pragmatic Engineer
    ("https://raw.githubusercontent.com/Olshansk/rss-feeds/main/feeds/feed_the_batch.xml" practitioners)   ; The Batch (deeplearning.ai)

    ;; Research
    ("https://rss.arxiv.org/rss/cs.CL" research)   ; arXiv cs.CL
    ("https://rss.arxiv.org/rss/cs.AI" research)   ; arXiv cs.AI

    ;; Community
    ("https://hnrss.org/newest?q=LLM+OR+Claude+OR+OpenAI+OR+Anthropic+OR+GPT+OR+Gemini&points=50" core community)   ; Hacker News · AI (50+ pts)
    ("https://lobste.rs/t/ai.rss" community)   ; Lobsters · ai
    ("https://www.reddit.com/r/LocalLLaMA/.rss" community)   ; r/LocalLLaMA
    ("https://www.reddit.com/r/ClaudeAI/.rss" community)))  ; r/ClaudeAI
  :config
  ;; Newsboat's "starred" flag -> a star tag.
  (defalias 'elfeed-toggle-star (elfeed-expose #'elfeed-search-toggle-all 'star))
  ;; evil-collection only covers tagging; give the rest of elfeed's own keys
  ;; back their meaning in normal state (evil would otherwise use b/r/s for motions).
  (evil-define-key 'normal elfeed-search-mode-map
    (kbd "RET") #'elfeed-search-show-entry
    "b" #'elfeed-search-browse-url
    "r" #'elfeed-search-untag-unread     ; mark read
    "u" #'elfeed-search-tag-unread       ; mark unread (evil-collection had these backwards)
    "s" #'elfeed-search-live-filter
    "R" #'elfeed-update
    "*" #'elfeed-toggle-star
    "F" #'feeds-pick-filter
    "q" #'elfeed-search-quit-window)
  (evil-define-key 'normal elfeed-show-mode-map
    "n" #'elfeed-show-next
    "p" #'elfeed-show-prev
    "b" #'elfeed-show-visit
    "r" #'elfeed-show-refresh
    "*" (lambda () (interactive) (elfeed-show-tag 'star))
    "q" #'elfeed-kill-buffer))

;; The newsboat "virtual inboxes", as saved elfeed filters.
(defvar feeds-filters
  '(("all unread"     . "@2-weeks-ago +unread")
    ("starred"        . "+star")
    ("core"           . "@2-weeks-ago +unread +core")
    ("labs"           . "@2-weeks-ago +unread +labs")
    ("claude & tools" . "@2-weeks-ago +unread +tools")
    ("anthropic"      . "@1-month-ago +anthropic")
    ("practitioners"  . "@2-weeks-ago +unread +practitioners")
    ("research"       . "@3-days-ago +unread +research")
    ("community"      . "@2-days-ago +unread +community")
    ("today"          . "@1-day-ago")
    ("everything"     . "@1-month-ago")))

(defun feeds-pick-filter ()
  "Set the elfeed search filter to one of `feeds-filters'."
  (interactive)
  (let ((name (completing-read "Filter: " (mapcar #'car feeds-filters) nil t)))
    (elfeed-search-set-filter (alist-get name feeds-filters nil nil #'equal))))

(defun feeds-open ()
  "Open RSS in the home workspace."
  (interactive)
  (persp-switch "home")
  (elfeed))

(leader "or" '(feeds-open :wk "rss"))
