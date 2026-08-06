-- Platform defaults, renderer selection and visual configuration.
local wezterm = require 'wezterm'
local act = wezterm.action

local M = {
  status_update_interval_ms = 500,
  config_path = wezterm.config_file:gsub('[^/\\]+$', 'wezterm_appearance.lua'),
}

-- ---------- Scheme-derived tab bar palette (pure) ----------
-- The fancy tab bar fills each button from static config.colors.tab_bar.*
-- colors, so they can't be computed per-tab in format-tab-title. Derive them
-- from whichever scheme is active instead of hardcoding one theme's hues, so
-- the active tab reads as "this theme's highlighted surface" under every
-- scheme (including the ~1000 builtins, which we don't control).

local function parse_hex(hex)
  local r, g, b = tostring(hex):match('^#?(%x%x)(%x%x)(%x%x)$')
  if not r then return nil end
  return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

-- Linear blend: t=0 yields `from`, t=1 yields `to`.
function M.mix(from, to, t)
  local fr, fg, fb = parse_hex(from)
  local tr, tg, tb = parse_hex(to)
  if not fr or not tr then return from end
  local function chan(a, b) return math.floor(a + (b - a) * t + 0.5) end
  return string.format('#%02x%02x%02x', chan(fr, tr), chan(fg, tg), chan(fb, tb))
end

-- Colors for the fancy tab bar buttons, derived from a color scheme table.
-- Terminal selection colors are a poor fit here: they are designed for a small,
-- temporary text highlight and are often inverted or near-white (Nord), which
-- makes a persistent tab button visually overpower the entire bar. Build a quiet
-- raised surface from the scheme's background and foreground instead. The same
-- blend works in both directions for dark and light schemes.
function M.tab_bar_colors(scheme)
  local bg = scheme.background or '#000000'
  local fg = scheme.foreground or '#ffffff'
  local active_bg = M.mix(bg, fg, 0.15)
  return {
    background = bg,
    -- Active tab a touch lighter than the bar; inactive matches the bar; hover
    -- sits halfway so it reads as a preview of selecting the tab.
    active_tab   = { bg_color = active_bg, fg_color = fg },
    inactive_tab = { bg_color = bg, fg_color = M.mix(fg, bg, 0.35) },
    inactive_tab_hover = { bg_color = M.mix(bg, active_bg, 0.5), fg_color = fg },
    new_tab = { bg_color = bg, fg_color = M.mix(fg, bg, 0.5) },
    new_tab_hover = { bg_color = M.mix(bg, active_bg, 0.5), fg_color = fg },
  }
end

-- Look up a scheme table by name: our inline schemes first, then the builtins.
-- The final fallback keeps config load working if a persisted scheme name no
-- longer resolves (e.g. a builtin renamed across wezterm versions).
function M.resolve_scheme(config, name)
  return (config.color_schemes or {})[name]
    or wezterm.color.get_builtin_schemes()[name]
    or { background = '#0e1330', foreground = '#d8dce8' }
end

function M.apply(config)
  -- ---------- Default shell ----------
  -- Default new tabs/windows to the WSL distro, but only on Windows: this domain
  -- doesn't exist on Mac/Linux and setting it there errors at config load. There
  -- the built-in local domain is used instead.
  if wezterm.target_triple:find('windows') then
    config.default_domain = 'WSL:Ubuntu-24.04'
  end

  -- ---------- Renderer ----------
  -- The default OpenGL path on this build uses a generic GL adapter and is slow
  -- (laggy text selection / scrolling). Use WebGpu on the discrete GPU instead.
  config.front_end = 'WebGpu'
  config.webgpu_power_preference = 'HighPerformance'
  config.max_fps = 120
  -- WezTerm otherwise changes its FreeType default at 100 DPI. Pinning
  -- unhinted rendering avoids uneven stem snapping when a window crosses
  -- between the 1x and 1.25x monitors.
  config.freetype_load_flags = 'NO_HINTING'
  -- The default cursor-blink easing functions repaint continuously at
  -- animation_fps for any focused window, even a fully idle one. Constant
  -- easing plus a 1fps animation clock removes that idle repaint floor;
  -- max_fps only caps, so scrolling and typing still render at 120.
  config.animation_fps = 1
  config.cursor_blink_ease_in = 'Constant'
  config.cursor_blink_ease_out = 'Constant'
  for _, gpu in ipairs(wezterm.gui.enumerate_gpus()) do
    if gpu.backend == 'Vulkan' and gpu.device_type == 'DiscreteGpu' then
      config.webgpu_preferred_adapter = gpu
      break
    end
  end

  -- Disable macOS dead-key / IME composition so Option+key bindings work as raw keys.
  config.send_composed_key_when_left_alt_is_pressed = false
  config.send_composed_key_when_right_alt_is_pressed = false
  config.use_ime = false
  config.debug_key_events = false

  -- ---------- Appearance ----------
  -- Color schemes ported from the Ghostty themes (~/.config/ghostty/themes/).
  -- WezTerm ships no cosmic-dusk/rapture builtins, so define them inline and pick
  -- one via config.color_scheme. set-theme.sh sed-rewrites that line to switch.
  config.color_schemes = {
    -- Ghostty "Cosmic Dusk" (~/.config/ghostty/themes/Cosmic Dusk).
    ['Cosmic Dusk'] = {
      background = '#0e1330',
      foreground = '#d8dce8',
      cursor_bg = '#d4607a',
      cursor_fg = '#0c1024',
      cursor_border = '#d4607a',
      selection_bg = '#2a3060',
      selection_fg = '#f0f2fa',
      ansi = { '#0c1024', '#d4607a', '#69db7c', '#fbbf24', '#6a7acc', '#b09ac0', '#7aadcc', '#d8dce8' },
      brights = { '#2a3060', '#e87898', '#7eeea0', '#ffd43b', '#7a8ae0', '#c4b0d8', '#8ac0e0', '#f0f2fa' },
    },
    -- "Rapture" — no Ghostty theme exists; palette matched to the other apps'
    -- rapture themes (Zed/Lite XL/Micro).
    ['Rapture'] = {
      background = '#111e2a',
      foreground = '#c0c9e5',
      cursor_bg = '#7afde1',
      cursor_fg = '#111e2a',
      cursor_border = '#7afde1',
      selection_bg = '#304b66',
      selection_fg = '#ffffff',
      ansi = { '#000000', '#fc644d', '#7afde1', '#fff09b', '#6c9bf5', '#ff4fa1', '#64e0ff', '#c0c9e5' },
      brights = { '#304b66', '#fc644d', '#7afde1', '#fff09b', '#6c9bf5', '#ff4fa1', '#64e0ff', '#ffffff' },
    },
    -- "Yosemite Glow" (light) — Half Dome sunset: pale rose/peach sky, golden
    -- clouds, violet haze, slate-gray granite, pine green. No existing Ghostty
    -- theme; palette defined from scratch (see theme brief).
    ['Yosemite Glow'] = {
      background = '#f8ece2',
      foreground = '#45424f',
      cursor_bg = '#d26847',
      cursor_fg = '#f8ece2',
      cursor_border = '#d26847',
      selection_bg = '#f2cbb0',
      selection_fg = '#45424f',
      ansi = { '#55505c', '#bf4d55', '#5c7a52', '#d28f3c', '#5b7996', '#a35d9b', '#58908c', '#f1e0d2' },
      brights = { '#766f7d', '#d16680', '#6f9160', '#e2ab55', '#7592b1', '#bc7fb4', '#74aaa4', '#fdf5ec' },
    },
    -- Classic Gruvbox Dark (medium). Inline because no builtin normalizes to
    -- plain "Gruvbox" (builtins are "Gruvbox Dark (Gogh)", "GruvboxDark", ...),
    -- so set-theme.sh's builtin probe can't find it from the "gruvbox" slug.
    ['Gruvbox'] = {
      background = '#282828',
      foreground = '#ebdbb2',
      cursor_bg = '#ebdbb2',
      cursor_fg = '#282828',
      cursor_border = '#ebdbb2',
      selection_bg = '#504945',
      selection_fg = '#ebdbb2',
      ansi = { '#282828', '#cc241d', '#98971a', '#d79921', '#458588', '#b16286', '#689d6a', '#a89984' },
      brights = { '#928374', '#fb4934', '#b8bb26', '#fabd2f', '#83a598', '#d3869b', '#8ec07c', '#ebdbb2' },
    },
  }
  -- NOTE: the "Set Theme..." palette entry persists your choice by rewriting the
  -- color_scheme line in this APPLIED module, not its chezmoi source. Therefore
  -- `chezmoi apply` resets the theme to whatever is written here.
  -- Keep this line in sync with your current theme (or re-pick from the palette
  -- after applying).
  config.color_scheme = 'nord'
  config.font_size = 14
  config.window_background_opacity = 0.92
  config.window_padding = { left = 10, right = 10, top = 6, bottom = 6 }

  -- Ghostty: macos-titlebar-style = tabs + hidden window buttons.
  -- Windows nearest: integrate the min/max/close buttons into the tab bar.
  config.window_decorations = 'RESIZE'
  -- Hyprland (tiling Wayland) has no server-side title bar, so WezTerm draws its
  -- own title strip + control buttons over the tab bar and the glyphs render as
  -- broken empty squares. Hyprland handles move/resize itself, so drop decorations
  -- entirely there. Other environments (e.g. GNOME) keep the resizable border.
  local function running_under_hyprland()
    return os.getenv('HYPRLAND_INSTANCE_SIGNATURE') ~= nil
      or (os.getenv('XDG_CURRENT_DESKTOP') or ''):lower():find('hyprland') ~= nil
  end
  if running_under_hyprland() then
    config.window_decorations = 'NONE'
  end
  config.use_fancy_tab_bar = true
  config.show_new_tab_button_in_tab_bar = false -- drop the "+" new-tab button
  config.show_close_tab_button_in_tabs = false  -- drop the per-tab "x" (it overlapped the title)
  -- Note: tab_max_width is ignored in fancy tab bar mode (tabs are sized by the
  -- native widget / available width). Kept for the retro-bar fallback only. Our
  -- own truncation in format-tab-title uses the per-tab max_width passed there.
  config.tab_max_width = 32
  config.status_update_interval = M.status_update_interval_ms
  local scheme = M.resolve_scheme(config, config.color_scheme)
  config.window_frame = {
    -- Inter for the label text; fall back to Hack Nerd Font so the per-app tab
    -- icons (editor/git/docker/… — see wezterm_tabbar.lua) have glyphs to render. Inter has
    -- no Private Use Area glyphs, so without the fallback they'd show as tofu.
    --
    -- Adwaita Mono is a third fallback purely for the Claude status stars ❋ (U+274B)
    -- and ✹ (U+2739): they exist in NO other installed font, so without this entry
    -- wezterm can only reach them via its ASYNC system-wide font search. That search
    -- can briefly gap across genuine config/theme reloads. Listing the font here
    -- resolves the glyphs synchronously from the configured stack.
    font = wezterm.font_with_fallback({ { family = 'Inter', weight = 'Medium' }, 'Hack Nerd Font', 'Adwaita Mono' }),
    font_size = 15,
    active_titlebar_bg = scheme.background,
    inactive_titlebar_bg = scheme.background,
    border_left_width = '1px',
    border_right_width = '1px',
    border_bottom_height = '1px',
    border_top_height = '1px',
    border_left_color = '#555555',
    border_right_color = '#555555',
    border_bottom_color = '#555555',
    border_top_color = '#555555',
  }

  -- split-divider-color = #FFBF00
  config.colors = {
    split = '#FFBF00',
    -- Fancy tab bar fills each button from these static colors (per-tab bg in
    -- format-tab-title only paints behind the text), so they're derived from the
    -- scheme up front. The "Set Theme..." palette entry re-derives them when it
    -- switches schemes at runtime (see wezterm_themes.lua).
    tab_bar = M.tab_bar_colors(scheme),
  }

  -- copy-on-select = false (only copy via explicit ctrl+c)
  config.mouse_bindings = {
    { event = { Up = { streak = 1, button = 'Left' } }, mods = 'NONE', action = act.Nop },
  }

  -- Close confirmation is handled by the ctrl+w callback in wezterm_keybindings.
  config.window_close_confirmation = 'NeverPrompt'
end

return M
