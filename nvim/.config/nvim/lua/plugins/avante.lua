-- return {}
return {
  "yetone/avante.nvim",
  event = "VeryLazy",
  lazy = false,
  version = false, -- Set this to "*" to always pull the latest release version, or set it to false to update to the latest code changes.
  keys = function ()
    return {
      {"<C-b>", "<CMD>AvanteToggle<CR>", mode = {"n", "i", "v"}, desc = "Toggle Avante"}
      -- {
        --   "<leader>ac",
        --   function()
          --     -- Store current window
          --     local current_win = vim.api.nvim_get_current_win()
          --     vim.cmd("new")
          --     local temp_win = vim.api.nvim_get_current_win()
          --     local temp_buf = vim.api.nvim_get_current_buf()
          --     -- Run AvanteChat command
          --     vim.cmd("AvanteChat")
          --     -- Return focus to original window
          --     vim.api.nvim_set_current_win(current_win)
          --     -- Close the temporary window (buffer will be closed along with it)
          --     pcall(vim.api.nvim_win_close, temp_win, true)
          --   end,
          --   desc = "Open Avante Chat without current file in context"
          -- }
        }
      end,
      opts = function ()
        load_secret_env({ env = "KAGI_API_KEY", file_name = "kagi_api_key"})
        return {
          provider = "copilot",
          -- auto_suggestions_provider = "copilot",
          copilot = {
            model = "claude-3.7-sonnet",
            -- model = "gpt-4o",         -- GPT-4o (default)
            -- model = "claude-3.5-sonnet", -- Claude Sonnet 3.5
            -- model = "gemini-2.0-flash", -- Gemini 2.0 Flash
            -- model = "o1",              -- o1
            -- model = "o3-mini",         -- o3-mini
            -- Available models for Copilot Code Completion:
            -- model = "gpt-3.5-turbo",  -- GPT-3.5 Turbo (default for code completion)
            -- model = "gpt-4o-mini",    -- GPT-4o-mini
          },

          web_search_engine = {
            provider = 'kagi'
          },
        }
      end,
      -- if you want to build from source then do `make BUILD_FROM_SOURCE=true`
      build = "make",

      -- build = "powershell -ExecutionPolicy Bypass -File Build.ps1 -BuildFromSource false" -- for windows
      dependencies = {
        "nvim-treesitter/nvim-treesitter",
        "stevearc/dressing.nvim",
        "nvim-lua/plenary.nvim",
        "MunifTanjim/nui.nvim",
        "echasnovski/mini.pick",
        "nvim-telescope/telescope.nvim",
        "ibhagwan/fzf-lua",
        "zbirenbaum/copilot.lua",
        {
          "HakonHarnes/img-clip.nvim",
          event = "VeryLazy",
          opts = {
            default = {
              embed_image_as_base64 = false,
              prompt_for_file_name = false,
              drag_and_drop = {
                insert_mode = true,
              },
              use_absolute_path = true,
            },
          },
        },
      },
    }
