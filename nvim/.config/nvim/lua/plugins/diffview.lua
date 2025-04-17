return {
  'sindrets/diffview.nvim',
  opts = {
    enhanced_diff_hl = true,
    key_bindings = {
      file_history_panel = { q = '<Cmd>DiffviewClose<CR>' },
      file_panel = { q = '<Cmd>DiffviewClose<CR>' },
      view = { q = '<Cmd>DiffviewClose<CR>' },
    },
  }
}
