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

-- Spawn a new tab immediately after the current one (not appended at end).
local function spawn_tab_next(domain)
  return wezterm.action_callback(function(win, pane)
    local idx
    for _, item in ipairs(win:mux_window():tabs_with_info()) do
      if item.is_active then idx = item.index; break end
    end
    win:perform_action(act.SpawnTab(domain), pane)
    win:perform_action(act.MoveTab(idx + 1), pane)
  end)
end

-- Last known tab title — format-tab-title stashes here so overlays (InputSelector
-- etc.) that blank the active pane don't cause a flicker to an empty title.
local last_tab_title = {}

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
config.debug_key_events = true

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
}
-- config.color_scheme = 'Ayu Mirage'
config.color_scheme = 'Horizon Dark (Gogh)'
config.font_size = 16 -- matches Ghostty's font-size = 16
config.window_background_opacity = 0.95
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
config.use_fancy_tab_bar = false
config.show_new_tab_button_in_tab_bar = false -- drop the "+" new-tab button
config.show_close_tab_button_in_tabs = false  -- drop the per-tab "x" (it overlapped the title)
config.tab_max_width = 32
local scheme = config.color_schemes[config.color_scheme]
  or wezterm.color.get_builtin_schemes()[config.color_scheme]
  or { background = '#0e1330' }
config.window_frame = {
  font_size = 16,
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
  },
}

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
    -- Decide whether the pane is idle at a shell (close silently) or has a program
    -- running (confirm first). Under WSL get_foreground_process_name only sees the
    -- wslhost.exe proxy, so prefer the WEZTERM_PROG user var the zsh hooks publish:
    -- precmd sets it to "zsh" at the prompt, preexec to the running command line.
    -- Fall back to the OS process for panes without the hook (e.g. the pwsh domain).
    local skip = { bash=1, sh=1, zsh=1, fish=1, tmux=1, nu=1, login=1,
                   ['pwsh.exe']=1, ['powershell.exe']=1, ['cmd.exe']=1 }
    local prog = (pane:get_user_vars() or {}).WEZTERM_PROG
    local name
    if prog and prog ~= '' then
      name = (prog:match('^%S+') or prog):match('[^/\\]+$') or prog
    else
      local procs = pane:get_foreground_process_name()
      name = procs and (procs:match('[^/\\]+$') or procs) or nil
    end
    local dominated_by_shell = name == nil or skip[name] ~= nil
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
  { key = 't', mods = 'CTRL', action = spawn_tab_next('CurrentPaneDomain') },
  -- new PowerShell (pwsh) tab in the local Windows domain (default domain is WSL).
  -- Full path to the MSI install — avoids the slow WindowsApps execution-alias stub.
  { key = 't', mods = 'CTRL|SHIFT', action = wezterm.action_callback(function(win, pane)
    local idx
    for _, item in ipairs(win:mux_window():tabs_with_info()) do
      if item.is_active then idx = item.index; break end
    end
    win:perform_action(act.SpawnCommandInNewTab {
      domain = { DomainName = 'local' },
      args = { 'C:\\Program Files\\PowerShell\\7\\pwsh.exe' },
    }, pane)
    win:perform_action(act.MoveTab(idx + 1), pane)
  end) },
  { key = 'n', mods = 'CTRL', action = act.SpawnWindow },
  { key = 'PageUp', mods = 'CTRL', action = act.ActivateTabRelative(-1) },
  { key = 'PageDown', mods = 'CTRL', action = act.ActivateTabRelative(1) },

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
  { key = "'", mods = 'ALT|SUPER', action = act.SplitPane { direction = 'Right' } },
  { key = 't', mods = 'CTRL|SHIFT|ALT|SUPER', action = act.SplitPane { direction = 'Right' } },
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
  -- Word nav: karabiner rewrites ctrl+left/right => alt(option)+left/right,
  -- so the terminal sees Alt+Arrow. Emit the real ctrl+arrow CSI sequences
  -- (zsh binds these to backward-word/forward-word; TUIs read them too).
  { key = 'LeftArrow', mods = 'ALT', action = act.SendString '\x1b[1;5D' },
  { key = 'RightArrow', mods = 'ALT', action = act.SendString '\x1b[1;5C' },
  { key = 'k', mods = 'CTRL|SHIFT', action = act.SendString '\x0b' },
  { key = 'Home', mods = 'SHIFT', action = act.SendString '\x1b[1;2H' },
  { key = 'End', mods = 'SHIFT', action = act.SendString '\x1b[1;2F' },
}

-- ---------- Tab bar styling ----------
-- Claude session status, set per-pane via the OSC 1337 SetUserVar "claude_status"
-- escape sequence emitted by ~/.claude/hooks/wezterm_status.sh. Drives a leading
-- glyph + tab tint so you can see at a glance which tabs are working vs waiting.
-- Each state has an emphasized active bg and a dulled inactive bg.
local STATUS_STYLE = {
  working   = { glyph = '◐', active_bg = '#4C6B8A', inactive_bg = '#2C3E50' },
  -- stopped / turn finished: claude orange (matches the no-status fallback).
  -- No glyph — the claude icon in the title already marks these tabs.
  done      = { glyph = '', active_bg = '#C0623A', inactive_bg = '#7A3D24' },
  -- vivid saturated red, kept distinct from the muted claude-orange "done"
  attention = { glyph = '⚠', active_bg = '#E5252B', inactive_bg = '#8A1418' },
}

