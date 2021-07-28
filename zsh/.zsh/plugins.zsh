autoload -Uz _zinit
(( ${+_comps} )) && _comps[zinit]=_zinit

# Completion
# zinit wait lucid for \
    # blockf zsh-users/zsh-completions

znap source jeffreytse/zsh-vi-mode
znap source zsh-users/zsh-autosuggestions
znap source zdharma/fast-syntax-highlighting
znap source ajeetdsouza/zoxide

znap source marlonrichert/zsh-autocomplete
zstyle ':autocomplete:tab:*' accept-autosuggestions no
zstyle ':autocomplete:tab:*' widget-style menu-select
zstyle ':autocomplete:*' min-delay 0.50

autoload -U promptinit; promptinit
znap prompt spaceship-prompt/spaceship-prompt
