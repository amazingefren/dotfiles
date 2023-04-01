vim.g.mapleader = ' '
map("n", "<Space>", "<NOP>")

-- map("n", "<C-h>", "<C-w>h", opts)
-- map("n", "<C-j>", "<C-w>j", opts)
-- map("n", "<C-k>", "<C-w>k", opts)
-- map("n", "<C-l>", "<C-w>l", opts)

map("v", "<", "<gv")
map("v", ">", ">gv")

map("n", "<Leader>y", '"+y')
map("v", "<Leader>y", '"+y')

map("v", "<S-j>", ":m .+1<CR>gv=gv")
map("v", "<S-k>", ":m .-2<CR>gv=gv")

map("n", "<tab>", ":bnext<CR>")
map("n", "<S-tab>", ":bprevious<CR>")
map("n", "<leader><tab>", ":tabnext<CR>")
map("n", "<leader><S-tab>", ":tabprevious<CR>")
map("n", "<leader>tn", ":tabedit %<CR>")
map("n", "<leader>td", ":tabclose<CR>")

map("n", "<M-h>", ":vertical resize +3<CR>")
map("n", "<M-j>", ":res -1<CR>")
map("n", "<M-k>", ":res +1<CR>")
map("n", "<M-l>", ":vertical resize -3<CR>")

-- map("v", "<leader>qp", '"_dP')
-- map("n", "<leader>qd", '"_d')
-- map("v", "<leader>qd", '"_d')
map("n", "Q", "<NOP>", {})


