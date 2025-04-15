-- local default_model = "google/gemini-2.5-pro-preview-03-25"
-- local default_model = "google/gemini-2.5-pro-preview-03-25"

-- local available_models = {
--   "google/gemini-2.0-flash-001",
--   "google/gemini-2.5-pro-preview-03-25",
--   "anthropic/claude-3.7-sonnet",
--   "anthropic/claude-3.5-sonnet",
--   "openai/gpt-4o-mini",
-- }
-- local default_model = "openrouter/quasar-alpha"
-- local default_inline_model = "google/gemini-2.0-flash-001"
local default_model = "google/gemini-2.0-flash-001"

return {
  "olimorris/codecompanion.nvim",
  lazy = true,
  -- branch = "feat/move-to-function-calling",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-treesitter/nvim-treesitter",
    "j-hui/fidget.nvim",
    "nvim-telescope/telescope.nvim",
  },

  keys = function ()
    return {
      { "<leader>aa" , "<CMD>CodeCompanionActions<CR>", mode = {"n", "v"}, desc = "Code Companion Actions" },
      { "<leader>ae" , ":CodeCompanion<CR>", mode = {"v"}, desc = "Code Companion Inline Edit" },
      { "<C-b>" , "<CMD>CodeCompanionChat Toggle<CR>", mode = {"n", "v"}, desc = "Code Companion Chat" },
      { "<C-l>" , "<CMD>CodeCompanionChat Add<CR><Esc>", mode = {"v"}, desc = "Add to Code Companion Chat"}
    }
  end,

  init = function ()
    require("plugins.codecompanion.fidget-spinner"):init()
  end,

  opts = function ()
    vim.cmd([[cab cc CodeCompanion]])
    return {
      strategies = {
        chat = {
          -- adapter = "gemini"
          adapter = "openrouter"
          -- adapter = "copilot"
        },

        inline = {
          -- adapter = "gemini",
          adapter = "openrouter_inline",
          -- adapter = "copilot",
        },
      },
      adapters = {
        openrouter = function()
          load_secret_env({ env = "OPENROUTER_API_KEY", file_name = "openrouter_api_key"})
          return require("codecompanion.adapters").extend("openai_compatible", {
            env = {
              url = "https://openrouter.ai/api",
              api_key = "OPENROUTER_API_KEY",
              chat_url = "/v1/chat/completions",
            },
            schema = {
              model = {
                default = default_model,
              },
            },
          })
        end,
        openrouter_inline = function()
          load_secret_env({ env = "OPENROUTER_API_KEY", file_name = "openrouter_api_key"})
          return require("codecompanion.adapters").extend("openai_compatible", {
            env = {
              url = "https://openrouter.ai/api",
              api_key = "OPENROUTER_API_KEY",
              chat_url = "/v1/chat/completions",
            },
            schema = {
              model = {
                default = default_model,
              },
            },
          })
        end,
        copilot = function ()
          return require("codecompanion.adapters").extend("copilot", {
            schema = {
              model = {
                default = "gemini-2.0-flash-001"
              }
            }
          })
        end,
        gemini = function ()
          load_secret_env({ env = "GEMINI_API_KEY", file_name = "gemini_api_key"})
          return require("codecompanion.adapters").extend("gemini", {
            env = {
              api_key = "GEMINI_API_KEY"
            },
            schema = {
              model = {
                default = "gemini-2.5-pro-exp-03-25"
              }
            }
          })
        end
      },
      display = {
        chat = {
          -- show_settings = true,
          window = {
            layout = "horizontal",
            position = "bottom",
            height = 0.35
            -- width = 0.8,
          }
        },
        diff = {
          -- layout = "horizontal",
          provider = "mini_diff",
          -- opts = {
          --   "internal",
          --   "filler",
          --   "closeoff",
          --   "algorithm:histogram", -- https://adamj.eu/tech/2024/01/18/git-improve-diff-histogram/
          --   "indent-heuristic",  -- https://blog.k-nut.eu/better-git-diffs
          --   "followwrap",
          --   "linematch:120",
          -- },
        }
      },
      -- adapters = {
      -- }
    }
  end
}
