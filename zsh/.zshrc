# ---------------------------------
# Plugin Sources
# ---------------------------------
ZPLUGINDIR=$HOME/.config/zsh/plugins
source ./.zsh.plugin

# ---------------------------------
# ENV
# ---------------------------------
export LANG="en_US.UTF-8"
export EDITOR=/usr/bin/nvim
export VISUAL=/usr/bin/nvim
export PAGER=/usr/bin/less

# ---------------------------------
# Paths
# ---------------------------------
NPM_PACKAGES="${HOME}/.npm-packages"
path+="${HOME}/.npm-packages/bin"

# ---------------------------------
# Zsh
# ---------------------------------
autoload -U compinit && compinit -u
setopt CORRECT
setopt HIST_IGNORE_ALL_DUPS

bindkey -v

stty -ixon # Disable XOFF/XON

# ---------------------------------
# History
# ---------------------------------
export HISTFILE=~/.zsh_history
export HISTSIZE=20000
export SAVEHIST=20000

setopt appendhistory
setopt HIST_VERIFY
setopt EXTENDED_HISTORY
setopt HIST_IGNOREALL_DUPS
setopt HIST_REDUCE_BLANKS
setopt INC_APPEND_HISTORY
setopt SHARE_HISTORY

# ---------------------------------
# Alias
# ---------------------------------
alias vim='nvim'
alias lg='lazygit'
alias ta="tmux attach"
alias rm='rm -I'
alias open='handlr open'

sht(){
  { curl -s "cht.sh/$1" & tldr $1 } | bat --color=always
}

# ---------------------------------
# Load Plugins
# ---------------------------------
plugins=( # Order First to Last
  jeffreytse/zsh-vi-mode
  romkatv/zsh-defer # defer with plugin-load
  hlissner/zsh-autopair
  zsh-users/zsh-completions
  Aloxaf/fzf-tab
  zsh-users/zsh-history-substring-search
  zsh-users/zsh-autosuggestions
  zdharma-continuum/fast-syntax-highlighting
); plugin-load $plugins

# Plugin Repos
repos=(
  ohmyzsh/ohmyzsh
); plugin-clone $repos

# OMZ lib
ZSH=$ZPLUGINDIR/ohmyzsh
for _f in $ZSH/lib/*.zsh; do
  source $_f
done
unset _f

# Plugin source files
plugins=(
  ohmyzsh/plugins/magic-enter
  ohmyzsh/plugins/fancy-ctrl-z
); plugin-source $plugins

# ---------------------------------
# FZF & FZF-TAB
# ---------------------------------
source /usr/share/fzf/key-bindings.zsh
source /usr/share/fzf/completion.zsh

FZF_DEFAULT_COMMAND="fd --type f --hidden --follow --exclude .git --exclude node_modules"
FZF_COMPLETION_TRIGGER='@@'
FZF_DEFAULT_OPTS="--height 40% --layout=reverse --border --preview-window down:1"
FZF_ALT_C_COMMAND="fd . $HOME -t d -H"
FZF_CTRL_T_COMMAND=$FZF_DEFAULT_COMMAND

bindkey -M emacs '^T' fzf-cd-widget
bindkey -M vicmd '^T' fzf-cd-widget
bindkey -M viins '^T' fzf-cd-widget

bindkey -M emacs '\ec' fzf-file-widget
bindkey -M vicmd '\ec' fzf-file-widget
bindkey -M viins '\ec' fzf-file-widget

zstyle ':completion:*:git-checkout:*' sort false
zstyle ':completion:*:descriptions' format '[%d]'
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'exa -1 --color=always $realpath'
zstyle ':fzf-tab:*' switch-group ',' '.'


# ---------------------------------
# Exa
# ---------------------------------
alias ls="exa --group-directories-first -ah"
alias lsa="ls -a"
alias lst="ls -T --level 2"

# ---------------------------------
# Starship Prompt
# ---------------------------------
eval "$(starship init zsh)"

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

# ---------------------------------
# NVM (node version manager)
# ---------------------------------
autoload -U add-zsh-hook
load-nvmrc() {
  local nvmrc_path="$(nvm_find_nvmrc)"

  if [ -n "$nvmrc_path" ]; then
    local nvmrc_node_version=$(nvm version "$(cat "${nvmrc_path}")")

    if [ "$nvmrc_node_version" = "N/A" ]; then
      nvm install
    elif [ "$nvmrc_node_version" != "$(nvm version)" ]; then
      nvm use
    fi
  elif [ -n "$(PWD=$OLDPWD nvm_find_nvmrc)" ] && [ "$(nvm version)" != "$(nvm version default)" ]; then
    echo "Reverting to nvm default version"
    nvm use default
  fi
}
add-zsh-hook chpwd load-nvmrc
load-nvmrc
