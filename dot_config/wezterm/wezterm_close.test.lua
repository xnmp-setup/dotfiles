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
    log_error = function() end,
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

local function pane(info, fallback_name, user_vars)
  return {
    get_foreground_process_info = function()
      if info == false then error('process info unavailable') end
      return info
    end,
    get_foreground_process_name = function() return fallback_name end,
    get_user_vars = function() return user_vars end,
  }
end

-- The overlay pane runs no process, which is how confirmation_active spots it.
local overlay_pane = { get_foreground_process_name = function() return nil end }

eq('basename/unix', close_module.process_basename('/usr/bin/bun'), 'bun')
eq('basename/windows', close_module.process_basename('C:\\Tools\\pwsh.exe'), 'pwsh.exe')
eq('basename/nil', close_module.process_basename(nil), nil)
eq('stateful/shell', close_module.is_stateful_process('/usr/bin/zsh'), false)
eq('stateful/gitstatus helper', close_module.is_stateful_process('/tmp/gitstatusd-linux-x86_64'), false)
eq('stateful/dev server', close_module.is_stateful_process('/usr/bin/bun'), true)

-- Versioned binaries get a readable name from the path, not the version.
eq('display/plain basename', close_module.display_name('/usr/bin/bun'), 'bun')
eq('display/version resolves app dir',
  close_module.display_name('/home/x/.local/share/claude/versions/2.1.222'), 'claude')
eq('display/v-prefixed version', close_module.display_name('/opt/tool/versions/v1.2'), 'tool')
eq('display/versioned dir keeps real basename',
  close_module.display_name('/opt/foo-1.2.3/bin/app'), 'app')
eq('display/nil', close_module.display_name(nil), nil)

local nested = proc('/usr/bin/zsh', {
  [12] = proc('/tmp/gitstatusd-linux-x86_64'),
  [13] = proc('/usr/bin/bash', { [14] = proc('/usr/bin/bun') }),
})
eq('tree/find nested stateful process', close_module.find_stateful_process(nested), 'bun')
eq('tree/all stateless', close_module.find_stateful_process(proc('/usr/bin/zsh')), nil)

