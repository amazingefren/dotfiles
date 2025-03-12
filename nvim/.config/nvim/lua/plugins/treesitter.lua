return {
  "nvim-treesitter/nvim-treesitter",
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
