setopt HIST_IGNORE_ALL_DUPS

if [[ ! -d "$HOME/.zim" ]]; then
  curl -fsSL https://raw.githubusercontent.com/zimfw/install/master/install.zsh | zsh
fi

# if [[ "${VIMRUNTIME}" ]]; then
#   bindkey -e # Set zsh instance to emacs mode
#   else
bindkey -v # fi
setopt CORRECT
SPROMPT='zsh: correct %F{red}%R%f to %F{green}%r%f [nyae]? '
# Remove path separator from WORDCHARS.
# WORDCHARS=${WORDCHARS//[\/]}
# Use degit instead of git as the default tool to install and update modules.
zstyle ':zim:zmodule' use 'degit'
zstyle ':zim:git' aliases-prefix 'g'
zstyle ':zim:input' double-dot-expand yes

ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets)

if [[ ! ${ZIM_HOME}/init.zsh -nt ${ZDOTDIR:-${HOME}}/.zimrc ]]; then
  source ${ZIM_HOME}/zimfw.zsh init -q
fi
source ${ZIM_HOME}/init.zsh

bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down

zmodload -F zsh/terminfo +p:terminfo
if [[ -n ${terminfo[kcuu1]} && -n ${terminfo[kcud1]} ]]; then
  bindkey ${terminfo[kcuu1]} history-substring-search-up
  bindkey ${terminfo[kcud1]} history-substring-search-down
fi

bindkey '^P' history-substring-search-up
bindkey '^N' history-substring-search-down
bindkey -M vicmd 'k' history-substring-search-up
bindkey -M vicmd 'j' history-substring-search-down

bindkey '^f' autosuggest-accept

source "$HOME/.zsh/history.zsh"
source "$HOME/.zsh/alias.zsh"
# source "$HOME/.zsh/plugins.zsh"
# source "$HOME/.zsh/compmenu.zsh"

export EDITOR=/usr/bin/nvim
export VISUAL=/usr/bin/nvim
export PATH=$PATH:$HOME/go/bin

# ccache
export PATH="/usr/lib/ccache/bin/:$PATH"
export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Kitty
alias ssh="kitty +kitten ssh"


if [ -z "${DISPLAY}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx
    setxkbmap -layout us -variant dvp
fi

