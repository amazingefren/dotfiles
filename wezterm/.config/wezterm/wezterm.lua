local wezterm = require('wezterm')

local function isViProcess(pane)
    local process_info = pane:get_foreground_process_info()
    if process_info then
        local process_name = process_info.executable
        if process_name:find("vim$") or process_name:find("nvim$") then
            return true
        end
    end
    --
    -- -- Fall back to checking the title if process info isn't available
    -- return pane:get_title():find("^n?vim") ~= nil
    -- return pane:get_title():find("n?vim") ~= nil
end

local function conditionalActivatePane(window, pane, pane_direction, vim_direction)
    if isViProcess(pane) then
        window:perform_action(
            wezterm.action.SendKey({ key = vim_direction, mods = 'CTRL' }),
            pane
        )
    else
        window:perform_action(wezterm.action.ActivatePaneDirection(pane_direction), pane)
    end
end

wezterm.on('ActivatePaneDirection-right', function(window, pane)
    conditionalActivatePane(window, pane, 'Right', 'l')
end)
wezterm.on('ActivatePaneDirection-left', function(window, pane)
    conditionalActivatePane(window, pane, 'Left', 'h')
end)
wezterm.on('ActivatePaneDirection-up', function(window, pane)
    conditionalActivatePane(window, pane, 'Up', 'k')
end)
wezterm.on('ActivatePaneDirection-down', function(window, pane)
    conditionalActivatePane(window, pane, 'Down', 'j')
end)

local config = wezterm.config_builder()

config.max_fps = 120
config.font = wezterm.font { family = "TX02 Nerd Font", italic = false }
config.harfbuzz_features = {"calt=0", "clig=0", "liga=0"}
config.font_size = 12
config.line_height = 1.0
config.freetype_load_target = "Normal"
-- config.color_scheme = 'Modus-Vivendi'
config.color_scheme = 'Ef-Bio'

-- Make inactive pane less visible
config.inactive_pane_hsb = {
    saturation = 0.9,
    brightness = 0.6
}

-- Reduce padding
config.window_padding = {
  left = 0,
  right = 0,
  top = 0,
  bottom = 0,
}

-- Use basic tab bar
-- config.use_fancy_tab_bar = false

-- MacOS full screen
-- config.native_macos_fullscreen_mode = true

-- Keys and mappings
-- config.leader = { key = 'a', mods = 'CTRL', timeout_milliseconds = 1000 }
-- config.leader = { key = 'a', mods = 'CTRL', timeout_milliseconds = 1000 }
config.leader = { key = 'a', mods = 'CTRL', timeout_milliseconds = 1000 }
config.keys = {
    -- More easy split key mappings
    { key = '|', mods = 'LEADER|SHIFT', action = wezterm.action.SplitHorizontal { domain = 'CurrentPaneDomain' }, },
    { key = '-', mods = 'LEADER', action = wezterm.action.SplitVertical { domain = 'CurrentPaneDomain' }, },

    -- Send "CTRL-A" to the terminal when pressing CTRL-A, CTRL-A
    { key = 'a', mods = 'LEADER|CTRL', action = wezterm.action.SendString '\x01', },

    -- Integration with neovim panes
    { key = 'h', mods = 'CTRL', action = wezterm.action.EmitEvent('ActivatePaneDirection-left') },
    { key = 'j', mods = 'CTRL', action = wezterm.action.EmitEvent('ActivatePaneDirection-down') },
    { key = 'k', mods = 'CTRL', action = wezterm.action.EmitEvent('ActivatePaneDirection-up') },
    { key = 'l', mods = 'CTRL', action = wezterm.action.EmitEvent('ActivatePaneDirection-right') },

    -- Full screen
    -- { key = 'Enter', mods = 'OPT', action = wezterm.action.ToggleFullScreen }

    {
        key = 'Backspace',
        mods = 'CTRL',
        action = wezterm.action.SendKey {
            key = 'w',
            mods = 'CTRL',
        }
    }
}

require('plugin.wez-tmux').apply_to_config(config, {})

-- Configure SSH domains
config.ssh_domains = wezterm.default_ssh_domains()
for _, dom in ipairs(config.ssh_domains) do
  dom.local_echo_threshold_ms = 10000
end

return config
