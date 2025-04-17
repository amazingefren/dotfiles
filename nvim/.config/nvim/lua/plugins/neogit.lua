return {
  "NeogitOrg/neogit",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "sindrets/diffview.nvim",

    "echasnovski/mini.pick",
  },
  keys = {
    { "<leader>lg", "<cmd>Neogit<cr>", desc = "Open Neogit" },
  }
}
