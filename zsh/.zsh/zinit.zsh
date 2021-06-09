if [ ! -d "${HOME}/.zinit" ]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/zdharma/zinit/master/doc/install.sh)"
fi

source "$HOME/.zinit/bin/zinit.zsh"
autoload -Uz _zinit
(( ${+_comps} )) && _comps[zinit]=_zinit


# Fast Search
zinit wait lucid for \
    mafredri/zsh-async \
    seletskiy/zsh-fuzzy-search-and-edit
# bindkey '^M' fuzzy-search-and-edit
alias fz=fuzzy-search-and-edit

# Completion
zinit wait lucid for \
    blockf zsh-users/zsh-completions

# Syntax
zinit wait lucid for \
    atinit"ZINIT[COMPINIT_OPTS]='-1' zpcompinit; zpcdreplay" \
    zdharma/fast-syntax-highlighting

# Suggestion
zinit wait lucid for \
    atload"_zsh_autosuggest_start" \
    zsh-users/zsh-autosuggestions
export ZSH_AUTOSUGGEST_USE_ASYNC=1
export ZSH_AUTOSUGGEST_MANUAL_REBIND=1

# Better vi
zinit light  jeffreytse/zsh-vi-mode
