return {
	'nvim-telescope/telescope.nvim',
	dependencies = {
		'nvim-lua/plenary.nvim',
	},
	config = function()
		local ts = require('telescope')
		local h_pct = 0.90
		local w_pct = 0.80
		local w_limit = 75
		local standard_setup = {
			borderchars = { '─', '│', '─', '│', '┌', '┐', '┘', '└' },
			preview = { hide_on_startup = true },
			layout_strategy = 'vertical',
			layout_config = {
				vertical = {
					mirror = true,
					prompt_position = 'top',
					width = function(_, cols, _)
						return math.min( math.floor( w_pct * cols ), w_limit )
					end,
					height = function(_, _, rows)
					return math.floor( rows * h_pct )
					end,
					preview_cutoff = 10,
					preview_height = 0.4,
				},
			},
		}
		ts.setup {
			defaults = vim.tbl_extend('error', standard_setup, {
				sorting_strategy = 'ascending',
				path_display = { "filename_first" },
			}),
		}
	end,
}
