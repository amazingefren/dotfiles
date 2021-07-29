alias ls="exa --group-directories-first"
alias lsa="ls -a"
alias lst="ls -T --level 2"

b(){ popd &>/dev/null }

cdl(){
    if [ "$1" != "" ];then
        pushd $* &>/dev/null
        ls
    else
        pushd ~ &>/dev/null
        ls
    fi
    pwd > ~/.last_pwd
}

cd(){
    if [ "$1" != "" ];then
        pushd $* &>/dev/null
    else
        pushd ~ &>/dev/null
    fi
    pwd > ~/.last_pwd
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
alias ..='cd ..'

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
