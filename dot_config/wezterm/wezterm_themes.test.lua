-- Behavioral tests for wezterm_themes.lua. Run: lua wezterm_themes.test.lua

package.path = (arg[0]:match('(.*/)') or './') .. '?.lua;' .. package.path
local events = {}
package.preload.wezterm = function()
  return {
    action = { InputSelector = function(value) return value end },
    on = function(name, callback) events[name] = callback end,
    action_callback = function(callback) return callback end,
    get_builtin_color_schemes = function() return {} end,
  }
end

local themes = require 'wezterm_themes'

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    io.write(string.format('FAIL %s\n  got:  [%s]\n  want: [%s]\n', name, tostring(got), tostring(want)))
  end
end

eq(
  'rewrites applied appearance module',
  themes.replace_color_scheme("config.font_size = 14\nconfig.color_scheme = 'Cosmic Dusk'\n", 'Rapture'),
  "config.font_size = 14\nconfig.color_scheme = 'Rapture'\n"
)

eq(
  'preserves content without a scheme assignment',
  themes.replace_color_scheme('return config\n', 'Rapture'),
  'return config\n'
)

eq(
  'escapes quotes in custom scheme names',
  themes.replace_color_scheme("config.color_scheme='Old'", "Builder's Dark"),
  "config.color_scheme='Builder\\'s Dark'"
)

-- The interactive picker must update opacity as well as palette, in both
-- directions, and preserve unrelated overrides.
local path = os.tmpname()
local file = assert(io.open(path, 'w'))
file:write("config.color_scheme = 'Dark'\n")
file:close()
themes.setup({}, {
  persist_path = path,
  resolve_scheme = function(_, name) return name end,
  tab_bar_colors = function(name) return { background = name } end,
  background_opacity = function(name) return name == 'Light' and 0.97 or 0.92 end,
})
local overrides = { font_size = 17 }
local selector
local window = {
  perform_action = function(_, value) selector = value end,
  get_config_overrides = function() return overrides end,
  set_config_overrides = function(_, value) overrides = value end,
}
events['augment-command-palette'](window, {})[1].action(window, {})
selector.action(window, {}, 'Light', 'Light')
eq('picker gives light backgrounds subtle transparency', overrides.window_background_opacity, 0.97)
eq('picker preserves unrelated overrides', overrides.font_size, 17)
selector.action(window, {}, 'Dark', 'Dark')
eq('picker restores dark transparency', overrides.window_background_opacity, 0.92)
eq('picker changes the displayed scheme', overrides.color_scheme, 'Dark')
os.remove(path)

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
