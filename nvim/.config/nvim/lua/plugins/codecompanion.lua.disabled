return {
  "olimorris/codecompanion.nvim",
  lazy = true,
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-treesitter/nvim-treesitter",
    "j-hui/fidget.nvim",
  },

  keys = {
    { "<leader>aa" , "<CMD>CodeCompanionActions<CR>", mode = {"n", "v"}, desc = "Code Companion Actions" },
    { "<leader>ae" , ":CodeCompanion<CR>", mode = {"v"}, desc = "Code Companion Inline Edit" },
    { "<C-b>" , "<CMD>CodeCompanionChat Toggle<CR>", mode = {"n", "v"}, desc = "Code Companion Chat" },
    { "<C-l>" , "<CMD>CodeCompanionChat Add<CR>", mode = {"v"}, desc = "Add to Code Companion Chat"}
  },

  init = function ()
    require("plugins.codecompanion.fidget-spinner"):init()
  end,

  opts = function ()
    vim.cmd([[cab cc CodeCompanion]])
    return {
      strategies = {
        chat = {
          adapter = "copilot"
        },

        inline = {
          adapter = "copilot",
        },
      },
      display = {
        -- diff = {
        --   provider = "mini_diff"
        -- }
      },
      adapters = {
        copilot = function ()
          return require("codecompanion.adapters").extend("copilot", {
            schema = {
              model = {
                default = "gemini-2.0-flash-001"
              }
            }
          })
        end
      }
    }
  end
}
