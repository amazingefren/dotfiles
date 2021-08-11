# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

source ~/.znap/zsh-snap/znap.zsh

source "$HOME/.zsh/plugins.zsh"
source "$HOME/.zsh/history.zsh"
source "$HOME/.zsh/alias.zsh"
source "$HOME/.zsh/compmenu.zsh"

# Slow to start, but is fast WIP
# eval "$(starship init zsh)"
# export STARSHIP_CONFIG=$HOME/.starship.toml

export EDITOR=/usr/bin/nvim
export VISUAL=/usr/bin/nvim
export PATH=$PATH:$HOME/go/bin

# ccache
export PATH="/usr/lib/ccache/bin/:$PATH"
export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Kitty
alias ssh="kitty +kitten ssh"

if [ -f ~/.last_pwd ]; then
    cd `cat ~/.last_pwd` &>/dev/null
fi 

if [ -z "${DISPLAY}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx
fi

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
