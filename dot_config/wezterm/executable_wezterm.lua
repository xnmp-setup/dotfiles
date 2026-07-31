-- WezTerm config — Windows port of the Ghostty config (dot_config/ghostty/config).
-- Each behavior cluster owns its state and event handlers; this file only wires
-- the modules together. See the NOTES block below for features that do not port.

local wezterm = require 'wezterm'
local config = wezterm.config_builder()

local navigation = require 'wezterm_navigation'
local background = require('wezterm_background').setup(config)
local windowing = require('wezterm_windowing').setup()
local utilities = require('wezterm_utilities').setup(config)
local close = require('wezterm_close').setup()

-- Restore normal panes from the last GUI session. Background panes are excluded
-- because their dedicated mux domains already outlive the GUI.
require('sessionstore').setup { dir = background.socket_dir }

local agent = require('wezterm_agent').setup()
local appearance = require 'wezterm_appearance'
appearance.apply(config)

require('wezterm_keybindings').apply(config, {
  navigation = navigation,
  background = background,
  windowing = windowing,
  agent = agent,
  close = close,
  utilities = utilities,
})

require('wezterm_tabbar').setup {
  agent = agent,
  status_update_interval_ms = appearance.status_update_interval_ms,
}
require('wezterm_themes').setup(config, {
  persist_path = appearance.config_path,
})

return config

-- ---------- NOTES: things that don't port from the Ghostty config ----------
-- * quick-terminal-* : macOS-only Ghostty feature. On Windows your AutoHotkey
--   F9 dropdown (terminal_dropdown.ahk) fills this role instead.
-- * custom-shader (enter-ripple.glsl) : WezTerm has no GLSL shader hook.
-- * font-thicken / font-thicken-strength : no direct equivalent. Closest is
--   picking a heavier font weight via config.font = wezterm.font(name, {weight=...}).
-- * write_screen_file:paste (ctrl+shift+c) : no equivalent; left as default copy.
-- * ctrl+,=open_config and ctrl+shift+t=undo : no built-in WezTerm actions.
-- * SUPER == the Windows key, which Windows reserves (Win+L locks, Win+P projects)
--   and your AHK script also intercepts (Win+Arrows, LWin remap). The super+arrow
--   pane nav and super+l/p/; binds likely won't reach WezTerm. If you want
--   them to actually fire, remap those to ALT or CTRL+ALT.
