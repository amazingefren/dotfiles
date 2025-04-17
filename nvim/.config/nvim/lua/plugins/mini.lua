return {
  {
    "echasnovski/mini.icons",
    config = function ()
      require("mini.icons").setup{}
      require("mini.icons").mock_nvim_web_devicons()
    end
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
-- { "echasnovski/mini.tabline", opts = {} },
{ "echasnovski/mini.trailspace", opts = {} },
{ "echasnovski/mini.pick", opts = {} },
{ "echasnovski/mini.jump", opts = {} },
}
