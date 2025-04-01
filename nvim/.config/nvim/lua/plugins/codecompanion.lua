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
    { "<C-l>" , "<CMD>CodeCompanionChat Add<CR><Esc>", mode = {"v"}, desc = "Add to Code Companion Chat"}
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
        diff = {
          -- layout = "horizontal",
          provider = "mini_diff",
          opts = {
            "internal",
            "filler",
            "closeoff",
            "algorithm:histogram", -- https://adamj.eu/tech/2024/01/18/git-improve-diff-histogram/
            "indent-heuristic",  -- https://blog.k-nut.eu/better-git-diffs
            "followwrap",
            "linematch:120",
          },
        }
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
