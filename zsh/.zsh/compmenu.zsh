zmodload -i zsh/complist

export LS_COLORS="$(vivid generate $HOME/.zsh/assets/vividtheme.yml)"

# zstyle ':completion:*' completer _extensions _expand _complete _ignored _approximate
zstyle ':completion:*' completer _extensions _expand _complete _ignored
zstyle ':completion::complete:*' use-cache on
zstyle ':completion::complete:*' cache-path ~/.zsh_cache/$HOST
zstyle ':completion:*' menu select=1
zstyle ':completion:*:descriptions' format '%F{cyan}%B ----- %d -----%f'
zstyle ':completion:*' group-name ''
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
zstyle ':completion:*' complete-options true # DIRECTORY STACK LETS GO

zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|=*' 'l:|=* r:|=*'

### MOOD: sad
# SEE: https://www.zsh.org/mla/users/2020/msg00229.html
# zstyle ':completion:*' file-list true all
###

setopt nocaseglob
setopt auto_menu
setopt globdots
# setopt menu_complete
# setopt list_packed

bindkey -M menuselect 'H' vi-backward-char
bindkey -M menuselect 'K' vi-up-line-or-history
bindkey -M menuselect 'J' vi-down-line-or-history
bindkey -M menuselect 'L' vi-forward-char
bindkey -M menuselect ' ' accept-and-infer-next-history
bindkey -M menuselect '/' history-incremental-search-forward
bindkey -M menuselect '^[[Z' reverse-menu-complete
