local opt = vim.opt

opt.shiftwidth = 2
opt.tabstop = 2
opt.smartindent=true
opt.expandtab = true
opt.autoindent = true

opt.ignorecase = true

opt.ruler = false
opt.wrap = true
opt.termguicolors = true
opt.number = true
opt.relativenumber = true
opt.smartcase = true
opt.hidden = true
opt.splitbelow = true
opt.splitright = true
-- opt.laststatus = 3
opt.fillchars = { eob = " " }
opt.numberwidth = 2

-- opt.shortmess:append "sI"

opt.signcolumn = "number"
-- opt.list = true

opt.cursorline = true

opt.undofile = true
opt.undodir = os.getenv('HOME')..'/.undodir'
