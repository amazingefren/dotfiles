# alias ls="exa --group-directories-first"
export LS_COLORS="$(vivid generate $HOME/.zsh/assets/vividtheme.yml)"

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
    # ls
}

md(){
  if [ "$1" != "" ];then
    glow -s dark -w 60 "$1"
  else
    glow -s dark -w 60 README.md
  fi
}

sht(){
  curl -s "cheat.sh/$1" | bat --decorations never --color always
  # tldr $1 | bat -p
  # {curl -s "cheat.sh/$1" & tldr $1} | bat
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
alias open='handlr open'
alias ps="procs"
alias rmt="rmtrash"

# n ()
# {
#     export EDITOR=nvim
#     export PAGER='less -Ri'
#     export NNN_COLORS='#5251d0be;2341'
#     nnn -cdEFQx
# }

alias ta="tmux attach"

export FZF_DEFAULT_OPTS=$FZF_DEFAULT_OPTS\
'--no-bold '\
'--color=dark '\
'--color=fg:-1,bg:-1,hl:#5fff87,fg+:-1,bg+:-1,hl+:#ffaf5f '\
'--color=info:#af87ff,prompt:#5fff87,pointer:#ff87d7,marker:#ff87d7,spinner:#ff87d7 '\
'--bind ctrl-z:ignore '
zstyle ':edit:*' word-chars '*?\'

bind \
  '^T' '@. hop' \
  '^N' '@. hopvim' \
  '^Z' '+fg'

stty -ixon # Disable XOFF/XON
