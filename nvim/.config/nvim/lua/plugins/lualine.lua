return {
  'nvim-lualine/lualine.nvim',
  opts = {
    options = {
      icons_enabled = true,
      theme = 'auto',
      -- component_separators = { left = '', right = ''},
      -- section_separators = { left = '', right = ''},
      component_separators = { left = '', right = ''},
      section_separators = { left = '', right = ''},
      disabled_filetypes = {
        statusline = {},
        winbar = {},
      },
      ignore_focus = {},
      always_divide_middle = true,
      always_show_tabline = true,
      globalstatus = false,
      refresh = {
        statusline = 100,
        tabline = 100,
        winbar = 100,
      }
    },
    -- sections = {
    --   lualine_a = {'filename'},
    --   lualine_b = {},
    --   lualine_c = {},
    --   lualine_x = {'location'},
    --   lualine_y = {},
    --   lualine_z = {}
    -- },
    -- inactive_sections = {
    --   lualine_a = {},
    --   lualine_b = {},
    --   lualine_c = {'filename'},
    --   lualine_x = {},
    --   lualine_y = {},
    --   lualine_z = {}
    -- },
    sections = {},
    inactive_sections = {},
    tabline = {
      lualine_a = {'mode'},
      lualine_b = {},
      lualine_c = {'filename'},
      lualine_x = {'branch'},
      lualine_y = {'progress', 'location'},
      lualine_z = {'tabs'}
    },
    winbar = {},
    inactive_winbar = {},
    extensions = {}
  },
}
