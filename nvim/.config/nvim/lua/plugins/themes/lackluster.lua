return {
	"slugbyte/lackluster.nvim",
	lazy = false,
	priority = 1000,
	opts = function()
		local lackluster = require("lackluster")

		local color = lackluster.color -- blue, green, red, orange, black, lack, luster, gray1-9

		local palette = { -- reference
			gray1 = "#000000", -- default
			gray2 = "#191919", -- default
			gray3 = "#2A2A2A", -- default
			gray4 = "#444444", -- default
			gray5 = "#555555", -- default
			gray6 = "#7A7A7A", -- default
			gray7 = "#AAAAAA", -- default
			gray8 = "#CCCCCC", -- default
			gray9 = "#DDDDDD", -- default
			black = "#000000", -- default
			error = "#D70000", -- default
			warn = "#FFAA00", -- default
			special = "#789978", -- default
			hint = "#7788AA", -- default
			lack = "#788090", -- default
			luster = "#DEEEED", -- default
			diff_add_bg = "#002000", -- Darker special
			diff_change_bg = "#001A20", -- Darker warn
			diff_text_bg = "#201A00", -- Darker warn
			diff_delete_bg = "#200000", -- Darker error
		}


		return {
			tweak_syntax = {
				string = color.blue,
				comment = "#4a4a4a",
			},
      -- tweak_background = {
      --   normal = palette.gray2,
      -- },
			tweak_highlight = {
				["DiffAdd"] = { overwrite = true, bg = palette.diff_add_bg },
				["DiffText"] = { overwrite = true, bg = palette.diff_text_bg },
				["DiffChange"] = { overwrite = true, bg = palette.diff_change_bg },
				["DiffDelete"] = { overwrite = true, bg = palette.diff_delete_bg },
				-- ["DiagnosticWarn"] = { overwrite = false, fg = palette.warn },
				-- ["DiagnosticVirtualTextWarn"] = { overwrite = false, bg = palette.warn },
				["DiagnosticVirtualTextOk"] = { overwrite = false, fg = palette.lack },
				["DiagnosticVirtualTextHint"] = { overwrite = false, fg = palette.lack },
				["DiagnosticVirtualTextInfo"] = { overwrite = false, fg = palette.lack },
				["DiagnosticVirtualTextWarn"] = { overwrite = false, fg = palette.warn },
				-- ["DiagnosticVirtualTextError"] = { overwrite = false, fg = palette.hint }
				-- ["Added"] = { overwrite = false, bg = diff_add_bg },
				-- ["Changed"] = { overwrite = false, bg = diff_change_bg },
				-- ["Removed"] = { overwrite = false, bg = diff_delete_bg },
			},
		}
	end,
}
