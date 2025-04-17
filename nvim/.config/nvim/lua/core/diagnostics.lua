vim.diagnostic.config({
  virtual_text = true,
  signs = true,

  float = {
    show_header = true,
    source = "always",
    border = "rounded",
    focusable = true,
  },

  update_in_insert = false,

  severity_sort = true,
})

vim.opt.updatetime = 300
vim.api.nvim_create_autocmd("CursorHold", {
  callback = function()
    local hover_visible = false
    for _, win in pairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        local filetype = vim.api.nvim_buf_get_option(buf, "filetype")
        if filetype == "markdown" or vim.startswith(filetype, "lsp") then
          hover_visible = true
          break
        end
      end
    end

    if not hover_visible then
      vim.diagnostic.open_float({ focus = false, scope = "cursor" })
    end
  end,
})

-- Add keymaps for diagnostics navigation and display
vim.keymap.set('n', '<leader>e', function()
  vim.diagnostic.open_float()
  -- Add a small delay before attempting to move to the floating window
  vim.defer_fn(function()
    -- Try to find and focus the floating window
    for _, win in pairs(vim.api.nvim_list_wins()) do
      local config = vim.api.nvim_win_get_config(win)
      if config.relative ~= "" then  -- This is a floating window
        vim.api.nvim_set_current_win(win)
        return
      end
    end
  end, 10)
end, { desc = "Show diagnostic in float window and focus it" })
vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, { desc = "Go to previous diagnostic" })
vim.keymap.set('n', ']d', vim.diagnostic.goto_next, { desc = "Go to next diagnostic" })
vim.keymap.set('n', '<leader>dq', vim.diagnostic.setloclist, { desc = "Add diagnostics to location list" })

-- Enable hover diagnostics
vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("UserLspConfig", {}),
  callback = function(ev)
    local opts = { buffer = ev.buf }

    -- Enable hover documentation
    vim.keymap.set('n', 'K', vim.lsp.buf.hover, opts)

    -- Other LSP keymaps
    vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, opts)
    vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action, opts)
    vim.keymap.set({'n', 'v'}, '<leader>fmt', function() vim.lsp.buf.format({ async = true }) end, opts)
  end,
})

