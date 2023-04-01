local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"

if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

local plugins = {
  "nvim-lua/plenary.nvim", -- Async

  -- Colorschemes --
  "Mofiqul/vscode.nvim",
  { "sainnhe/sonokai",
    init = function()
      vim.g.sonokai_style = 'espresso'
      vim.g.sonokai_better_performance = 1
      vim.cmd[[ colorscheme sonokai ]]
    end,
    priority = 100,
    lazy = false
  },

  { "kyazdani42/nvim-web-devicons", lazy=true },

  -- IDE --
  "neovim/nvim-lspconfig",
  { "williamboman/mason.nvim",
    dependencies = {
      "williamboman/mason-lspconfig.nvim",
      "folke/neodev.nvim"
    },
    config = function()
      require'plugins.configs.mason'
    end
  },

  { "mfussenegger/nvim-dap",
    dependencies = {
      "rcarriga/nvim-dap-ui"
    },
    config = function()
      -- require'plugins.configs.dap'
    end
  },

  { "kdheepak/lazygit.nvim",
    config = function()
      map('n', '<leader>lg', '<cmd>:LazyGit<cr>')
    end
  },

  "jose-elias-alvarez/null-ls.nvim", -- Lint & Format
  "folke/trouble.nvim", -- Trouble Menu

  { "kyazdani42/nvim-tree.lua",
    config = function()
      require'plugins.configs.nvimtree'
    end
  },

  { "mbbill/undotree",
    config = function()
      -- require'plugins.configs.undotree'
      vim.api.nvim_set_keymap('n', '<Leader>uu', ':UndotreeToggle<CR>', {silent = false})
      vim.opt.undofile = true
      vim.opt.undodir = os.getenv('HOME')..'/.undodir'
    end,
  },

  { 'hrsh7th/nvim-cmp',
    dependencies = {
      'hrsh7th/cmp-nvim-lsp',
      'hrsh7th/cmp-buffer',
      'hrsh7th/cmp-path',
      'hrsh7th/cmp-nvim-lsp',
      'hrsh7th/cmp-cmdline',
      'L3MON4D3/LuaSnip',
      'saadparwaiz1/cmp_luasnip',
      'lukas-reineke/cmp-under-comparator',
      'andersevenrud/cmp-tmux',
      'onsails/lspkind.nvim'
    },
    config = function()
      require'plugins.configs.cmp'
    end
  },

  { "NvChad/nvim-colorizer.lua",
    config = function()
      require'plugins.configs.colorizer'
    end
  },

  { "nvim-treesitter/nvim-treesitter",
    dependencies = {
      'nvim-treesitter/nvim-treesitter-context'
    },
    priority = 120,
    lazy = false,
    cmd = 'TSUpdate',
    config = function()
      require'plugins.configs.treesitter'
    end
  },

  { 'numToStr/Comment.nvim',
    config = function()
      require'plugins.configs.comment'
    end
  },

  { 'lewis6991/gitsigns.nvim',
    config = function()
      require'plugins.configs.gitsigns'
    end
  },

  { 'NMAC427/guess-indent.nvim',
    config = function()
      require'guess-indent'.setup{}
    end
  },

  { "anuvyklack/hydra.nvim",
    config = function()
      --require'plugins.configs.hydra'
    end
  },

  { "themercorp/themer.lua",
    -- config = function()
    --   require("themer").setup({
    --       colorscheme = "monokai_pro",
    --       styles = {
    --           -- ["function"] = { style = 'italic' },
    --           -- functionbuiltin = { style = 'italic' },
    --           -- variable = { style = 'italic' },
    --           -- variableBuiltIn = { style = 'italic' },
    --           -- parameter  = { style = 'italic' },
    --       },
    --   })
    -- end
  },

  { 'sindrets/diffview.nvim',
    config = function()
      require'plugins.configs.diffview'
    end
  },

  { "akinsho/bufferline.nvim",
    config = function()
      -- require'plugins.configs.bufferline'
      require'bufferline'.setup{}
    end
  },

  -- Performance --
  { "lewis6991/impatient.nvim",
    init = function()
      require'impatient'
    end,
    priority = 999,
    lazy = false,
  },

  -- Util
  'christoomey/vim-tmux-navigator', -- Move Splits Using <C-{h/j/k/l}>
  { "echasnovski/mini.nvim",
    config = function()
      require'plugins.configs.mini'
    end
  },

  { 'nvim-telescope/telescope.nvim',
    dependencies = {
      'nvim-lua/plenary.nvim',
      { 'nvim-telescope/telescope-fzf-native.nvim', build = 'make' }
    },
    config = function()
      require'plugins.configs.telescope'
    end
  }

}

local opts = {}

require"lazy".setup(plugins, opts)
