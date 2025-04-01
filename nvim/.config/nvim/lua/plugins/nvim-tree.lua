return {
  "nvim-tree/nvim-tree.lua",
  dependencies = { "echasnovski/mini.icons" },
  keys = {
    { "<C-/>", "<CMD>NvimTreeToggle<CR>", desc = "Toggle Nvim-Tree"}
  },
  opts = function ()
    local function my_on_attach(bufnr)
      local api = require "nvim-tree.api"
      local function opts(desc)
        return { desc = "nvim-tree: " .. desc, buffer = bufnr, noremap = true, silent = true, nowait = true }
      end
      -- default mappings
      api.config.mappings.default_on_attach(bufnr)

      -- custom mappings
      vim.keymap.set('n', '<C-t>', api.tree.change_root_to_parent,        opts('Up'))
      vim.keymap.set('n', '?',     api.tree.toggle_help,                  opts('Help'))
    end

    local icons = {
      git_placement = 'after',
      modified_placement = 'after',
      padding = ' ',
      glyphs = {
        default = '󰈔',
        folder = {
          arrow_closed = '',
          arrow_open = '',
          default = ' ',
          open = ' ',
          empty = ' ',
          empty_open = ' ',
          symlink = '󰉒 ',
          symlink_open = '󰉒 ',
        },
      },
    }

    local renderer = {
      indent_width = 2,
      indent_markers = {
        enable = true,
        inline_arrows = true,
        icons = { corner = '╰' },
      },
      icons = icons,
    }

    return {
      renderer = renderer,
      on_attach = my_on_attach,
      view = {
        cursorline = false,
        signcolumn = 'no',
        -- width = { max = 38, min = 38 },
      },
      git = {
        ignore = false
      },
      hijack_cursor = true,
      update_focused_file = {
        enable = true
      },
      diagnostics = {
        enable = true
      },
    }
  end
}

