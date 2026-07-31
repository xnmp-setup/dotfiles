-- Behavioral tests for wezterm_links.lua. Run: lua wezterm_links.test.lua

package.path = (arg[0]:match('(.*/)') or './') .. '?.lua;' .. package.path

local action = {
  Nop = { kind = 'Nop' },
  OpenLinkAtMouseCursor = { kind = 'OpenLinkAtMouseCursor' },
}

package.preload.wezterm = function()
  return {
    action = action,
    default_hyperlink_rules = function()
      return { { regex = 'https?://\\S+', format = '$0' } }
    end,
  }
end

local links = require 'wezterm_links'

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    io.write(string.format('FAIL %s\n  got:  [%s]\n  want: [%s]\n', name, tostring(got), tostring(want)))
  end
end

local config = { mouse_bindings = { { mods = 'NONE' } } }
links.setup(config)

eq('rules/default retained', config.hyperlink_rules[1].format, '$0')
eq('mouse/existing binding retained', config.mouse_bindings[1].mods, 'NONE')
eq('mouse/eight bindings added', #config.mouse_bindings, 9)

local click_bindings = {}
for _, binding in ipairs(config.mouse_bindings) do
  if binding.mods ~= 'NONE' then
    local event = binding.event.Up and 'Up' or 'Down'
    click_bindings[binding.mods .. '/' .. event .. '/' .. tostring(binding.mouse_reporting)] = binding.action.kind
  end
end
for _, mods in ipairs { 'CTRL', 'ALT' } do
  for _, reporting in ipairs { false, true } do
    local suffix = '/' .. tostring(reporting)
    eq('mouse/' .. mods .. '/down' .. suffix, click_bindings[mods .. '/Down' .. suffix], 'Nop')
    eq('mouse/' .. mods .. '/up' .. suffix, click_bindings[mods .. '/Up' .. suffix], 'OpenLinkAtMouseCursor')
  end
end

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
