# alias ls="exa --group-directories-first"
export LS_COLORS="$(vivid generate $HOME/.zsh/assets/vividtheme.yml)"

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

alias ta="tmux attach"

runfg(){echo;fg}
zle -N runfg
bindkey '^Z' runfg

export FZF_DEFAULT_OPTS=$FZF_DEFAULT_OPTS'
--no-bold
--color=dark
--color=fg:-1,bg:-1,hl:#5fff87,fg+:-1,bg+:-1,hl+:#ffaf5f
--color=info:#af87ff,prompt:#5fff87,pointer:#ff87d7,marker:#ff87d7,spinner:#ff87d7
'

findfolder(){
  local wheretogo=$(fd . $HOME --full-path -p -c always -H -t d -t l -E .git -E node_modules -E .cache -E .local --max-depth 10 -E .npm -E .rustup| fzf --preview 'exa -a1 {}')
  if [[ ! -z "$wheretogo" ]];then
    cd "$wheretogo"
    zle reset-prompt
  fi
}

findfile(){
  local file=$(fd . -c always -t f -L --no-ignore -H --max-depth 8 \
    -E .steam -E .rustup -E node -E .cache -E .zim -E c: -E z: -E proton -E .lock -E SSD -E .nvm -E .asdf -E .local -E .emacs -E .shaders -E .wine -E node_modules -E .yarn -E .git -E .npm -E .cargo \
    | fzf --preview 'bat {} --color always --decorations auto --theme "Dracula" --style rule,numbers')
  if [[ ! -z "$file" ]];then
    vim "$file"
  fi
}

zle -N findfolder
bindkey '^T' findfolder

zle -N findfile
bindkey '^N' findfile
