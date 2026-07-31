-- Behavioral tests for wezterm_close.lua. Run: lua wezterm_close.test.lua

package.path = (arg[0]:match('(.*/)') or './') .. '?.lua;' .. package.path

local function format(items)
  local text = {}
  for _, item in ipairs(items) do
    if type(item) == 'table' and item.Text then text[#text + 1] = item.Text end
  end
  return table.concat(text)
end

local action = setmetatable({}, {
  __index = function(_, name)
    return function(value) return { kind = name, value = value } end
  end,
})

package.preload.wezterm = function()
  return {
    action = action,
    action_callback = function(callback) return callback end,
    format = format,
  }
end

local close_module = require 'wezterm_close'

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    io.write(string.format('FAIL %s\n  got:  [%s]\n  want: [%s]\n', name, tostring(got), tostring(want)))
  end
end

local function contains(name, value, pattern)
  eq(name, value:find(pattern, 1, true) ~= nil, true)
end

local function proc(executable, children)
  return { executable = executable, name = executable, children = children or {} }
end

local function pane(info, fallback_name)
  return {
    get_foreground_process_info = function()
      if info == false then error('process info unavailable') end
      return info
    end,
    get_foreground_process_name = function() return fallback_name end,
  }
end

eq('basename/unix', close_module.process_basename('/usr/bin/bun'), 'bun')
eq('basename/windows', close_module.process_basename('C:\\Tools\\pwsh.exe'), 'pwsh.exe')
eq('basename/nil', close_module.process_basename(nil), nil)
eq('stateful/shell', close_module.is_stateful_process('/usr/bin/zsh'), false)
eq('stateful/gitstatus helper', close_module.is_stateful_process('/tmp/gitstatusd-linux-x86_64'), false)
eq('stateful/dev server', close_module.is_stateful_process('/usr/bin/bun'), true)

local nested = proc('/usr/bin/zsh', {
  [12] = proc('/tmp/gitstatusd-linux-x86_64'),
  [13] = proc('/usr/bin/bash', { [14] = proc('/usr/bin/bun') }),
})
eq('tree/find nested stateful process', close_module.find_stateful_process(nested), 'bun')
eq('tree/all stateless', close_module.find_stateful_process(proc('/usr/bin/zsh')), nil)

local close = close_module.setup()
local performed = {}
local active_panes = {}
local window = {
  perform_action = function(_, wezterm_action, target)
    performed[#performed + 1] = { action = wezterm_action, target = target }
  end,
  active_tab = function()
    return { panes = function() return active_panes end }
  end,
}

local idle_shell = pane(proc('/usr/bin/zsh'))
close.close_pane()(window, idle_shell)
eq('pane/idle shell closes immediately', performed[#performed].action.kind, 'CloseCurrentPane')
eq('pane/idle shell skips confirmation', performed[#performed].action.value.confirm, false)

local codex = pane(proc('/usr/bin/codex'))
close.close_pane()(window, codex)
local confirmation = performed[#performed].action
eq('pane/stateful uses confirmation overlay', confirmation.kind, 'Confirmation')
contains('pane/message names scope', confirmation.value.message, 'Close this pane?')
contains('pane/message names process', confirmation.value.message, 'codex')
confirmation.value.action(window, codex)
eq('pane/accept closes pane', performed[#performed].action.kind, 'CloseCurrentPane')

local hidden_terminal = pane(nested)
active_panes = { idle_shell, hidden_terminal }
close.close_tab()(window, idle_shell)
confirmation = performed[#performed].action
eq('tab/hidden daemon prompts', confirmation.kind, 'Confirmation')
contains('tab/message names scope', confirmation.value.message, 'Close this tab?')
contains('tab/message names hidden process', confirmation.value.message, 'bun')
contains('tab/message explains consequence', confirmation.value.message, 'All panes in this tab will be terminated.')
confirmation.value.action(window, idle_shell)
eq('tab/accept closes whole tab', performed[#performed].action.kind, 'CloseCurrentTab')

local remote_process = pane(false, '/usr/bin/ssh')
close.close_pane()(window, remote_process)
eq('pane/fallback process name prompts', performed[#performed].action.kind, 'Confirmation')
contains('pane/fallback process shown', performed[#performed].action.value.message, 'ssh')

active_panes = { idle_shell, pane(proc('/usr/bin/bash')) }
close.close_tab()(window, idle_shell)
eq('tab/all shells closes immediately', performed[#performed].action.kind, 'CloseCurrentTab')

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
