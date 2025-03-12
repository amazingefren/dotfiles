-- vim.cmd[[
-- nnoremap <F5> :let _s=@/<Bar>:%s/\s\+$//e<Bar>:let @/=_s<Bar><CR>
-- nnoremap <F6> :!jq<CR>
-- vnoremap <F6> :'<,'>!jq<CR>
-- ]]

-- Formatting
map("n", "<F5>", ":let _s=@/<Bar>:%s/\\s\\+$//e<Bar>:let @/=_s<Bar><CR>", "Remove trailspaces")
map("n", "<F6>", ":!jq<CR>", "Format JSON file")
map("v", "<F6>", ":'<,'>!jq<CR>", "Format JSON from selection")

-- Easier access to beginning and end of lines
map("n", "<M-h>", "^", "Go to beginning of line")
map("n", "<M-l>", "$", "Go to end of line")

-- -- Better window navigation
-- map("n", "<C-h>", "<C-w><C-h>", "Navigate windows to the left")
-- map("n", "<C-j>", "<C-w><C-j>", "Navigate windows down")
-- map("n", "<C-k>", "<C-w><C-k>", "Navigate windows up")
-- map("n", "<C-l>", "<C-w><C-l>", "Navigate windows to the right")

-- Resize with arrows
map("n", "<C-Up>", ":resize +2<CR>", "Increase window height")
map("n", "<C-Down>", ":resize -2<CR>", "Decrease window height")
map("n", "<C-Left>", ":vertical resize +2<CR>", "Increase window width")
map("n", "<C-Right>", ":vertical resize -2<CR>", "Decrease window width")

-- Navigate buffers
map("n", "<S-l>", ":bnext<CR>", "Next buffer")
map("n", "<S-h>", ":bprevious<CR>", "Previous buffer")

-- Stay in indent mode
map("v", "<", "<gv", "Decrease indent")
map("v", ">", ">gv", "Increase indent")

map("t", "<C-v><Esc>", "<C-\\><C-n>", "Exit terminal mode")
map("t", "<C-v><C-c>", "<C-\\><C-n>", "Exit terminal mode")

map("n", "<Leader>y", '"+y', "Yank to + register" )
map("v", "<Leader>y", '"+y', "Yank to + register" )
