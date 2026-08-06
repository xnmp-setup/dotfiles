-- Browser-style recently closed tabs. Snapshots are plain data retained in
-- wezterm.GLOBAL so Ctrl+Shift+T keeps working across a config reload.
local wezterm = require 'wezterm'
local act = wezterm.action

local M = {}

local STACK_KEY = 'recently_closed_tabs_v1'
local MAX_TABS = 20

local function stack()
  local value = wezterm.GLOBAL[STACK_KEY]
  if value == nil then return {} end
  if type(value) == 'string' then
    local ok, decoded = pcall(wezterm.json_parse, value)
    if ok and type(decoded) == 'table' then return decoded end
    return {}, 'invalid JSON history: ' .. tostring(decoded)
  end
  -- Table values read from wezterm.GLOBAL are exposed as special userdata on
  -- current builds. Store the stack as JSON text so its type and copy semantics
  -- remain unambiguous across callbacks and config evaluation contexts.
  return {}, 'unexpected history type: ' .. type(value)
end

local function persist_stack(tabs)
  local ok, encoded = pcall(wezterm.json_encode, tabs)
  if not ok then return false, encoded end
  local assigned, reason = pcall(function() wezterm.GLOBAL[STACK_KEY] = encoded end)
  if not assigned then return false, reason end
  return true
end

local function toast(window, message)
  pcall(function()
    window:toast_notification('WezTerm', message, nil, 3000)
  end)
end

local function active_tab_index(mux_window, active_tab)
  local active_id = active_tab:tab_id()
  for _, info in ipairs(mux_window:tabs_with_info()) do
    if info.tab:tab_id() == active_id then return info.index end
  end
  return #mux_window:tabs_with_info()
end

local function object_id(object, method)
  if not object then return 'nil' end
  local ok, value = pcall(function() return object[method](object) end)
  return ok and value or 'unavailable'
end

local function resume_pane_count(snapshot)
  local count = 0
  for _, pane_state in ipairs(snapshot.panes or {}) do
    if pane_state.args then count = count + 1 end
  end
  return count
end

function M.setup(deps)
  local sessionstore = assert(deps.sessionstore, 'sessionstore dependency is required')
  local resume_args_for = assert(deps.agent.resume_args_for, 'agent dependency is required')
  local log = deps.log or function() end

  local initial_tabs, initial_error = stack()
  log('history.setup', {
    count = #initial_tabs,
    error = initial_error,
    storage_type = type(wezterm.GLOBAL[STACK_KEY]),
  })

  local function remember_tab(window)
    local tab = window:active_tab()
    local mux_window = window:mux_window()
    log('capture.begin', {
      tab_id = object_id(tab, 'tab_id'),
      window_id = object_id(window, 'window_id'),
    })
    if not tab or not mux_window then
      log('capture.missing_target', { mux_window = mux_window ~= nil, tab = tab ~= nil })
      return false
    end

    local index = active_tab_index(mux_window, tab)
    local ok, snapshot, reason = pcall(sessionstore.capture_tab, tab, resume_args_for)
    if not ok or not snapshot then
      local failure = ok and reason or snapshot
      log('capture.failed', { error = failure, index = index, pcall_ok = ok })
      toast(window, 'Closed tab was not saved: ' .. tostring(failure))
      return false
    end

    local tabs, read_error = stack()
    if read_error then log('history.read_failed', { error = read_error }) end
    tabs[#tabs + 1] = { index = index, tab = snapshot }
    if #tabs > MAX_TABS then table.remove(tabs, 1) end
    local persisted, persist_error = persist_stack(tabs)
    if not persisted then
      log('history.persist_failed', { error = persist_error, operation = 'push' })
      toast(window, 'Closed tab was not saved: history persistence failed')
      return false
    end
    log('history.push', {
      count = #tabs,
      index = index,
      pane_count = #(snapshot.panes or {}),
      resume_pane_count = resume_pane_count(snapshot),
      tab_id = object_id(tab, 'tab_id'),
    })
    return true
  end

  local function reopen_tab()
    return wezterm.action_callback(function(window, pane)
      local tabs, read_error = stack()
      if read_error then log('history.read_failed', { error = read_error }) end
      local closed = tabs[#tabs]
      log('reopen.dispatch', {
        count = #tabs,
        pane_id = object_id(pane, 'pane_id'),
        window_id = object_id(window, 'window_id'),
      })
      if not closed then
        log('reopen.empty', {})
        toast(window, 'No recently closed tabs')
        return
      end

      log('restore.begin', {
        index = closed.index,
        pane_count = #((closed.tab or {}).panes or {}),
      })
      local ok, restored_tab, active_pane = pcall(
        sessionstore.restore_tab, window:mux_window(), closed.tab
      )
      if not ok or not restored_tab then
        local failure = ok and active_pane or restored_tab
        log('restore.failed', { error = failure, pcall_ok = ok })
        toast(window, 'Could not restore tab: ' .. tostring(failure))
        return
      end

      table.remove(tabs)
      local persisted, persist_error = persist_stack(tabs)
      if not persisted then
        log('history.persist_failed', { error = persist_error, operation = 'pop' })
      end
      local tab_count = #window:mux_window():tabs_with_info()
      local target_index = math.max(0, math.min(closed.index or tab_count - 1, tab_count - 1))
      window:perform_action(act.MoveTab(target_index), active_pane or pane)
      log('restore.succeeded', {
        history_count = #tabs,
        restored_tab_id = object_id(restored_tab, 'tab_id'),
        target_index = target_index,
      })
    end)
  end

  return {
    remember_tab = remember_tab,
    reopen_tab = reopen_tab,
  }
end

return M
