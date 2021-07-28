source ~/.znap/zsh-snap/znap.zsh
autoload -Uz compinit 
compinit
source "$HOME/.zsh/plugins.zsh"
source "$HOME/.zsh/history.zsh"
source "$HOME/.zsh/alias.zsh"
source "$HOME/.zsh/prompt.zsh"
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|=*' 'l:|=* r:|=*'
setopt menu_complete
setopt nocaseglob

# . "/usr/share/LS_COLORS/dircolors.sh"
export LS_COLORS="$(vivid generate $HOME/.zsh/assets/vividtheme.yml)"

export EDITOR=/usr/bin/nvim
export VISUAL=/usr/bin/nvim

export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

q () {
  exit
}

if [ -f ~/.last_pwd ]; then
    cd `cat ~/.last_pwd`
fi 

export PATH=$PATH:$HOME/go/bin

if [ -z "${DISPLAY}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx
fi
