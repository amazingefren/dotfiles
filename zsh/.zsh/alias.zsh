alias ls="exa --group-directories-first"
alias lsa="ls -a"
alias lst="ls -T --level 2"

b(){ popd &>/dev/null }

cd(){
    if [ "$1" != "" ];then
        pushd $* &>/dev/null
    else
        pushd ~ &>/dev/null
    fi
}


alias cat="bat -p"
alias find="fd -H"
alias du="dust"
alias fuck=b
alias temps='watch -n.5 "grep \"^[c]pu MHz\" /proc/cpuinfo; echo && sensors k10temp-pci-00c3 amdgpu-pci-2d00"'
alias fm='vifm'
# PS => PROCS
alias ua='sudo reflector --verbose --country US --latest 5 --protocol https --sort rate --save /etc/pacman.d/mirrorlist'
alias pn='pnpm'

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
