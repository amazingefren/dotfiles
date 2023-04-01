local has_treesitter, treesitter = pcall(require, 'treesitter')
if not has_treesitter then return end
treesitter.setup {
  highlight = {
    enable = true,
    additional_vim_regex_highlighting = false,
    -- disable = { 'vue', 'html' }
  },
  indent = {
    enable = true
  },
  incremental_selection = {
    enable = false,
    keymaps = {
      init_selection = 'gnn',
      node_incremental = 'grn',
      scope_incremental = 'grc',
      node_decremental = 'grm'
    }
  }
}

local has_tsc, tsc = pcall(require, 'treesitter-context')
if has_tsc then
  tsc.setup{}
end

