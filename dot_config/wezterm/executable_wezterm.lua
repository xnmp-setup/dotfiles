-- WezTerm config — Windows port of the Ghostty config (dot_config/ghostty/config).
-- See the NOTES block at the bottom for things that don't translate 1:1.

local wezterm = require 'wezterm'
local act = wezterm.action
local config = wezterm.config_builder()

-- Navigate panes within the current tab in book order (top-to-bottom, then
-- left-to-right). Only cross to the next/prev tab when already at the
-- last/first pane in that order.
local function pane_or_tab_nav(delta)
  return wezterm.action_callback(function(window, pane)
    local infos = window:active_tab():panes_with_info()
    table.sort(infos, function(a, b)
      if a.top ~= b.top then
        return a.top < b.top
      end
      return a.left < b.left
    end)
    local cur
    for i, info in ipairs(infos) do
      if info.is_active then
        cur = i
        break
      end
    end
    local target = cur + delta
    if target >= 1 and target <= #infos then
      infos[target].pane:activate()
    else
      window:perform_action(act.ActivateTabRelative(delta), pane)
    end
  end)
end

-- ---------- Default shell ----------
-- config.default_domain = 'WSL:Ubuntu-24.04'  -- Windows/WSL only

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

-- ---------- Appearance ----------
config.color_scheme = 'Ayu Mirage' -- if missing, try 'Ayu Mirage (Gogh)' or 'ayu'
config.font_size = 16
config.window_background_opacity = 0.95
config.window_padding = { left = 10, right = 10, top = 6, bottom = 6 }

-- Ghostty: macos-titlebar-style = tabs + hidden window buttons.
-- Windows nearest: integrate the min/max/close buttons into the tab bar.
config.window_decorations = 'INTEGRATED_BUTTONS|RESIZE'
config.use_fancy_tab_bar = true
config.tab_max_width = 32

-- split-divider-color = #FFBF00
config.colors = { split = '#FFBF00' }

-- copy-on-select = false (only copy via explicit ctrl+c)
config.mouse_bindings = {
  { event = { Up = { streak = 1, button = 'Left' } }, mods = 'NONE', action = act.Nop },
}

-- Close confirmation handled by ctrl+w callback below.
config.window_close_confirmation = 'NeverPrompt'

