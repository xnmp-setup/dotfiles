-- Window titles, compositor focus and moving tabs between existing windows.
local wezterm = require 'wezterm'
local window_identity = require 'wezterm_window_identity'
local act = wezterm.action

local M = {}

function M.setup()
  -- ctrl+shift+m: move the current tab into an EXISTING window (picked from a
  -- list), as opposed to ctrl+shift+n which always pops it into a brand new one.
  -- There is no Lua API for this: pane:move_to_new_window()/move_to_new_tab()
  -- only ever create a fresh window/tab, they can't target one that's already
  -- open. `wezterm cli move-pane-to-new-tab --window-id` can, so shell out to it.
  -- Same executable_dir rationale as the mux binary in wezterm_background.lua:
  -- the CLI isn't on PATH inside the macOS app; '.exe' is Windows-only.
  local WEZTERM_CLI_BIN = wezterm.executable_dir .. '/wezterm' .. (wezterm.target_triple:find('windows') and '.exe' or '')

  -- Basename of a pane's cwd (e.g. "dotfiles" from "/home/x/dotfiles"), or nil if
  -- the pane has none. Same userdata/string Url handling as wezterm_tabbar.lua,
  -- without that module's title-specific behavior.
  local function short_cwd(pane)
    local cwd = pane:get_current_working_dir()
    if not cwd then return nil end
    local path
    if type(cwd) == 'userdata' then
      path = cwd.file_path
    else
      path = tostring(cwd):gsub('^file://[^/]*', '')
    end
    if not path or path == '' then return nil end
    return (path:gsub('/$', ''):match('[^/]+$')) or path
  end

  -- Human label for a mux window, used by the move-tab-to-window picker below so
  -- entries read like "3 tabs — nvim · dotfiles" instead of a bare window id.
  local SHELL_PROCS = { bash = 1, sh = 1, zsh = 1, fish = 1, tmux = 1, nu = 1, login = 1 }
  local function window_label(mux_win)
    local tabs = mux_win:tabs_with_info()
    local active_pane
    for _, t in ipairs(tabs) do
      if t.is_active then
        active_pane = t.tab:active_pane()
        break
      end
    end
    local desc = 'empty'
    if active_pane then
      local proc = active_pane:get_foreground_process_name() or ''
      local base = (proc:match('[^/\\]+$') or ''):gsub('%.exe$', '')
      local cwd = short_cwd(active_pane)
      if base ~= '' and not SHELL_PROCS[base] then
        desc = cwd and (base .. ' · ' .. cwd) or base
      else
        desc = cwd or 'shell'
      end
    end
    local n = #tabs
    return string.format('%d tab%s — %s', n, n == 1 and '' or 's', desc)
  end

  -- Window title. This reproduces WezTerm's own default (the worked example in
  -- the format-window-title docs) and exists only so the format is OURS: it lets
  -- hypr_focus_window below predict a window's exact title, which is the only
  -- handle we have on which OS window is which. Keep the two in sync — if this
  -- and mux_window_title ever disagree, focus silently stops following.
  local function format_title(zoomed, tab_index, tab_count, pane_title, window_id)
    local z = zoomed and '[Z] ' or ''
    local idx = tab_count > 1 and string.format('[%d/%d] ', tab_index + 1, tab_count) or ''
    return z .. idx .. pane_title .. window_identity.tag(window_id)
  end

  wezterm.on('format-window-title', function(tab, _pane, tabs, _panes, _config)
    return format_title(
      tab.active_pane.is_zoomed,
      tab.tab_index,
      #tabs,
      tab.active_pane.title,
      tab.window_id
    )
  end)

  -- The same string, derived from mux data. format-window-title's TabInformation
  -- is only available inside that synchronous callback, so anything outside it
  -- has to rebuild the title from the mux.
  local function mux_window_title(mux_win)
    local tabs = mux_win:tabs_with_info()
    for _, item in ipairs(tabs) do
      if item.is_active then
        local zoomed = false
        for _, p in ipairs(item.tab:panes_with_info()) do
          if p.is_active then zoomed = p.is_zoomed; break end
        end
        return format_title(
          zoomed,
          item.index,
          #tabs,
          item.tab:active_pane():get_title() or '',
          mux_win:window_id()
        )
      end
    end
    return nil
  end

  -- Raise an OS window under Hyprland. Wayland doesn't let a client focus itself
  -- — window:focus() is documented as unsupported there and silently does
  -- nothing — so the compositor has to be asked instead. Hyprland's dispatchers
  -- match on title, and titles are the only wezterm state a compositor can see
  -- (every GUI window shares one pid and one app_id), hence format-window-title
  -- above. If two windows somehow carry the same title, Hyprland focuses the
  -- first; wrong-window is the worst case, never a crash.
  --
  -- No-ops off Hyprland: on macOS, Windows and X11 window:focus() works on its
  -- own, so nothing here needs a per-OS equivalent.
  --
  -- Lua dispatch syntax, matching open-link.sh's focus call — hyprctl on the Lua
  -- config wraps its argument as `return hl.dispatch(<arg>)`, so `focuswindow
  -- title:...` is a parse error. The matcher is passed as a long-bracket string
  -- because it is Lua source: the regex's backslashes would otherwise be read as
  -- escape sequences. On an older Hyprland this fails harmlessly to stderr and
  -- focus just stays put.
  local HYPR_RE_META = '[%^%$%(%)%.%[%]%*%+%?%{%}|\\]'
  local function hypr_focus_window(mux_win)
    if not os.getenv('HYPRLAND_INSTANCE_SIGNATURE') then return end
    local title = mux_window_title(mux_win)
    if not title or title == '' then return end
    local matcher = 'title:^' .. title:gsub(HYPR_RE_META, '\\%0') .. '$'
    wezterm.background_child_process {
      'hyprctl', 'dispatch', 'hl.dsp.focus({ window = [==[' .. matcher .. ']==] })',
    }
  end

  -- The move above runs as a detached CLI child process, so there's no completion
  -- signal to hook and nothing focuses the destination: the tab lands unselected
  -- in a window that isn't even raised. Poll the mux for the moved pane (same
  -- call_after-not-sleep_ms rationale as spawn_bg_tab_when_ready), then activate
  -- its new tab and focus its window. Matching on pane id rather than parsing the
  -- CLI's stdout keeps this independent of where in the tab bar it landed.
  local function focus_moved_pane(target_id, pane_id, attempts)
    attempts = attempts or 0
    for _, w in ipairs(wezterm.mux.all_windows()) do
      if w:window_id() == target_id then
        for _, item in ipairs(w:tabs_with_info()) do
          for _, p in ipairs(item.tab:panes()) do
            if p:pane_id() == pane_id then
              item.tab:activate()
              local gui = w:gui_window()
              if gui then gui:focus() end
              -- Activation has to land in the title bar before Hyprland can be
              -- asked to match on it.
              wezterm.time.call_after(0.1, function() hypr_focus_window(w) end)
              return
            end
          end
        end
      end
    end
    if attempts >= 40 then return end  -- 40 * 50ms = 2s; move failed, leave focus be
    wezterm.time.call_after(0.05, function()
      focus_moved_pane(target_id, pane_id, attempts + 1)
    end)
  end

  local function move_tab_to_window()
    return wezterm.action_callback(function(win, pane)
      local cur_id = win:mux_window():window_id()
      local choices = {}
      for _, w in ipairs(wezterm.mux.all_windows()) do
        if w:window_id() ~= cur_id then
          choices[#choices + 1] = { label = window_label(w), id = tostring(w:window_id()) }
        end
      end
      if #choices == 0 then
        win:toast_notification('WezTerm', 'No other window to move this tab to.', nil, 3000)
        return
      end
      win:perform_action(act.InputSelector {
        title = 'Move tab to window',
        choices = choices,
        fuzzy = true,
        action = wezterm.action_callback(function(_w, p, id, _label)
          if not id then return end
          local moved_pane_id = p:pane_id()
          wezterm.background_child_process {
            WEZTERM_CLI_BIN, 'cli', 'move-pane-to-new-tab',
            '--pane-id', tostring(moved_pane_id),
            '--window-id', id,
          }
          focus_moved_pane(tonumber(id), moved_pane_id)
        end),
      }, pane)
    end)
  end

  return {
    move_tab_to_window = move_tab_to_window,
  }
end

return M
