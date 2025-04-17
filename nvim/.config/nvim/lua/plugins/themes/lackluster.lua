return {
  "slugbyte/lackluster.nvim",
  lazy = false,
  priority=1000,
  opts = function ()
    local lackluster = require'lackluster'

    local color = lackluster.color -- blue, green, red, orange, black, lack, luster, gray1-9

    return {
      tweak_syntax = {
        string = color.orange,
        comment = "#4a4a4a"
      },
    }
  end
}
