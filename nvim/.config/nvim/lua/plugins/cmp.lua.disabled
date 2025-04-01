return { 'hrsh7th/nvim-cmp',
  event = "InsertEnter",
  dependencies = {
    'hrsh7th/cmp-nvim-lsp',
    'hrsh7th/cmp-buffer',
    'hrsh7th/cmp-path',
    'hrsh7th/cmp-cmdline',
    'L3MON4D3/LuaSnip',
    'saadparwaiz1/cmp_luasnip',
    'lukas-reineke/cmp-under-comparator',
    'andersevenrud/cmp-tmux',
    'onsails/lspkind.nvim'
  },
  opts = function ()
    local cmp = require'cmp'
    cmp.setup.cmdline('/', {
      sources = {
        { name = 'buffer' }
      }
    })

    cmp.setup.cmdline(':', {
      sources = cmp.config.sources({
        { name = 'path' }
      }, {
        { name = 'cmdline' }
      })
    })

    return {
      fields = { "abbr", "kind", "menu" },
      -- window = {
      --   completion = {
      --     scrollbar = false,
      --     border = border "CmpBorder"
      --   },
      --   documentation = {
      --     border = border "CmpDocBorder",
      --   }
      -- },
      window = {
        completion = {
          winhighlight = "Normal:Pmenu,FloatBorder:Pmenu,Search:None",
          col_offset = -3,
          side_padding = 0,
        },
      },
      formatting = {
        fields = { "kind", "abbr", "menu" },
        format = function(entry, vim_item)
          local kind = require("lspkind").cmp_format({ mode = "symbol_text", maxwidth = 50 })(entry, vim_item)
          local strings = vim.split(kind.kind, "%s", { trimempty = true })
          kind.kind = " " .. (strings[1] or "") .. " "
          kind.menu = "    (" .. (strings[2] or "") .. ")"

          return kind
        end,
      },
      experimental = {
        ghost_text = true
      },
      -- formatting = {
      --   format = require'lspkind'.cmp_format({
      --     mode = 'symbol',
      --     maxwidth = 50,
      --     ellipsis_char = '...',
      --     before = function (entry, vim_item)
      --       vim_item.kind = string.format('%s', vim_item.kind)
      --       vim_item.menu = ({
      --         buffer = "[Buffer]",
      --         nvim_lsp = "[LSP]",
      --         luasnip = "[LuaSnip]",
      --         nvim_lua = "[Lua]",
      --         latex_symbols = "[LaTeX]",
      --         path = "[Path]",
      --         tmux = "[Tmux]"
      --       })[entry.source.name]
      --       return vim_item
      --     end
      --   })
      -- },
      snippet = {
        expand = function (args) require'luasnip'.lsp_expand(args.body) end
      },
      completion = {
        -- autocomplete = false,
        completeopt = "menu, menuone, noselect"
      },
      mapping = {
        ['<C-u>'] = cmp.mapping(cmp.mapping.scroll_docs(-4), {'i', 'c'}),
        ['<C-d>'] = cmp.mapping(cmp.mapping.scroll_docs(4), {'i', 'c'}),
        ['<C-Space>'] = cmp.mapping(cmp.mapping.complete(), {'i', 'c'}),
        ['<C-f>'] = function(fallback)
          if cmp.visible() then
            cmp.confirm({select = true})
          else
            fallback()
          end
        end,
        ['<C-e>'] = cmp.mapping({
          i = cmp.mapping.abort(),
          c = cmp.mapping.close(),
        }),
        ['<C-n>'] = cmp.mapping({
          i = cmp.mapping.select_next_item(),
          c = cmp.mapping.select_next_item()
        }),
        ['<C-p>'] = cmp.mapping({
          i = cmp.mapping.select_prev_item(),
          c = cmp.mapping.select_prev_item()
        }),
        ['<CR>'] = cmp.mapping.confirm({ select = false }), -- Accept currently selected item. Set `select` to `false` to only confirm explicitly selected items.
      },
      sources = cmp.config.sources({
        -- { name = 'codecompanion' },
        { name = 'nvim_lsp' },
        { name = 'luasnip' },
      }, {
        { name = 'tmux' },
        -- { name = 'buffer', max_item_count = 30 },
        { name = 'buffer' },
        { name = 'path' },
      })
    }
  end
}

