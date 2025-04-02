return {
  {
    'saghen/blink.cmp',
    version = '*',

    dependencies = {
      { 'disrupted/blink-cmp-conventional-commits' },
      -- "fang2hou/blink-copilot"
    },

    ---@module 'blink.cmp'
    ---@type blink.cmp.Config
    opts = {
      cmdline = { enabled = true, },
      fuzzy = {
        sorts = {
          'exact',
          -- defaults
          'score',
          'sort_text',
        },
      },

      completion = {
        menu = {
          border = 'none',
          auto_show = true,
          draw = {
            columns = {
              { "kind_icon" }, { "label", "label_description", gap = 1 }, { "kind" }
            }
          }
        },
        keyword = { range = 'prefix' },
        list = { selection = { preselect = false, auto_insert = true } },
        documentation = { auto_show = true, auto_show_delay_ms = 100 },
        ghost_text = { enabled = true, show_with_menu = false },
      },

      signature = { enabled = true, window = { border = 'none' } },

      keymap = {
        preset = 'none',
        ['<C-space>'] = { 'show', 'show_documentation', 'hide_documentation' },
        ['<C-e>'] = { 'hide' },
        ['<C-f>'] = { 'select_and_accept', 'fallback' },

        ['<C-p>'] = { 'select_prev', 'fallback' },
        ['<C-n>'] = { 'select_next', 'fallback' },

        ['<C-u>'] = { 'scroll_documentation_up', 'fallback' },
        ['<C-d>'] = { 'scroll_documentation_down', 'fallback' },

        -- ['<Tab>'] = { 'snippet_forward', 'fallback' },
        ['<Tab>'] = {
          -- function(cmp)
          --
          --   if cmp.snippet_active() then return cmp.accept()
          --
          --   if not cmp.is_visible() then return end
          --   local completion_list = require('blink.cmp.completion.list')
          --   if completion_list.selected_item_idx then
          --     cmp.select_and_accept()
          --     return true
          --   else
          --     return false
          --   end
          -- end,
          'snippet_forward',
          'fallback'
        },
        ['<S-Tab>'] = { 'snippet_backward', 'fallback' },

        ['<CR>'] = {
          function(cmp)
            if not cmp.is_visible() then return end

            local completion_list = require('blink.cmp.completion.list')
            if completion_list.selected_item_idx then
              cmp.select_and_accept()
              return true
            else
              return false
            end
          end, 'fallback' },
        -- ['<C-k>'] = { 'show_signature', 'hide_signature', 'fallback' },
      },

      appearance = {
        nerd_font_variant = 'normal' -- Set to 'mono' for 'Nerd Font Mono' or 'normal' for 'Nerd Font'
      },

      -- Default list of enabled providers defined so that you can extend it
      -- elsewhere in your config, without redefining it, due to `opts_extend`
      sources = {
        default = {
          'conventional_commits', -- add it to the list
          -- 'copilot',
          'lsp',
          'path',
          'snippets',
          'buffer'
        },
        providers = {
          conventional_commits = {
            name = 'Conventional Commits',
            module = 'blink-cmp-conventional-commits',
            enabled = function()
              return vim.bo.filetype == 'gitcommit'
            end,
            ---@module 'blink-cmp-conventional-commits'
            ---@type blink-cmp-conventional-commits.Options
            opts = {}, -- none so far
          },
        }
      },

      snippets = { preset = "luasnip" },
    },
    opts_extend = { "sources.default" }
  }
}
