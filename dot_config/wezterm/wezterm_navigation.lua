-- Pane, tab and cross-window navigation actions.
local wezterm = require 'wezterm'
local act = wezterm.action

local M = {}

-- Navigate panes within the current tab in book order (top-to-bottom, then
-- left-to-right). Only cross to the next/prev tab when already at the
-- last/first pane in that order.
function M.pane_or_tab_nav(delta)
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
function M.tab_nav_across_windows(delta)
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
function M.spawn_tab_next(domain)
  return wezterm.action_callback(function(win, pane)
    local idx
    for _, item in ipairs(win:mux_window():tabs_with_info()) do
      if item.is_active then idx = item.index; break end
    end
    win:perform_action(act.SpawnTab(domain), pane)
    win:perform_action(act.MoveTab(idx + 1), pane)
  end)
end

return M
