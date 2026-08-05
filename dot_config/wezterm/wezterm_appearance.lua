-- Platform defaults, renderer selection and visual configuration.
local wezterm = require 'wezterm'
local act = wezterm.action

local M = {
  status_update_interval_ms = 200,
  config_path = wezterm.config_file:gsub('[^/\\]+$', 'wezterm_appearance.lua'),
}

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
  config.color_scheme = 'Cosmic Dusk'
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
  local scheme = config.color_schemes[config.color_scheme]
    or wezterm.color.get_builtin_schemes()[config.color_scheme]
    or { background = '#0e1330' }
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
    tab_bar = {
      background = scheme.background,
      -- Fancy tab bar fills each button from these static colors (per-tab bg in
      -- format-tab-title only paints behind the text). Active tab a touch
      -- lighter than the bar; inactive matches the bar; hover between.
      active_tab   = { bg_color = '#2a3352', fg_color = '#ffffff' },
      inactive_tab = { bg_color = scheme.background, fg_color = '#aaaaaa' },
      inactive_tab_hover = { bg_color = '#1c2340', fg_color = '#dddddd' },
      new_tab = { bg_color = scheme.background, fg_color = '#888888' },
      new_tab_hover = { bg_color = '#1c2340', fg_color = '#dddddd' },
    },
  }

  -- copy-on-select = false (only copy via explicit ctrl+c)
  config.mouse_bindings = {
    { event = { Up = { streak = 1, button = 'Left' } }, mods = 'NONE', action = act.Nop },
  }

  -- Close confirmation is handled by the ctrl+w callback in wezterm_keybindings.
  config.window_close_confirmation = 'NeverPrompt'
end

return M
