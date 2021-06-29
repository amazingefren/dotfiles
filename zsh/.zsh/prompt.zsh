autoload -Uz vcs_info
precmd_vcs_info() { vcs_info }
precmd_functions+=( precmd_vcs_info )
setopt prompt_subst
setopt promptsubst
zinit snippet OMZL::git.zsh
zinit snippet OMZP::git
autoload -U colors && colors
YS_VCS_PROMPT_PREFIX=" %{$fg[white]%} %{$fg_bold[cyan]%}"
# YS_VCS_PROMPT_SUFFIX="%{$fg[red]]%} %{$reset_color%}"
YS_VCS_PROMPT_DIRTY=" %{$fg[red]%}✗"
YS_VCS_PROMPT_CLEAN=" %{$fg[green]%}●"
local git_info='$(git_prompt_info)'
ZSH_THEME_GIT_PROMPT_PREFIX="$YS_VCS_PROMPT_PREFIX"
# ZSH_THEME_GIT_PROMPT_SUFFIX="$YS_VCS_PROMPT_SUFFIX"
ZSH_THEME_GIT_PROMPT_DIRTY="$YS_VCS_PROMPT_DIRTY"
ZSH_THEME_GIT_PROMPT_CLEAN="$YS_VCS_PROMPT_CLEAN"

precmd() { print "" }
# Luke Smith + Git
PS1="%{$fg[red]%}[%{$fg[yellow]%}%n%{$fg[green]%}@%{$fg[blue]%}%M %{$fg[magenta]%}%(4~|%-1~/…/%2~|%3~)%{${git_info}%}%{$fg[red]%}]%{$reset_color%} 
$ "