wezterm.on('format-tab-title', function(tab, tabs, panes, cfg, hover, max_width)
  local pane_info = tab.active_pane
  local title = ''
  local uv = pane_info.user_vars or {}
  local is_active = tab.is_active

  -- Resolve the foreground command. WezTerm's foreground_process_name only sees
  -- the wslhost.exe proxy for WSL panes, never the real process, so prefer the
  -- WEZTERM_PROG user var the zsh hooks publish from inside WSL. Fall back to the
  -- OS process for panes without the hook (e.g. the pwsh local domain). prog is a
  -- command line ("git status"); foreground_process_name is a path (".../pwsh.exe").
  local prog = uv.WEZTERM_PROG
  local proc_name, display_cmd
  if prog and prog ~= '' then
    proc_name = (prog:match('^%S+') or prog):match('[^/\\]+$') or prog
    display_cmd = prog
  else
    local proc = pane_info.foreground_process_name or ''
    proc_name = proc:match('[^/\\]+$') or proc
    display_cmd = proc_name
  end

  -- Overlays (InputSelector, etc.) replace the active pane with one that has no
  -- cwd and no foreground process. Fall back to the last known rendered title.
  if not pane_info.current_working_dir and (proc_name == '' or proc_name == nil) then
    local cached = last_tab_title[tostring(tab.tab_id)]
    if cached then
      return cached
    end
  end

  local is_claude = proc_name:find('claude') ~= nil

  -- Working directory basename (the project name). Reliable via OSC-7 even under
  -- WSL, unlike pane_info.title which stays "wslhost.exe" until claude gets around
  -- to setting its own title. Used for both claude and plain tabs.
  local cwd = pane_info.current_working_dir
  local basename = ''
  if cwd then
    local path
    if type(cwd) == 'userdata' then
      -- Url object. file_path (already decoded) is nil when the OSC-7 host !=
      -- local host, so fall back to the percent-encoded .path and decode that.
      -- Never call string methods on the userdata, or the handler errors and
      -- wezterm shows the raw full-path title.
      path = cwd.file_path
      if not path or path == '' then
        path = (cwd.path or ''):gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
      end
    else
      -- Legacy string form: "file://host/path"
      path = tostring(cwd):gsub('^file://[^/]*', '')
    end
    path = path:gsub('[/\\]+$', '')
    basename = path:match('[^/\\]+$') or path
  end

  -- Names that aren't a real foreground command: shells, plus the WSL proxy that
  -- foreground_process_name / the raw pane title report before claude (or the
  -- WEZTERM_PROG hook) sets a proper title.
  local shells = { bash=1, sh=1, zsh=1, fish=1, nu=1, login=1,
                   ['pwsh.exe']=1, ['powershell.exe']=1, ['cmd.exe']=1,
                   ['wslhost.exe']=1, ['wsl.exe']=1, ['wslrelay.exe']=1 }

  if is_claude then
    -- Show the title Claude Code sets via OSC ("Claude Code", or whatever /rename
    -- changes it to). Until it does, the raw WSL pane title is "wslhost.exe", so
    -- fall back to the project dir / "claude".
    local t = pane_info.title or ''
    local tbase = t:match('[^/\\]+$') or t
    if t ~= '' and not shells[tbase] then
      title = t
    else
      title = basename ~= '' and basename or 'claude'
    end
  else
    -- Plain tab: "cwd", or "cwd: command" when a process is running.
    if proc_name ~= '' and not shells[proc_name] then
      title = basename .. ': ' .. display_cmd
    else
      title = basename
    end
  end

  -- Append pane count if more than one
  local pane_count = #tab.panes
  if pane_count > 1 then
    title = title .. ' (' .. pane_count .. ')'
  end

  local intensity = is_active and 'Normal' or 'Half'
  local underline = is_active and 'Single' or 'None'
  local sep_color = is_active and '#555555' or '#333333'

  local result
  local sep_left = {
    { Attribute = { Underline = 'None' } },
    { Attribute = { Intensity = 'Normal' } },
    { Background = { Color = scheme.background } },
    { Foreground = { Color = sep_color } },
    { Text = '▎' },
  }
  if is_claude then
    local fg = is_active and '#ffffff' or '#bbbbbb'
    local status = uv.claude_status
    local style = status and STATUS_STYLE[status]
    if style then
      local bg = is_active and style.active_bg or style.inactive_bg
      local prefix = style.glyph ~= '' and (' ' .. style.glyph) or ''
      result = {
        sep_left[1], sep_left[2], sep_left[3], sep_left[4], sep_left[5],
        { Attribute = { Intensity = intensity } },
        { Attribute = { Underline = underline } },
        { Background = { Color = bg } },
        { Foreground = { Color = fg } },
        { Text = prefix .. ' ' .. title .. ' ' },
      }
    else
      local bg = is_active and '#C0623A' or '#7A3D24'
      result = {
        sep_left[1], sep_left[2], sep_left[3], sep_left[4], sep_left[5],
        { Attribute = { Intensity = intensity } },
        { Attribute = { Underline = underline } },
        { Background = { Color = bg } },
        { Foreground = { Color = fg } },
        { Text = ' ' .. title .. ' ' },
      }
    end
  else
    local fg = is_active and '#ffffff' or '#aaaaaa'
    result = {
      sep_left[1], sep_left[2], sep_left[3], sep_left[4], sep_left[5],
      { Attribute = { Intensity = intensity } },
      { Attribute = { Underline = underline } },
      { Foreground = { Color = fg } },
      { Text = ' ' .. title .. ' ' },
    }
  end

  last_tab_title[tostring(tab.tab_id)] = result
  return result
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
