-- Behavioral tests for wezterm_themes.lua. Run: lua wezterm_themes.test.lua

package.path = (arg[0]:match('(.*/)') or './') .. '?.lua;' .. package.path
package.preload.wezterm = function() return { action = {} } end

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

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
