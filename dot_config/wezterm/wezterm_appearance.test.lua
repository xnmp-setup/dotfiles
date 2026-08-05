-- Behavioral tests for the pure color derivation in wezterm_appearance.lua.
-- Run: lua wezterm_appearance.test.lua

package.path = (arg[0]:match('(.*/)') or './') .. '?.lua;' .. package.path

local builtins = {
  ['Builtin Scheme'] = { background = '#101010', foreground = '#f0f0f0', selection_bg = '#404040' },
  -- Some builtins define no selection colors at all.
  ['Spartan'] = { background = '#000000', foreground = '#ffffff' },
}

package.preload.wezterm = function()
  return {
    action = {},
    config_file = '/home/u/.config/wezterm/wezterm.lua',
    target_triple = 'x86_64-unknown-linux-gnu',
    color = { get_builtin_schemes = function() return builtins end },
  }
end

local appearance = require 'wezterm_appearance'

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    io.write(string.format('FAIL %s\n  got:  [%s]\n  want: [%s]\n', name, tostring(got), tostring(want)))
  end
end

-- ---------- mix ----------
eq('mix at t=0 is the start color', appearance.mix('#102030', '#ffffff', 0), '#102030')
eq('mix at t=1 is the end color', appearance.mix('#102030', '#ffffff', 1), '#ffffff')
eq('mix halfway averages channels', appearance.mix('#000000', '#ffffff', 0.5), '#808080')
eq('mix accepts hex without a leading #', appearance.mix('000000', '#101010', 0.5), '#080808')
eq('mix returns the start color for malformed input', appearance.mix('not-a-color', '#ffffff', 0.5), 'not-a-color')
eq('mix returns the start color for a malformed end', appearance.mix('#123456', '#12345', 0.5), '#123456')

-- ---------- tab_bar_colors ----------
-- The contract: the active tab is visibly distinct from the bar, and every
-- color traces back to the scheme rather than a fixed theme's hues.
local dark = { background = '#0e1330', foreground = '#d8dce8', selection_bg = '#2a3060', selection_fg = '#f0f2fa' }
local dc = appearance.tab_bar_colors(dark)
eq('bar background is the scheme background', dc.background, '#0e1330')
eq('active tab uses the scheme selection background', dc.active_tab.bg_color, '#2a3060')
eq('active tab uses the scheme selection foreground', dc.active_tab.fg_color, '#f0f2fa')
eq('inactive tab blends into the bar', dc.inactive_tab.bg_color, '#0e1330')
eq('hover sits between the bar and the active tab', dc.inactive_tab_hover.bg_color, '#1c2248')

-- A light scheme must not get a darkened-for-dark-themes active tab: it takes
-- its own selection color, so contrast direction follows the scheme.
local light = { background = '#fdf6e3', foreground = '#3b4252', selection_bg = '#eee8d5', selection_fg = '#3b4252' }
local lc = appearance.tab_bar_colors(light)
eq('light scheme active tab is its selection color', lc.active_tab.bg_color, '#eee8d5')
eq('light scheme bar background is its background', lc.background, '#fdf6e3')

-- Schemes lacking selection colors still yield a distinguishable active tab.
local bare = appearance.tab_bar_colors({ background = '#000000', foreground = '#ffffff' })
eq('active tab is derived when selection_bg is absent', bare.active_tab.bg_color, '#262626')
eq('active tab fg falls back to the foreground', bare.active_tab.fg_color, '#ffffff')
eq('inactive tab fg is dimmer than the foreground', bare.inactive_tab.fg_color, '#a6a6a6')

-- Fully empty scheme table: still returns a usable palette, never nil colors.
local empty = appearance.tab_bar_colors({})
eq('empty scheme yields a background', empty.background, '#000000')
eq('empty scheme yields a distinct active tab', empty.active_tab.bg_color, '#262626')

-- ---------- resolve_scheme ----------
local config = { color_schemes = { Local = { background = '#111111' } } }
eq('inline schemes win', appearance.resolve_scheme(config, 'Local').background, '#111111')
eq('builtins resolve by name', appearance.resolve_scheme(config, 'Builtin Scheme').background, '#101010')
eq('unknown names fall back rather than erroring',
  appearance.resolve_scheme(config, 'Nope Renamed In v20').background, '#0e1330')
eq('a config without inline schemes still resolves builtins',
  appearance.resolve_scheme({}, 'Spartan').background, '#000000')

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
