-- Modifier-click hyperlink handling.
local wezterm = require 'wezterm'
local act = wezterm.action

local M = {}

local function add_click_binding(bindings, mods, mouse_reporting)
  bindings[#bindings + 1] = {
    event = { Down = { streak = 1, button = 'Left' } },
    mods = mods,
    mouse_reporting = mouse_reporting,
    action = act.Nop,
  }
  bindings[#bindings + 1] = {
    event = { Up = { streak = 1, button = 'Left' } },
    mods = mods,
    mouse_reporting = mouse_reporting,
    action = act.OpenLinkAtMouseCursor,
  }
end

function M.setup(config)
  config.hyperlink_rules = wezterm.default_hyperlink_rules()

  config.mouse_bindings = config.mouse_bindings or {}
  for _, mods in ipairs { 'CTRL', 'ALT' } do
    add_click_binding(config.mouse_bindings, mods, false)
    -- TUI applications can enable mouse reporting. Match that state too so
    -- modifier-click remains a terminal action instead of reaching the TUI.
    add_click_binding(config.mouse_bindings, mods, true)
  end
end

return M
