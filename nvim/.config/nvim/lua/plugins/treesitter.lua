return {
  "nvim-treesitter/nvim-treesitter",
  dependencies = {
    {"nvim-treesitter/nvim-treesitter-context", opts = {}}
  },
  build = ":TSUpdate",
  config = function()
    require("nvim-treesitter.configs").setup {
      auto_install = true,
      ignore_install = { "zig" },
      highlight = {
        enable = true,
        disable = { "zig" },
      },
      indent = { enable = true },
    }
  end,
}
