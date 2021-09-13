# alias ls="exa --group-directories-first"
alias lsa="ls -a"
alias lst="ls -T --level 2"

b(){ popd &>/dev/null }

cd(){
    if [ "$1" != "" ];then
        pushd $* &>/dev/null
    else
        pushd ~ &>/dev/null
    fi
    # ls
}

md(){
  if [ "$1" != "" ];then
    glow -s dark -w 60 "$1"
  else
    glow -s dark -w 60 README.md
  fi
}

# alias du="dust"
# alias find="fd -H"
# alias fm='vifm'
# PS => PROCS

alias lg=lazygit
alias fuck=b
alias temps='watch -n.5 "grep \"^[c]pu MHz\" /proc/cpuinfo; echo && sensors k10temp-pci-00c3 amdgpu-pci-2d00"'
alias um='sudo reflector --verbose --country US --latest 5 --protocol https --sort rate --save /etc/pacman.d/mirrorlist'
alias alexaturnonthecamera='sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="OBS Cam" exclusive_caps=1'

# n ()
# {
#     export EDITOR=nvim
#     export PAGER='less -Ri'
#     export NNN_COLORS='#5251d0be;2341'
#     nnn -cdEFQx
# }

runfg(){echo;fg}
zle -N runfg
bindkey '^Z' runfg

findfolder(){
  local wheretogo=$(fd -c always -H -t d -t l . $HOME -E .git -E node_modules -E .cache -E local | fzf)
  if [[ ! -z "$wheretogo" ]];then
    cd "$wheretogo"
  fi
  zle reset-prompt
}
zle -N findfolder
bindkey '^T' findfolder
