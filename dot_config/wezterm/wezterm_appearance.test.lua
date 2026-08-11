-- Behavioral tests for the pure color derivation in wezterm_appearance.lua.
-- Run: lua wezterm_appearance.test.lua

package.path = (arg[0]:match('(.*/)') or './') .. '?.lua;' .. package.path

local builtins = {
  ['Builtin Scheme'] = { background = '#101010', foreground = '#f0f0f0', selection_bg = '#404040' },
  -- Some builtins define no selection colors at all.
  ['Spartan'] = { background = '#000000', foreground = '#ffffff' },
}

local wezterm_stub = {
  action = {},
  config_file = '/home/u/.config/wezterm/wezterm.lua',
  home_dir = '/home/u',
  target_triple = 'x86_64-unknown-linux-gnu',
  color = { get_builtin_schemes = function() return builtins end },
  gui = { enumerate_gpus = function() return {} end },
  font_with_fallback = function(fonts) return fonts end,
}
package.preload.wezterm = function() return wezterm_stub end

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
eq('active tab is a restrained lift from the bar', dc.active_tab.bg_color, '#2c314c')
eq('active tab uses the scheme foreground', dc.active_tab.fg_color, '#d8dce8')
eq('inactive tab blends into the bar', dc.inactive_tab.bg_color, '#0e1330')
eq('hover sits between the bar and the active tab', dc.inactive_tab_hover.bg_color, '#1d223e')

-- A light scheme is nudged toward its dark foreground, so contrast direction
-- follows the scheme without a dark/light special case.
local light = { background = '#fdf6e3', foreground = '#3b4252', selection_bg = '#eee8d5', selection_fg = '#3b4252' }
local lc = appearance.tab_bar_colors(light)
eq('light scheme active tab is subtly darkened', lc.active_tab.bg_color, '#e0dbcd')
eq('light scheme bar background is its background', lc.background, '#fdf6e3')

-- Nord's text-selection surface is nearly white. It must not leak into the tab
-- bar, where it becomes a glaring persistent block against the dark chrome.
local nord = appearance.tab_bar_colors {
  background = '#2e3440',
  foreground = '#d8dee9',
  selection_bg = '#eceff4',
  selection_fg = '#4c566a',
}
eq('Nord active tab stays a dark raised surface', nord.active_tab.bg_color, '#484e59')
eq('Nord active title stays light', nord.active_tab.fg_color, '#d8dee9')

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

-- ---------- apply: idle repaint floor ----------
-- A focused idle window must not drive continuous redraws: constant cursor
-- blink easing at a 1fps animation clock, while interactive frames stay at
-- the max_fps cap.
local applied = {}
appearance.apply(applied)
eq('agent status clock is 2fps', appearance.status_update_interval_ms, 500)
eq('status update interval uses the agent clock', applied.status_update_interval, 500)
eq('animation clock is 1fps', applied.animation_fps, 1)
eq('cursor blink ease in is constant', applied.cursor_blink_ease_in, 'Constant')
eq('cursor blink ease out is constant', applied.cursor_blink_ease_out, 'Constant')
eq('interactive frame cap is unchanged', applied.max_fps, 120)
eq('font rasterization is stable across display DPI', applied.freetype_load_flags, 'NO_HINTING')
eq('non-Windows does not add a Windows font directory', applied.font_dirs, nil)

-- Windows user-installed fonts are not consistently visible through the system
-- locator. The explicit directory keeps Inter as the title face; its missing
-- icon glyphs still fall through to the monospaced fonts in window_frame.font.
wezterm_stub.target_triple = 'x86_64-pc-windows-msvc'
wezterm_stub.home_dir = 'C:\\Users\\u'
local windows_applied = {}
appearance.apply(windows_applied)
eq('Windows scans per-user fonts', windows_applied.font_dirs[1],
  'C:\\Users\\u/AppData/Local/Microsoft/Windows/Fonts')

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
