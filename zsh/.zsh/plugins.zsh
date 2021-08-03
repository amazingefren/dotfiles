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

# znap source jakshin/yazpt
# YAZPT_LAYOUT="%{%F{green}%B%D{%H:%M}%b%} %{%B%F{white}%D{%b %d}%b%} %{%B%F{reset_color}[%b%}%{%B%F{blue}%n%b%}%{%B%F{reset_color}@%b%}%{%B%F{cyan}${${(%):-%m}#1}%b%}%{%B%F{reset_color}]%b%} %{%B%}<cwd> <git>%{%b%}
# > "
# YAZPT_VCS_CONTEXT_COLOR=green
