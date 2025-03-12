_G.map = function(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, { silent = true, desc = desc })
end

_G.lsp_map = function(lhs, rhs, bufnr, desc)
  vim.keymap.set("n", lhs, rhs, { silent = true, buffer = bufnr, desc = desc })
end

_G.load_secret_env = function(opts)
  local env, file_name = opts.env, opts.file_name
  local path = os.getenv("HOME") .. "/.secrets/" .. file_name
  if vim.fn.filereadable(path) == 0 then return nil end
  local content = vim.fn.readfile(path)
  if content and #content > 0 then
    vim.env[env] = vim.trim(content[1])
  end
end
