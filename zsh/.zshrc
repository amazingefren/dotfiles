source "$HOME/.zsh/zinit.zsh"
source "$HOME/.zsh/history.zsh"
source "$HOME/.zsh/alias.zsh"
source "$HOME/.zsh/prompt.zsh"

autoload -Uz compinit 
compinit
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z} l:|=* r:|?=**'
setopt menu_complete
setopt nocaseglob

export EDITOR=/usr/bin/nvim
export VISUAL=/usr/bin/nvim

if [ -z "${DISPLAY}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx
fi
