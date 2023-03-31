local Ut = require("Comment.utils")
local Op = require("Comment.opfunc")

function _G.__toggle_visual(vmode)
  local lcs, rcs = Ut.unwrap_cstr(vim.bo.commentstring)
  local srow, erow, lines = Ut.get_lines(vmode, Ut.ctype.line)

  Op.linewise(
    {
      cfg = {padding = true, ignore = nil},
      cmode = Ut.cmode.toggle,
      lines = lines,
      lcs = lcs,
      rcs = rcs,
      erow = erow,
      srow = srow
    }
  )
end

require'Comment'.setup()
map("n", "<C-_>", ":lua require('Comment.api').toggle()<cr>")
map("x", "<C-_>", ":lua require('Comment.api').gc(vim.fn.visualmode())<cr>") -- Line Comment

