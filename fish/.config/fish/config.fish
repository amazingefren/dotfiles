if status is-interactive
   alias ls eza
   alias la 'eza -a'
   alias ll 'eza -l'
   alias lla 'eza -la'
   alias lt 'eza --tree'

   alias lg 'lazygit'

   set fish_greeting

   function fish_user_key_bindings
      fish_vi_key_bindings
      bind \cz 'fg 2>/dev/null; commandline -f repaint'
      bind -M insert \cz 'fg 2>/dev/null; commandline -f repaint'
      bind \cf accept-autosuggestion
      bind -M insert \cf accept-autosuggestion

      fzf_configure_bindings --directory=\ct
   end

   set fzf_directory_opts --bind "ctrl-o:execute($EDITOR {} &> /dev/tty)"

   # add Pulumi to the PATH
   set -g fish_user_paths "/home/efren/.pulumi/bin" $fish_user_paths

end
