-- Contract test for the user key table. Run: lua wezterm_keybindings.test.lua

package.path = (arg[0]:match('(.*/)') or './') .. '?.lua;' .. package.path

local action = setmetatable({}, {
  __index = function(_, name)
    return function(value) return { kind = name, value = value } end
  end,
})
package.preload.wezterm = function()
  return {
    action = action,
    action_callback = function(callback) return callback end,
    target_triple = 'x86_64-pc-windows-msvc',
  }
end
package.preload.wezterm_clipboard = function()
  return { paste_action = function() return { kind = 'Paste' } end }
end

local marker = function(name) return { kind = name } end
local action_factory = function(name) return function() return marker(name) end end
local reopened = 0
local config = {}
require('wezterm_keybindings').apply(config, {
  navigation = {
    spawn_tab_next = action_factory('spawn-tab-next'),
  },
  windowing = { move_tab_to_window = action_factory('move-tab-to-window') },
  background = {
    spawn_tab = action_factory('spawn-bg-tab'),
    detach_tab = action_factory('detach-bg-tab'),
    reattach_tab = action_factory('reattach-bg-tab'),
  },
  agent = {
    page_keys_scroll_terminal = function() return false end,
    mark_done = function() end,
  },
  utilities = { activate_chord = marker('utility-chord') },
  close = {
    close_pane = action_factory('close-pane'),
    close_tab = action_factory('close-tab'),
    confirmation_active = function() return false end,
  },
  output = { copy_previous_command = marker('copy-previous-command') },
  recent_tabs = {
    reopen_tab = function()
      reopened = reopened + 1
      return marker('reopen-tab')
    end,
  },
})

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    io.write(string.format('FAIL %s\n  got:  [%s]\n  want: [%s]\n', name, tostring(got), tostring(want)))
  end
end

local matches = {}
for _, binding in ipairs(config.keys or {}) do
  if binding.key == 't' and binding.mods == 'CTRL|SHIFT' then matches[#matches + 1] = binding end
end
eq('ctrl-shift-t/one binding', #matches, 1)
eq('ctrl-shift-t/restores tab', matches[1] and matches[1].action.kind, 'reopen-tab')
eq('ctrl-shift-t/action built once', reopened, 1)

local function find_binding(key, mods)
  for _, binding in ipairs(config.keys or {}) do
    if binding.key == key and binding.mods == mods then return binding end
  end
end

local previous_tab = find_binding('PageUp', 'CTRL')
eq('ctrl-pageup/wraps to previous tab', previous_tab and previous_tab.action.kind, 'ActivateTabRelative')
eq('ctrl-pageup/moves left', previous_tab and previous_tab.action.value, -1)

local next_tab = find_binding('PageDown', 'CTRL')
eq('ctrl-pagedown/wraps to next tab', next_tab and next_tab.action.kind, 'ActivateTabRelative')
eq('ctrl-pagedown/moves right', next_tab and next_tab.action.value, 1)

local performed = {}
local window = {
  get_selection_text_for_pane = function() return '' end,
  perform_action = function(_, performed_action)
    performed[#performed + 1] = performed_action
  end,
}

local enter = find_binding('Enter', 'NONE')
enter.action(window, {})
eq('windows/enter uses raw bytes', performed[#performed].kind, 'SendString')
eq('windows/enter sends carriage return', performed[#performed].value, '\r')

local ctrl_c = find_binding('c', 'CTRL')
ctrl_c.action(window, {})
eq('windows/ctrl-c uses raw bytes', performed[#performed].kind, 'SendString')
eq('windows/ctrl-c sends interrupt', performed[#performed].value, '\x03')
eq('windows/escape callback is omitted', find_binding('Escape', 'NONE'), nil)

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
