return {
  {
    "echasnovski/mini.icons",
    opts = {},
    lazy = true,
    specs = {
      { "nvim-tree/nvim-web-devicons", enabled = false, optional = true },
    },
    init = function()
      package.preload["nvim-web-devicons"] = function()
        require("mini.icons").mock_nvim_web_devicons()
        return package.loaded["nvim-web-devicons"]
      end
    end,
  },
  { "echasnovski/mini.ai", opts = {} },
  { "echasnovski/mini.comment", opts = {} },
  { "echasnovski/mini.diff", opts = {} },
  { "echasnovski/mini.move",
  opts = {
    mappings = {
      left = '<S-h>',
      down = '<S-j>',
      up = '<S-k>',
      right = '<S-l>'
    }
  }
},
{ "echasnovski/mini.pairs", opts = {} },
{ "echasnovski/mini.splitjoin", opts = {} },
{ "echasnovski/mini.surround", opts = {} },
-- { "echasnovski/mini.statusline", opts = {} },
{ "echasnovski/mini.tabline", opts = {} },
{ "echasnovski/mini.trailspace", opts = {} },
{ "echasnovski/mini.pick", opts = {} },
}
