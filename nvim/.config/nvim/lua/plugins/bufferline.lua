return {
  'akinsho/bufferline.nvim',
  version = "*",
  dependencies = 'nvim-tree/nvim-web-devicons',
  opts = function ()
    local bufferline = require'bufferline'
    return {
      options = {
        indicator = { style = 'underline' },
        show_buffer_icons = false
      }
    }
  end
}

