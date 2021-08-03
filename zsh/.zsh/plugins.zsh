znap source mafredri/zsh-async
znap source zsh-users/zsh-autosuggestions
znap source zdharma/fast-syntax-highlighting
znap source ajeetdsouza/zoxide
znap source zsh-users/zsh-completions

# Check if running in vim
if [[ "${VIMRUNTIME}" ]]; then
  bindkey -e # Set zsh instance to emacs mode
else
  znap source jeffreytse/zsh-vi-mode
fi

# znap source marlonrichert/zsh-autocomplete
# zstyle ':autocomplete:tab:*' accept-autosuggestions no
# zstyle ':autocomplete:tab:*' widget-style menu-select
# zstyle ':autocomplete:*' min-delay 0.50

#temp workaround for starship using async branch (pending PR)
# if [ -d "$HOME/.znap/spaceship-prompt" ];then
  # znap prompt ~[spaceship-prompt/spaceship-prompt]
# else
#   git clone --branch async $HOME/.znap/spaceship-prompt
# fi

# is so fast
# znap prompt sindresorhus/pure

# faster than pure somehow
# temp for now (needs vi mode)
# znap source jakshin/yazpt

# YAZPT_LAYOUT="%{%F{green}%B%D{%H:%M}%b%} %{%B%F{white}%D{%b %d}%b%} %{%B%F{reset_color}[%b%}%{%B%F{blue}%n%b%}%{%B%F{reset_color}@%b%}%{%B%F{cyan}${${(%):-%m}#1}%b%}%{%B%F{reset_color}]%b%} %{%B%}<cwd> <git>%{%b%}
# > "

# YAZPT_VCS_CONTEXT_COLOR=green
