vim.g.mapleader = ' '
vim.g.maplocalleader = '\\'
vim.keymap.set("n", "<Space>", "<NOP>")

require("core.api")
require("core.options")
require("core.lazy")
require("core.keymaps")
require("core.diagnostics")

-- vim.cmd[[ colorscheme modus_vivendi ]]
vim.cmd[[ colorscheme lackluster-hack ]]
