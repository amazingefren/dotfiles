if [ ! -d "${HOME}/.zinit" ]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/zdharma/zinit/master/doc/install.sh)"
fi


source "$HOME/.zinit/bin/zinit.zsh"
autoload -Uz _zinit
(( ${+_comps} )) && _comps[zinit]=_zinit


# zinit ice load light-mode for \

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


zinit wait lucid for \
  mfaerevaag/wd

# NOTE: ZINIT OR ZSH-SNAP? I CANT FIGURE OUT HOW TO LOAD THIS BEFORE INIT
# SO IT DOESNT WORK UNTIL SECOND PROMPT
# PR: zinit #268
# CLAIMS: https://www.reddit.com/r/zsh/comments/ix98cv/new_znap_plugin_manager_features_instant_prompt/g6e3ep7/
# WORTH: a shot
zinit wait for marlonrichert/zsh-autocomplete