-- ---------- Keybinds ----------
config.keys = {
  -- config / palette
  { key = ',', mods = 'CTRL|SHIFT', action = act.ReloadConfiguration },
  { key = 'p', mods = 'CTRL|SHIFT', action = act.ActivateCommandPalette },

  -- tabs / windows / panes
  -- Close pane: immediate if only shell running, else prompt (Enter to confirm).
  { key = 'w', mods = 'CTRL', action = wezterm.action_callback(function(window, pane)
    local dominated_by_shell = true
    local procs = pane:get_foreground_process_name()
    if procs then
      local name = procs:match('[^/\\]+$') or procs
      local skip = { bash=1, sh=1, zsh=1, fish=1, tmux=1, nu=1, login=1 }
      if not skip[name] then
        dominated_by_shell = false
      end
    end
    if dominated_by_shell then
      window:perform_action(act.CloseCurrentPane { confirm = false }, pane)
    else
      window:perform_action(act.InputSelector {
        title = '🛑 Kill pane with running process? (Enter = yes, Esc = no)',
        choices = { { label = 'Yes, close pane' } },
        action = wezterm.action_callback(function(win, p, id, label)
          if label then
            win:perform_action(act.CloseCurrentPane { confirm = false }, p)
          end
        end),
      }, pane)
    end
  end) },
  { key = 't', mods = 'CTRL', action = act.SpawnTab 'CurrentPaneDomain' },
  -- new PowerShell (pwsh) tab in the local Windows domain (default domain is WSL).
  -- Full path to the MSI install — avoids the slow WindowsApps execution-alias stub.
  {
    key = 't',
    mods = 'CTRL|SHIFT',
    action = act.SpawnCommandInNewTab {
      domain = { DomainName = 'local' },
      args = { 'C:\\Program Files\\PowerShell\\7\\pwsh.exe' },
    },
  },
  { key = 'n', mods = 'CTRL', action = act.SpawnWindow },
  { key = 'PageUp', mods = 'CTRL', action = pane_or_tab_nav(-1) },
  { key = 'PageDown', mods = 'CTRL', action = pane_or_tab_nav(1) },

  -- clipboard
  -- ctrl+v: normal text paste. ctrl+shift+v: forward ^V to the app so Claude
  -- Code (running in WSL) fires its own image-paste handler — WezTerm's own
  -- PasteFrom only handles text and would drop clipboard images.
  { key = 'v', mods = 'CTRL', action = act.PasteFrom 'Clipboard' },
  { key = 'v', mods = 'CTRL|SHIFT', action = act.SendKey { key = 'v', mods = 'CTRL' } },
  { key = 'Insert', mods = 'SHIFT', action = act.PasteFrom 'Clipboard' },
  -- performable ctrl+c: copy if there's a selection, else send SIGINT (^C)
  {
    key = 'c',
    mods = 'CTRL',
    action = wezterm.action_callback(function(window, pane)
      local sel = window:get_selection_text_for_pane(pane)
      if sel and sel ~= '' then
        window:perform_action(act.CopyTo 'Clipboard', pane)
      else
        window:perform_action(act.SendKey { key = 'c', mods = 'CTRL' }, pane)
      end
    end),
  },

  -- unbind ghostty's ctrl+shift+left/right
  { key = 'LeftArrow', mods = 'CTRL|SHIFT', action = act.DisableDefaultAssignment },
  { key = 'RightArrow', mods = 'CTRL|SHIFT', action = act.DisableDefaultAssignment },

  -- scrolling
  { key = 'PageUp', mods = 'SHIFT', action = act.ScrollByPage(-1) },
  { key = 'PageDown', mods = 'SHIFT', action = act.ScrollByPage(1) },

  -- panes: create (alt+super) and navigate (super). See NOTES re: Win key on Windows.
  { key = 'h', mods = 'CTRL', action = act.SplitPane { direction = 'Right' } },
  { key = 'l', mods = 'ALT|SUPER', action = act.SplitPane { direction = 'Left' } },
  { key = 'p', mods = 'ALT|SUPER', action = act.SplitPane { direction = 'Up' } },
  { key = ';', mods = 'ALT|SUPER', action = act.SplitPane { direction = 'Down' } },
  { key = 'o', mods = 'ALT', action = act.TogglePaneZoomState },
  { key = 'RightArrow', mods = 'SUPER', action = act.ActivatePaneDirection 'Right' },
  { key = 'LeftArrow', mods = 'SUPER', action = act.ActivatePaneDirection 'Left' },
  { key = 'UpArrow', mods = 'SUPER', action = act.ActivatePaneDirection 'Up' },
  { key = 'DownArrow', mods = 'SUPER', action = act.ActivatePaneDirection 'Down' },

  -- raw escape / CSI-u sequences
  { key = '/', mods = 'SUPER', action = act.SendString '\x1f' },
  { key = 'l', mods = 'SUPER', action = act.SendString '\x1bl' },
  { key = 'p', mods = 'SUPER', action = act.SendString '\x1bp' },
  { key = ';', mods = 'SUPER', action = act.SendString '\x1b;' },
  { key = "'", mods = 'SUPER', action = act.SendString "\x1b'" },
  { key = 'Enter', mods = 'CTRL', action = act.SendString '\x1b[13;5u' },
  { key = 'Enter', mods = 'SHIFT', action = act.SendString '\x1b[13;2u' },
  { key = 'Backspace', mods = 'ALT', action = act.SendString '\x1b\x7f' },
  { key = 'Backspace', mods = 'CTRL', action = act.SendString '\x17' },
  { key = 'Delete', mods = 'ALT', action = act.SendString '\x1bd' },
  { key = 'Delete', mods = 'CTRL', action = act.SendString '\x1bd' },
  { key = 'k', mods = 'CTRL|SHIFT', action = act.SendString '\x0b' },
  { key = 'Home', mods = 'SHIFT', action = act.SendString '\x1b[1;2H' },
  { key = 'End', mods = 'SHIFT', action = act.SendString '\x1b[1;2F' },
}

-- ---------- Tab bar: orange for Claude Code ----------
wezterm.on('format-tab-title', function(tab, tabs, panes, cfg, hover, max_width)
  local pane_info = tab.active_pane
  local title = pane_info.title or ''
  local proc = pane_info.foreground_process_name or ''

  local is_claude = proc:find('claude') ~= nil

  if is_claude then
    return {
      { Background = { Color = '#C0623A' } },
      { Foreground = { Color = '#ffffff' } },
      { Text = ' ' .. title .. ' ' },
    }
  end
end)

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
--   pane nav and super+l/p/; binds above likely won't reach WezTerm. If you want
--   them to actually fire, say so and I'll remap those to ALT or CTRL+ALT.
