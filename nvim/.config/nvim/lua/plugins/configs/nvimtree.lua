local nvim_tree = require'nvim-tree'

map("n", "<C-s>", ":NvimTreeToggle<CR>")

nvim_tree.setup{
 git = {
   ignore = false
 },
 hijack_cursor = true,
 update_focused_file = {
   enable = true
 },
 diagnostics = {
   enable = true
 },
}
