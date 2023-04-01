local cmp = require'cmp'

local function border(hl_name)
  return {
    { "╭", hl_name },
    { "─", hl_name },
    { "╮", hl_name },
    { "│", hl_name },
    { "╯", hl_name },
    { "─", hl_name },
    { "╰", hl_name },
    { "│", hl_name },
  }
end

cmp.setup({
  fields = { "abbr", "kind", "menu" },
  window = {
    completion = {
      side_padding = 1,
      winhighlight = "Normal:CmpPmenu,CursorLine:CmpSel,Search:PmenuSel",
      scrollbar = false,
      border = border "CmpBorder"
    },
    documentation = {
      border = border "CmpDocBorder",
      winhighlight = "Normal:CmpDoc"
    }
  },
  sorting = {
    comparators = {
      cmp.config.compare.offset,
      cmp.config.compare.exact,
      cmp.config.compare.score,
      require "cmp-under-comparator".under,
      cmp.config.compare.kind,
      cmp.config.compare.sort_text,
      cmp.config.compare.length,
      cmp.config.compare.order,
    },
  },
  performance = {
    -- debounce = 10,
    -- -- throttle = 2,
    -- -- fetching_timeout = 0
    debounce = 150,
    -- throttle = 60,
    -- fetching_timeout = 200,
  },
  experimental = {
    ghost_text = true
  },
  formatting = {
    format = require'lspkind'.cmp_format({
      mode = 'symbol',
      maxwidth = 50,
      ellipsis_char = '...',
      before = function (entry, vim_item)
        vim_item.kind = string.format('%s', vim_item.kind)
        vim_item.menu = ({
          buffer = "[Buffer]",
          nvim_lsp = "[LSP]",
          luasnip = "[LuaSnip]",
          nvim_lua = "[Lua]",
          latex_symbols = "[LaTeX]",
          path = "[Path]",
          tmux = "[Tmux]"
        })[entry.source.name]
        return vim_item
      end
    })
  },
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
    { name = 'nvim_lsp' },
    { name = 'luasnip' },
  }, {
    { name = 'tmux' },
    -- { name = 'buffer', max_item_count = 30 },
    { name = 'buffer' },
    { name = 'path' },
  })
})

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


