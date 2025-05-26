return {
	"stevearc/conform.nvim",
	opts = {
		formatters_by_ft = {
			lua = { "stylua" },
		},
	},
	keys = function ()
		local Conform = require'conform'
		return {
			{ "<leader>fb", function () Conform.format() end, desc = "Format Buffer" },
		}
	end
}
