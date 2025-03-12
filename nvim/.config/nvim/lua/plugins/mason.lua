return {
  {
    "williamboman/mason.nvim",
    opts = {}
  },
  {
    "williamboman/mason-lspconfig.nvim",
    dependencies = { "williamboman/mason.nvim", "neovim/nvim-lspconfig" },
    config = function()
      require("mason-lspconfig").setup {}

      -- Automatically configure all installed LSPs
      local lspconfig = require("lspconfig")
      -- local capabilities = require('blink.cmp').get_lsp_capabilities()
      require("mason-lspconfig").setup_handlers {
        function(server_name)
          lspconfig[server_name].setup { capabilities = capabilities }
        end,

        ["lua_ls"] = function()
          lspconfig.lua_ls.setup {
            capabilities = capabilities,
            settings = {
              Lua = {
                diagnostics = { globals = { "vim" } }, -- Recognize 'vim' global for Neovim
              },
            },
          }
        end,
      }
    end,
  },
}
