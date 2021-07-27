source "$HOME/.zsh/zinit.zsh"
source "$HOME/.zsh/history.zsh"
source "$HOME/.zsh/alias.zsh"
source "$HOME/.zsh/prompt.zsh"

autoload -Uz compinit 
compinit
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|=*' 'l:|=* r:|=*'
setopt menu_complete
setopt nocaseglob

export EDITOR=/usr/bin/nvim
export VISUAL=/usr/bin/nvim

export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm

q () {
  exit
}

# bindkey -e not changing from bindkey -v 
# i'm guessing either (EDITOR) or the plugin is causing bindkey -v to stick
# local check=$(env | grep "VIMRUNTIME" &>/dev/null)
# if [ ! -z "$check" ]; then
  # zinit unload jeffreytse/zsh-vi-mode
  # bindkey -e
# else
  zinit light  jeffreytse/zsh-vi-mode
# fi

# ITS TEMPORARY OK
if [ -f ~/.last_pwd ]; then
    cd `cat ~/.last_pwd`
fi 

export PATH=$PATH:$HOME/go/bin

if [ -z "${DISPLAY}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx
fi

