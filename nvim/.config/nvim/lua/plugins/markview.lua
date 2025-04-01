return {
  "OXY2DEV/markview.nvim",
  lazy = false,
  opts = {
    preview = {
      modes = { "n", "i", "no", "c" },
      hybrid_modes = { "i" },
      icon_provider = "mini",
      filetypes = {
        'md',
        'markdown',
        'norg',
        'rmd',
        'org',
        'vimwiki',
        'typst',
        'latex',
        'quarto',
        'Avante',
        'codecompanion',
      },
      ignore_buftypes = {},
      condition = function (buffer)
        local ft, bt = vim.bo[buffer].ft, vim.bo[buffer].bt;

        if bt == "nofile" and (ft == "Avante" or ft == "codecompanion") then

          return true;
        elseif bt == "nofile" then
          return false;
        else
          return true;
        end
      end
    },
  },
}
