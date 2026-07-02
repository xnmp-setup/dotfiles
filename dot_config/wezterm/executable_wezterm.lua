-- WezTerm config — Windows port of the Ghostty config (dot_config/ghostty/config).
-- See the NOTES block at the bottom for things that don't translate 1:1.

local wezterm = require 'wezterm'
local act = wezterm.action
local config = wezterm.config_builder()

-- Pure, unit-tested tab-title truncation lives in tabtitle.lua (beside this
-- file, which wezterm puts on package.path). See tabtitle.test.lua for tests.
local compute_tab_title = require('tabtitle').compute_tab_title

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

-- Navigate tabs, crossing into the next/previous window when already at the
-- last/first tab of the current window. ctrl+pgdown past the last tab lands on
-- the first tab of the next window; ctrl+pgup past the first tab lands on the
-- last tab of the previous window. Both wrap around.
--
-- Window order is by mux window-id, i.e. creation order. That's the closest
-- stable "book order" the API exposes — WezTerm doesn't let us query a window's
-- on-screen position, so spatial ordering isn't possible (the pathological case
-- the request anticipates: windows physically arranged out of creation order).
local function tab_nav_across_windows(delta)
  return wezterm.action_callback(function(window, pane)
    local mux_win = window:mux_window()
    local tabs = mux_win:tabs_with_info()
    local cur
    for _, info in ipairs(tabs) do
      if info.is_active then cur = info.index; break end -- index is 0-based
    end

    -- Still inside the current window's tab range — plain relative move.
    local target = (cur or 0) + delta
    if target >= 0 and target <= #tabs - 1 then
      window:perform_action(act.ActivateTabRelative(delta), pane)
      return
    end

    -- Need to cross a window boundary. Order all windows by id (creation order).
    local wins = wezterm.mux.all_windows()
    if #wins < 2 then
      window:perform_action(act.ActivateTabRelative(delta), pane) -- lone window: wrap in place
      return
    end
    table.sort(wins, function(a, b) return a:window_id() < b:window_id() end)

    local cur_id = mux_win:window_id()
    local pos
    for i, w in ipairs(wins) do
      if w:window_id() == cur_id then pos = i; break end
    end

    local next_pos = pos + delta
    if next_pos < 1 then next_pos = #wins end
    if next_pos > #wins then next_pos = 1 end

    local target_win = wins[next_pos]
    local target_tabs = target_win:tabs()
    -- Forward → first tab of the next window; backward → last tab of the prev.
    local target_tab = delta > 0 and target_tabs[1] or target_tabs[#target_tabs]
    if target_tab then
      target_tab:activate()
      local gui = target_win:gui_window()
      if gui then gui:focus() end
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

-- Per-window focus state, keyed by window-id, maintained by the
-- window-focus-changed handler below. format-tab-title reads it so an unfocused
-- window's active tab renders with the dulled inactive styling. nil = unknown
-- (before any focus event) → treated as focused so nothing dims on first paint.
local window_focus = {}

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
-- config.color_scheme = 'Horizon Dark (Gogh)'
config.color_scheme = 'Horizon Dark (Gogh)'
config.font_size = 16 -- matches Ghostty's font-size = 16
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
-- Drives the update-status timer cadence = spinner animation frame rate. The
-- handler repaints via set_right_status (cheap, no config reload), so a fast
-- cadence is fine here. 200ms = 5fps — a lively star grow/shrink.
config.status_update_interval = 200
local scheme = config.color_schemes[config.color_scheme]
  or wezterm.color.get_builtin_schemes()[config.color_scheme]
  or { background = '#0e1330' }
config.window_frame = {
  font = wezterm.font('Inter', { weight = 'Medium' }),
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
  { key = 'PageUp', mods = 'CTRL', action = tab_nav_across_windows(-1) },
  { key = 'PageDown', mods = 'CTRL', action = tab_nav_across_windows(1) },

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
  working   = { glyph = '', active_bg = '#4C6B8A', inactive_bg = '#2C3E50' },
  -- stopped / turn finished: claude orange (matches the no-status fallback).
  -- No glyph — the claude icon in the title already marks these tabs.
  done      = { glyph = '', active_bg = '#C0623A', inactive_bg = '#7A3D24' },
  -- vivid saturated red, kept distinct from the muted claude-orange "done"
  attention = { glyph = '', active_bg = '#E5252B', inactive_bg = '#8A1418' },
}

-- Spinner animation for "working" tabs. format-tab-title normally renders a
-- static ⬤ dot; while a claude pane reports status=working we twinkle Claude's
-- own star glyph in its place — the shape grows/shrinks (· → ✦ → ✳ → ✷ → …) and
-- the color pulses dim→bright, so it reads as a blinking Claude icon rather than
-- a generic spinner. WezTerm only repaints the tab bar on an invalidation (not a
-- timer), so the update-status handler advances spinner_frame and forces a
-- repaint each tick — ONLY while working, so idle tabs don't churn repaints.
--
-- Claude Code's own "working" spinner, replicated. Claude cycles a GROWING STAR
-- (not a rotation or color pulse): it eases up from a dot to a big asterisk and
-- back, ping-pong, over a 2000ms period with cosine timing. Glyphs (from the
-- Claude Code binary): · U+00B7, ✢ U+2722, ✳ U+2733, ✶ U+2736, ✻ U+273B,
-- ✽ U+273D. We list the forward ramp and mirror it in code for the ping-pong.
--
-- Each glyph carries a trailing \u{FE0E} (VARIATION SELECTOR-15) to force TEXT
-- presentation — bare ✳ would render as a green emoji that ignores our color.
-- With VS15 they're monochrome and obey the orange Foreground below.
--
-- Claude's TUI is monospace so its star can change width freely; our fancy tab
-- bar is proportional (Inter), so differing glyph widths would shift the title.
-- The marker is therefore rendered in a fixed-width wrapper (see format below).
-- Claude's ramp starts with · (U+00B7 middle dot), but in the proportional tab
-- font the dot is far narrower than the stars and its frame visibly shifted the
-- title. Dropped it: the remaining star-family glyphs are near-equal width, so
-- the grow/shrink still reads while the text barely moves.
--
-- Also dropped ✳ (U+2733): it has EMOJI presentation by default and our VS15
-- override doesn't stick in this wezterm build, so that one frame rendered as a
-- big green emoji star. The remaining glyphs are text-default and stay orange.
local SPINNER_RAMP = {
  '✢\u{FE0E}', '✶\u{FE0E}', '✻\u{FE0E}', '✽\u{FE0E}',
}
-- Ping-pong: 1..6 then 5..2 → 10 frames, smooth grow/shrink with no repeated peak.
local SPINNER_FRAMES = {}
for i = 1, #SPINNER_RAMP do SPINNER_FRAMES[#SPINNER_FRAMES + 1] = SPINNER_RAMP[i] end
for i = #SPINNER_RAMP - 1, 2, -1 do SPINNER_FRAMES[#SPINNER_FRAMES + 1] = SPINNER_RAMP[i] end

-- Working spinner color: a CYAN/BLUE shimmer, deliberately different from the
-- orange done/idle star so an in-progress tab is unmistakable at a glance. The
-- color brightens toward the peak glyph and dims on the way back, in lockstep
-- with the grow/shrink, giving a shimmer. Built ping-pong the same way as the
-- glyphs so frame N's color matches frame N's star size. Ramp runs muted teal →
-- bright cyan-white.
local SPINNER_COLOR_RAMP = { '#3a6b7a', '#4fa9c0', '#7ad6e8', '#b6f0ff' }
local SPINNER_COLORS = {}
for i = 1, #SPINNER_COLOR_RAMP do SPINNER_COLORS[#SPINNER_COLORS + 1] = SPINNER_COLOR_RAMP[i] end
for i = #SPINNER_COLOR_RAMP - 1, 2, -1 do SPINNER_COLORS[#SPINNER_COLORS + 1] = SPINNER_COLOR_RAMP[i] end
local spinner_frame = 1

wezterm.on('format-tab-title', function(tab, tabs, panes, cfg, hover, max_width)
  local pane_info = tab.active_pane
  local title = pane_info.title or ''
  local proc = pane_info.foreground_process_name or ''

  -- An active tab in an unfocused window should look inactive: fold the window's
  -- focus state into is_active so all the styling below (intensity, underline,
  -- bg tint) dims to match the greyed-out window contents. focus default is nil
  -- (treated as focused) so tabs don't dim before the first focus event.
  local window_focused = window_focus[tab.window_id] ~= false
  local is_active = tab.is_active and window_focused

  -- Overlays (InputSelector, etc.) replace the active pane with one that has no
  -- cwd and no foreground process. Fall back to the last known rendered title.
  if not pane_info.current_working_dir and (proc == '' or proc == nil) then
    local cached = last_tab_title[tostring(tab.tab_id)]
    if cached then
      return cached
    end
  end

  local is_claude = proc:find('claude') ~= nil

  -- On exit Claude blanks its pane title (renders as a lone "_") for a frame
  -- before the shell repaints. proc still reads "claude" that frame, so the
  -- overlay guard above misses it (it requires no proc) and we'd flash an
  -- orange "_" tab. Treat a blank title while proc is still "claude" as the
  -- teardown frame and render it as a normal shell tab (cwd, black bg) right
  -- away, instead of holding the orange claude styling until the shell repaints.
  if is_claude and (title == '' or title == '_') then
    is_claude = false
    proc = ''  -- so the branch below takes the plain-cwd path, not "cwd: _"
  end

  -- For non-claude tabs, show "cwd" or "cwd: command" if a process is running
  if not is_claude then
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

    local proc_name = proc:match('[^/\\]+$') or ''
    local shells = { bash=1, sh=1, zsh=1, fish=1, nu=1, login=1 }
    if proc_name ~= '' and not shells[proc_name] then
      -- Running a command — show "cwd: command args" from pane title
      -- pane title is usually set to the running command by the shell
      local cmd = pane_info.title or proc_name
      title = basename .. ': ' .. cmd
    else
      title = basename
    end
  end

  -- Append pane count if more than one
  local pane_count = #tab.panes
  if pane_count > 1 then
    title = title .. ' (' .. pane_count .. ')'
  end

  -- Fancy tab bar renders each tab as its own rounded button and only fills the
  -- whole button from the static config.colors.tab_bar.* palette — a per-tab
  -- Background here paints just a rectangle behind the text, not the tab. So
  -- instead of tinting the tab bg, we lead with a colored status dot: claude
  -- tabs get an orange dot (or the working/attention status color), plain tabs
  -- get none. Underline marks the active tab; the button bg stays uniform.
  -- Keep intensity CONSTANT across focus. Previously active=Normal / inactive=Half:
  -- bold (Normal) glyphs are wider, so the same title rendered wider when focused,
  -- changing the visible length and clipping the '…' on the active tab. Fixing the
  -- weight makes width focus-independent; active tabs are still distinguished by
  -- underline, brighter fg, and the active_tab bg color.
  local intensity = 'Normal'
  local underline = is_active and 'Single' or 'None'

  -- Claude Code prefixes its pane title with its own animated spinner — a glyph
  -- (star ✳/✻/✽ or braille ⠐⠓⠋…) that lives in the U+2xxx range = 3-byte UTF-8
  -- starting 0xE2 — sometimes preceded by a "N: " tool/step count. We render our
  -- own marker, so strip both, otherwise two spinners compete. Loop so "3: ⠐ x"
  -- collapses to "x" in one pass.
  if is_claude then
    local changed = true
    while changed do
      changed = false
      -- Leading "N: " count prefix.
      local t = title:gsub('^%s*%d+:%s+', '')
      if t ~= title then title = t; changed = true end
      -- Leading 3-byte-glyph spinner token (0xE2 ...) + trailing space.
      t = title:gsub('^%s*\226[\128-\191][\128-\191]%s+', '')
      if t ~= title then title = t; changed = true end
    end
  end

  -- No custom separator glyph: fancy bar draws its own faint divider between
  -- buttons, and any glyph we add lands *inside* the button (a second, offset
  -- bar). Tab separation instead comes from distinct button bg colors set in
  -- config.colors.tab_bar.* (active vs inactive contrast).
  --
  -- Resolve the leading marker glyph + its color for the current state first, so
  -- we know how many cells it consumes before deciding how much title fits.
  local marker, marker_fg, title_fg
  if is_claude then
    local status = (pane_info.user_vars or {}).claude_status
    local style = status and STATUS_STYLE[status]
    if status == 'working' then
      -- Animate Claude's growing star with a synced cyan shimmer — both glyph and
      -- color come from the current ping-pong frame, so the star brightens as it
      -- grows. Cyan (not orange) marks in-progress apart from the idle star.
      local fi = ((spinner_frame - 1) % #SPINNER_FRAMES) + 1
      marker = SPINNER_FRAMES[fi]
      marker_fg = SPINNER_COLORS[((fi - 1) % #SPINNER_COLORS) + 1]
    elseif status == 'attention' then
      -- Needs input: loud red, and a CHUNKIER star than idle — ✹ (U+2739, twelve-
      -- pointed filled black star) is denser/bolder than the idle ❋ outline, so a
      -- tab awaiting input stands out. VS15 forces text presentation so it takes
      -- our red (bare emoji stars are font-colored and ignore it).
      marker = '✹\u{FE0E}'
      marker_fg = '#FF3B30'
    else
      -- done / idle: chunky orange claude-style star ❋ (U+274B). Can't reuse the
      -- emoji ✳ — emoji are font-colored (green), not tintable.
      marker = '❋\u{FE0E}'
      marker_fg = style and style.active_bg or '#C0623A'
    end
    title_fg = is_active and '#ffffff' or '#bbbbbb'
  else
    -- Non-claude tabs: a terminal prompt glyph (❯ U+276F, text-presentation so it
    -- needs no Nerd Font), dimmed so it reads as a marker not part of the name.
    marker = '❯'
    marker_fg = is_active and '#7aadcc' or '#4a5a6a'
    title_fg = is_active and '#ffffff' or '#aaaaaa'
  end

  -- Truncate via the pure helper. window_cols comes from the mux (a stable input)
  -- — NOT the content-driven max_width param, which feeds back on itself. See the
  -- long note on compute_tab_title above.
  local mux_win = wezterm.mux.get_window(tab.window_id)
  local window_cols = mux_win and mux_win:active_tab():get_size().cols or 200
  title = compute_tab_title {
    title = title,
    marker = marker,
    ntabs = #tabs,
    window_cols = window_cols,
    max_chars = 24,
    marker_pad = 3,  -- '  ' before + ' ' after the marker
    width = wezterm.column_width,
    truncate = wezterm.truncate_right,
  }

  local result = {
    { Attribute = { Intensity = intensity } },
    { Attribute = { Underline = underline } },
    { Foreground = { Color = marker_fg } },
    { Text = '  ' .. marker .. ' ' },
    { Foreground = { Color = title_fg } },
    { Text = title .. ' ' },
  }

  last_tab_title[tostring(tab.tab_id)] = result
  return result
end)

-- ---------- Dim unfocused windows' tab titles ----------
-- Record per-window focus state so format-tab-title renders an unfocused
-- window's active tab with the dulled inactive styling (it gates underline /
-- intensity on `tab.is_active and window_focused`), then force the tab bar to
-- repaint immediately.
--
-- Subtlety that cost real debugging time: format-tab-title recomputing does NOT
-- repaint the GUI surface — wezterm calls it constantly (~8-24x/sec per window)
-- but the visible tab bar only updates on an explicit invalidation. The reliable
-- trigger is the window-config-reloaded event, which set_config_overrides emits
-- — but ONLY when the override values actually CHANGE. Re-setting an unchanged
-- table is silently a no-op (verified: zero reload events), so the title would
-- lag 1-2s until the next surface refresh and the just-blurred window often
-- wouldn't update at all. So we flip an override every focus change.
--
-- The reload→repaint round trip costs ~135ms regardless of WHICH override is
-- flipped (measured: identical for opacity vs this), so latency isn't the reason
-- for the choice. But the override must be visually INERT, else it adds its own
-- cost/flicker on top: foreground_text_hsb re-renders every glyph (the original
-- ~2s lag), window_background_opacity recomposites the translucent surface (risk
-- of a faint opacity flicker). status_update_interval only changes a timer
-- cadence — no glyph render, no recomposite, no possible visual — so flipping it
-- 1000<->1001 is the cleanest pure repaint trigger. ~135ms is the floor for this
-- approach; wezterm exposes no cheaper tab-bar invalidation. window-focus-changed
-- fires for both the losing and gaining window, so both tab bars repaint at once.
wezterm.on('window-focus-changed', function(window, pane)
  local focused = window:is_focused()
  window_focus[window:window_id()] = focused

  -- Flip the (inert) interval by 1ms to force a tab-bar repaint. Stay at the
  -- 200ms base so we don't change the spinner clock. See long note above re: why
  -- this specific override is the cheapest invalidation trigger.
  local overrides = window:get_config_overrides() or {}
  overrides.status_update_interval = focused and 200 or 201
  window:set_config_overrides(overrides)
end)

-- ---------- Working spinner animation ----------
-- Fires every status_update_interval ms. If any pane in any window reports
-- claude_status=working, advance the braille spinner frame and force a tab-bar
-- repaint so format-tab-title re-renders the new frame.
--
-- CRITICAL: the repaint is done with set_right_status, NOT set_config_overrides.
-- The override trick used by window-focus-changed forces a full CONFIG RELOAD
-- (~135ms) every call — fine for an occasional focus change, but at animation
-- cadence it made tab switches visibly laggy. set_right_status is WezTerm's
-- intended per-frame update path: it invalidates and repaints the tab bar (which
-- re-runs format-tab-title) cheaply, with no reload. We stash the frame in a
-- module global and write an (empty) right status purely to trigger the repaint.
wezterm.on('update-status', function(window, pane)
  local any_working = false
  for _, w in ipairs(wezterm.mux.all_windows()) do
    for _, tab in ipairs(w:tabs()) do
      for _, p in ipairs(tab:panes()) do
        local st = (p:get_user_vars() or {}).claude_status
        if st == 'working' then any_working = true; break end
      end
      if any_working then break end
    end
    if any_working then break end
  end

  if not any_working then
    -- Keep a constant zero-width payload even when idle: toggling between empty
    -- and non-empty adds/removes the right-status region and reflows the tab bar
    -- vertically (a 1-2px jitter every frame). Always-present, always zero-width
    -- = stable layout.
    window:set_right_status(wezterm.format({ { Text = '\u{200b}' } }))
    return
  end

  spinner_frame = (spinner_frame % #SPINNER_FRAMES) + 1
  -- Alternate between two DIFFERENT zero-width chars (ZWSP U+200B / ZWNBSP
  -- U+FEFF) so the value changes each tick — an unchanged right status is a
  -- no-op and wouldn't repaint. Both are zero-width, so the region's size never
  -- changes and the tab bar doesn't shift. The chars are never visibly rendered;
  -- they exist only to invalidate the tab bar so format-tab-title re-runs.
  window:set_right_status(wezterm.format({ { Text = (spinner_frame % 2 == 0) and '\u{200b}' or '\u{feff}' } }))
end)

-- ---------- Command palette: Set Theme ----------
local function persist_color_scheme(name)
  local config_path = wezterm.config_file
  local fh = io.open(config_path, 'r')
  if not fh then return end
  local content = fh:read('*a')
  fh:close()
  local updated = content:gsub(
    "(config%.color_scheme%s*=%s*)('[^']*')",
    "%1'" .. name:gsub("'", "\\'") .. "'"
  )
  local out = io.open(config_path, 'w')
  if out then
    out:write(updated)
    out:close()
  end
end

wezterm.on('augment-command-palette', function(window, pane)
  return {
    {
      brief = 'Set Theme...',
      icon = 'md_palette',
      action = wezterm.action_callback(function(win, p)
        local schemes = wezterm.get_builtin_color_schemes()
        for name, _ in pairs(config.color_schemes or {}) do
          schemes[name] = true
        end
        local choices = {}
        for name, _ in pairs(schemes) do
          table.insert(choices, { label = name })
        end
        table.sort(choices, function(a, b) return a.label < b.label end)

        win:perform_action(act.InputSelector {
          title = 'Set Theme',
          choices = choices,
          fuzzy = true,
          action = wezterm.action_callback(function(w, _, _, label)
            if label then
              local overrides = w:get_config_overrides() or {}
              overrides.color_scheme = label
              w:set_config_overrides(overrides)
              persist_color_scheme(label)
            end
          end),
        }, p)
      end),
    },
  }
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
