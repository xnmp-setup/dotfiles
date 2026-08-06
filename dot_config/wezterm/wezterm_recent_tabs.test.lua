-- Behavioral tests for wezterm_recent_tabs.lua. Run: lua wezterm_recent_tabs.test.lua

package.path = (arg[0]:match('(.*/)') or './') .. '?.lua;' .. package.path

local action = {
  MoveTab = function(index) return { kind = 'MoveTab', index = index } end,
}
local global = {}
local encoded_values = {}
local next_encoded_value = 0
local function deep_copy(value)
  if type(value) ~= 'table' then return value end
  local copy = {}
  for key, item in pairs(value) do copy[deep_copy(key)] = deep_copy(item) end
  return copy
end
package.preload.wezterm = function()
  return {
    GLOBAL = global,
    action = action,
    action_callback = function(callback) return callback end,
    json_encode = function(value)
      next_encoded_value = next_encoded_value + 1
      local encoded = 'encoded-' .. next_encoded_value
      encoded_values[encoded] = deep_copy(value)
      return encoded
    end,
    json_parse = function(encoded) return deep_copy(encoded_values[encoded]) end,
  }
end

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    io.write(string.format('FAIL %s\n  got:  [%s]\n  want: [%s]\n', name, tostring(got), tostring(want)))
  end
end

local captured, restored, restore_failure = {}, {}, nil
local sessionstore = {
  capture_tab = function(tab, resume_args_for)
    captured[#captured + 1] = tab.id
    if tab.capture_failure then return nil, tab.capture_failure end
    return { id = tab.id, resume = resume_args_for(tab.pane) }
  end,
  restore_tab = function(_, snapshot)
    restored[#restored + 1] = snapshot
    if restore_failure then return nil, restore_failure end
    return { id = snapshot.id }, { id = 'pane-' .. snapshot.id }
  end,
}

local agent = {
  resume_args_for = function(pane) return pane and pane.resume end,
}
local recent = require('wezterm_recent_tabs').setup { sessionstore = sessionstore, agent = agent }

local mux_tabs = {}
local active_tab
local performed, toasts = {}, {}
local mux_window = {
  tabs_with_info = function() return mux_tabs end,
}
local window = {
  active_tab = function() return active_tab end,
  mux_window = function() return mux_window end,
  perform_action = function(_, wezterm_action, pane)
    performed[#performed + 1] = { action = wezterm_action, pane = pane }
  end,
  toast_notification = function(_, _, message) toasts[#toasts + 1] = message end,
}

local function tab(id, resume)
  return {
    id = id,
    pane = { resume = resume },
    tab_id = function(self) return self.id end,
  }
end

local function remember(tabs, active)
  mux_tabs, active_tab = {}, active
  for index, item in ipairs(tabs) do
    mux_tabs[index] = { index = index - 1, tab = item }
  end
  return recent.remember_tab(window)
end

local a = tab('a')
local b = tab('b', { 'claude', '--resume' })
eq('remember/a', remember({ a, b }, a), true)
eq('remember/b', remember({ a, b }, b), true)
eq('capture/decorator applied', captured[#captured], 'b')
eq('history/stored as scalar JSON', type(global.recently_closed_tabs_v1), 'string')

-- A newly evaluated config must decode the history stored by the old config.
recent = require('wezterm_recent_tabs').setup { sessionstore = sessionstore, agent = agent }

-- Last closed comes back first and is moved to its original index.
mux_tabs = { { index = 0, tab = a }, { index = 1, tab = tab('restored') } }
recent.reopen_tab()(window, a.pane)
eq('restore/lifo first', restored[#restored].id, 'b')
eq('restore/resume argv retained', restored[#restored].resume[1], 'claude')
eq('restore/original index', performed[#performed].action.index, 1)
eq('restore/targets new pane', performed[#performed].pane.id, 'pane-b')

recent.reopen_tab()(window, b.pane)
eq('restore/lifo second', restored[#restored].id, 'a')
eq('restore/index clamped to live tabs', performed[#performed].action.index, 0)

recent.reopen_tab()(window, a.pane)
eq('restore/empty is visible', toasts[#toasts], 'No recently closed tabs')

-- Failed capture is not remembered.
local bad = tab('bad')
bad.capture_failure = 'zoomed pane'
eq('capture/failure reported', remember({ bad }, bad), false)
eq('capture/failure toast', toasts[#toasts], 'Closed tab was not saved: zoomed pane')
recent.reopen_tab()(window, bad.pane)
eq('capture/failure leaves stack empty', toasts[#toasts], 'No recently closed tabs')

-- Failed restore remains at the top so a transient domain failure can retry.
eq('retry/remember', remember({ a }, a), true)
restore_failure = 'domain unavailable'
recent.reopen_tab()(window, a.pane)
eq('retry/failure visible', toasts[#toasts], 'Could not restore tab: domain unavailable')
restore_failure = nil
recent.reopen_tab()(window, a.pane)
eq('retry/same snapshot retained', restored[#restored].id, 'a')

-- Bound memory use: after 25 closes, only the newest 20 remain (6..25).
for i = 1, 25 do
  local item = tab(i)
  remember({ item }, item)
end
local before = #restored
for _ = 1, 25 do recent.reopen_tab()(window, a.pane) end
eq('bounded/restored count', #restored - before, 20)
eq('bounded/oldest retained', restored[#restored].id, 6)
eq('bounded/exhausted visibly', toasts[#toasts], 'No recently closed tabs')

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
