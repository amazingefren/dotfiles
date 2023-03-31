require'gitsigns'.setup {
  signs = {
    add = {hl = "GitSignsAdd", text = nil, numhl = "GitSignsAdd"},
    change = {hl = "GitSignsChange", text = nil, numhl = "GitSignsChange"},
    delete = {hl = "GitSignsDelete", text = nil, numhl = "GitSignsDelete"},
    topdelete = {hl = "GitSignsDelete", text = nil, numhl = "GitSignsDelete"},
    changedelete = {hl = "GitSignsChange", text = nil, numhl = "GitSignsChange"}
  },
  numhl = true,
  signcolumn = false
}
