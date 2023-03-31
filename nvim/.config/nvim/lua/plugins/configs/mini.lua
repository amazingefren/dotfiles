require('mini.basics').setup{
  -- No need to copy this inside `setup()`. Will be used automatically.
  -- Options. Set to `false` to disable.
  options = {
    -- Basic options ('termguicolors', 'number', 'ignorecase', and many more)
    basic = true,
    -- Extra UI features ('winblend', 'cmdheight=0', ...)
    extra_ui = true,
    -- Presets for window borders ('single', 'double', ...)
    win_borders = 'double',
  },
  -- Mappings. Set to `false` to disable.
  mappings = {
    -- Basic mappings (better 'jk', save with Ctrl+S, ...)
    basic = false,
    -- Prefix for mappings that toggle common options ('wrap', 'spell', ...).
    -- Supply empty string to not create these mappings.
    option_toggle_prefix = [[\]],
    -- Window navigation with <C-hjkl>, resize with <C-arrow>
    windows = false,
    -- Move cursor in Insert, Command, and Terminal mode with <M-hjkl>
    move_with_alt = false,
  },
  -- Autocommands. Set to `false` to disable
  autocommands = {
    -- Basic autocommands (highlight on yank, start Insert in terminal, ...)
    basic = true,
    -- Set 'relativenumber' only in linewise and blockwise Visual mode
    relnum_in_visual_mode = true,
  },
}
require('mini.pairs').setup{}
require('mini.surround').setup{}
require('mini.trailspace').setup{}
require('mini.bufremove').setup{}
map('n', '<leader>bd', ':lua MiniBufremove.delete()<CR>')
require('mini.indentscope').setup{}
require('mini.ai').setup{}
require('mini.fuzzy').setup{}
require('mini.splitjoin').setup{}
require('mini.starter').setup{}
require('mini.statusline').setup{
  set_vim_settings = false,
}
-- require('mini.tabline').setup{}

