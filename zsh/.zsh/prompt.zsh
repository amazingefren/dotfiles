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
terminfo_down_sc=$terminfo[cud1]$terminfo[cuu1]$terminfo[sc]$terminfo[cud1]
preexec () { print -rn -- $terminfo[el]; }
# The plugin will auto execute this zvm_after_select_vi_mode function
function zvm_after_select_vi_mode() {
  case $ZVM_MODE in
    $ZVM_MODE_NORMAL)
# PS1_2="%{$bg[blue]%F{#000}%} N "
PS1_2="%{$fg[blue]%}N"
PS1="%B%{$fg[red]%}[ %{$fg[yellow]%}%n%{$fg[green]%}@%{$fg[blue]%}%M %{$fg[magenta]%}%(4~|%-1~/…/%2~|%3~)%{${git_info}%}%{$fg[red]%} ]
${PS1_2}%{$reset_color%}> "
# ${PS1_2}%{$reset_color%}%{$fg[blue]%}%{$reset_color%} "
# %{$terminfo_down_sc$PS1_2$terminfo[rc]%}%{$reset_color%}$ "
    ;;
    $ZVM_MODE_INSERT)
# PS1_2="%{$bg[green]%F{#000}%} I "
PS1_2="%{$fg[green]%}I"
PS1="%B%{$fg[red]%}[ %{$fg[yellow]%}%n%{$fg[green]%}@%{$fg[blue]%}%M %{$fg[magenta]%}%(4~|%-1~/…/%2~|%3~)%{${git_info}%}%{$fg[red]%} ]
${PS1_2}%{$reset_color%}> "
# ${PS1_2}%{$reset_color%}%{$fg[green]%}%{$reset_color%} "
# %{$terminfo_down_sc$PS1_2$terminfo[rc]%}%{$reset_color%}$ "
    ;;
    $ZVM_MODE_VISUAL)
# PS1_2="%{$bg[yellow]%F{#000}%} V "
PS1_2="%{$fg[yellow]%}V"
PS1="%B%{$fg[red]%}[ %{$fg[yellow]%}%n%{$fg[green]%}@%{$fg[blue]%}%M %{$fg[magenta]%}%(4~|%-1~/…/%2~|%3~)%{${git_info}%}%{$fg[red]%} ]
${PS1_2}%{$reset_color%}> "
# ${PS1_2}%{$reset_color%}%{$fg[yellow]%}%{$reset_color%} "
# %{$terminfo_down_sc$PS1_2$terminfo[rc]%}%{$reset_color%}$ "
    ;;
    $ZVM_MODE_VISUAL_LINE)
# PS1_2="%{$bg[yellow]%F{#000}%} V "
PS1_2="%{$fg[yellow]%}V"
PS1="%B%{$fg[red]%}[ %{$fg[yellow]%}%n%{$fg[green]%}@%{$fg[blue]%}%M %{$fg[magenta]%}%(4~|%-1~/…/%2~|%3~)%{${git_info}%}%{$fg[red]%} ]
${PS1_2}%{$reset_color%}> "
# ${PS1_2}%{$reset_color%}%{$fg[yellow]%}%{$reset_color%} "
# %{$terminfo_down_sc$PS1_2$terminfo[rc]%}%{$reset_color%}$ "
    ;;
    $ZVM_MODE_REPLACE)
# PS1_2="%{$bg[red]%F{#000}%} R "
PS1_2="%{$fg[red]%}R"
PS1="%B%{$fg[red]%}[ %{$fg[yellow]%}%n%{$fg[green]%}@%{$fg[blue]%}%M %{$fg[magenta]%}%(4~|%-1~/…/%2~|%3~)%{${git_info}%}%{$fg[red]%} ]
${PS1_2}%{$reset_color%}> "
# ${PS1_2}%{$reset_color%}%{$fg[red]%}%{$reset_color%} "
# %{$terminfo_down_sc$PS1_2$terminfo[rc]%}%{$reset_color%}$ "
    ;;
  esac
}
# Luke Smith + Git
# PS1="%B%{$fg[red]%}[ %{$fg[yellow]%}%n%{$fg[green]%}@%{$fg[blue]%}%M %{$fg[magenta]%}%(4~|%-1~/…/%2~|%3~)%{${git_info}%}%{$fg[red]%} ]%{$reset_color%} 
# $ "