local remembered_tabs = 0
local close = close_module.setup {
  before_close_tab = function() remembered_tabs = remembered_tabs + 1 end,
}
local performed = {}
local active_panes = {}
local active_tab_id = 7
local window = {
  window_id = function() return 1 end,
  perform_action = function(_, wezterm_action, target)
    performed[#performed + 1] = { action = wezterm_action, target = target }
  end,
  active_tab = function()
    return {
      tab_id = function() return active_tab_id end,
      panes = function() return active_panes end,
    }
  end,
}
local function last() return performed[#performed] end

-- Idle shells close immediately, no prompt.
local idle_shell = pane(proc('/usr/bin/zsh'))
active_panes = { idle_shell, pane(proc('/usr/bin/bash')) }
close.close_pane()(window, idle_shell)
eq('pane/idle shell closes immediately', last().action.kind, 'CloseCurrentPane')
eq('pane/idle shell skips confirmation', last().action.value.confirm, false)
eq('pane/idle shell leaves enter alone', close.confirmation_active(window, overlay_pane), false)
eq('pane/close is not remembered as tab', remembered_tabs, 0)

-- Stateful pane: centered Confirmation overlay; Enter maps to y while it is up.
local claude = pane(proc('/home/x/.local/share/claude/versions/2.1.222'),
  '/home/x/.local/share/claude/versions/2.1.222')
active_panes = { claude, idle_shell }
close.close_pane()(window, claude)
local confirmation = last().action
eq('pane/stateful uses confirmation overlay', confirmation.kind, 'Confirmation')
contains('pane/message names scope', confirmation.value.message, 'Close this pane?')
contains('pane/message names process', confirmation.value.message, 'claude')
eq('pane/enter maps to y on the overlay', close.confirmation_active(window, overlay_pane), true)
eq('pane/enter stays normal in a process pane', close.confirmation_active(window, claude), false)
active_tab_id = 8
eq('pane/enter stays normal in another tab', close.confirmation_active(window, overlay_pane), false)
active_tab_id = 7

-- Accepting closes the pane and releases the Enter mapping.
confirmation.value.action(window, claude)
eq('pane/accept closes pane', last().action.kind, 'CloseCurrentPane')
eq('pane/accept releases enter', close.confirmation_active(window, overlay_pane), false)

-- Cancelling (n/Esc/mouse) releases the Enter mapping without closing.
close.close_pane()(window, claude)
local before_cancel = #performed
last().action.value.cancel(window)
eq('pane/cancel closes nothing', #performed, before_cancel)
eq('pane/cancel releases enter', close.confirmation_active(window, overlay_pane), false)

-- Tab close sees hidden stateful panes.
local hidden_terminal = pane(nested)
active_panes = { idle_shell, hidden_terminal }
close.close_tab()(window, idle_shell)
confirmation = last().action
eq('tab/hidden daemon prompts', confirmation.kind, 'Confirmation')
eq('tab/not remembered before confirmation', remembered_tabs, 0)
contains('tab/message names scope', confirmation.value.message, 'Close this tab?')
contains('tab/message names hidden process', confirmation.value.message, 'bun')
contains('tab/message explains consequence', confirmation.value.message,
  'All panes in this tab will be terminated.')
confirmation.value.cancel(window)
eq('tab/cancel is not remembered', remembered_tabs, 0)
close.close_tab()(window, idle_shell)
confirmation = last().action
confirmation.value.action(window, idle_shell)
eq('tab/accept closes whole tab', last().action.kind, 'CloseCurrentTab')
eq('tab/accept remembered once', remembered_tabs, 1)

-- Process info unavailable: fall back to the foreground process name.
local remote_process = pane(false, '/usr/bin/ssh')
close.close_pane()(window, remote_process)
eq('pane/fallback process name prompts', last().action.kind, 'Confirmation')
contains('pane/fallback process shown', last().action.value.message, 'ssh')
last().action.value.cancel(window)

active_panes = { idle_shell, pane(proc('/usr/bin/bash')) }
close.close_tab()(window, idle_shell)
eq('tab/all shells closes immediately', last().action.kind, 'CloseCurrentTab')
eq('tab/direct close remembered', remembered_tabs, 2)

-- Ctrl+W is a pane-close action, but closing the tab's final pane also closes
-- the tab. That path must enter recently-closed history just like CloseCurrentTab.
active_panes = { idle_shell }
close.close_pane()(window, idle_shell)
eq('pane/final shell closes immediately', last().action.kind, 'CloseCurrentPane')
eq('pane/final shell remembers tab', remembered_tabs, 3)

active_panes = { claude }
close.close_pane()(window, claude)
confirmation = last().action
eq('pane/final process prompts', confirmation.kind, 'Confirmation')
eq('pane/final process not remembered before confirmation', remembered_tabs, 3)
confirmation.value.cancel(window)
eq('pane/final process cancel is not remembered', remembered_tabs, 3)
close.close_pane()(window, claude)
confirmation = last().action
confirmation.value.action(window, claude)
eq('pane/final process accept closes pane', last().action.kind, 'CloseCurrentPane')
eq('pane/final process accept remembers tab', remembered_tabs, 4)

-- WEZTERM_PROG resolution (pure): the var is authoritative for WSL panes.
do
  local p, resolved = close_module.user_var_process({ WEZTERM_PROG = 'zsh' })
  eq('uservar/idle zsh → nil', p, nil)
  eq('uservar/idle zsh resolved', resolved, true)
  p, resolved = close_module.user_var_process({ WEZTERM_PROG = 'git status' })
  eq('uservar/running cmd → basename', p, 'git')
  eq('uservar/running cmd resolved', resolved, true)
  p, resolved = close_module.user_var_process({})
  eq('uservar/absent → nil', p, nil)
  eq('uservar/absent not resolved', resolved, false)
end

-- Integration: a WSL pane whose OS process is the wslhost.exe proxy (stateful-
-- looking) but WEZTERM_PROG says "zsh" must close WITHOUT a confirmation.
local wsl_idle = pane(proc('C:\\Windows\\wslhost.exe'), nil, { WEZTERM_PROG = 'zsh' })
close.close_pane()(window, wsl_idle)
eq('pane/WSL idle shell skips confirmation via user var',
   performed[#performed].action.kind, 'CloseCurrentPane')

-- Same proxy, but a real command is running per WEZTERM_PROG → confirm.
local wsl_busy = pane(proc('C:\\Windows\\wslhost.exe'), nil, { WEZTERM_PROG = 'bun run dev' })
close.close_pane()(window, wsl_busy)
eq('pane/WSL running cmd prompts via user var', performed[#performed].action.kind, 'Confirmation')
contains('pane/WSL running cmd named', performed[#performed].action.value.message, 'bun')

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
