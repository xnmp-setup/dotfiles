-- Behavioral tests for wezterm_utilities.lua. Run: lua wezterm_utilities.test.lua

package.path = (arg[0]:match('(.*/)') or './') .. '?.lua;' .. package.path

local opened_urls = {}
local scheduled = {}
local action = setmetatable({
  PopKeyTable = { kind = 'PopKeyTable' },
}, {
  __index = function(_, name)
    return function(value) return { kind = name, value = value } end
  end,
})

package.preload.wezterm = function()
  return {
    GLOBAL = {},
    action = action,
    action_callback = function(callback) return callback end,
    open_with = function(url) opened_urls[#opened_urls + 1] = url end,
    time = {
      call_after = function(_, callback) scheduled[#scheduled + 1] = callback end,
    },
  }
end

local utilities_module = require 'wezterm_utilities'

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    io.write(string.format('FAIL %s\n  got:  [%s]\n  want: [%s]\n', name, tostring(got), tostring(want)))
  end
end

local function pane(opts)
  opts = opts or {}
  return {
    pane_id = function() return opts.id end,
    get_foreground_process_name = function() return opts.process end,
    get_current_working_dir = function() return { file_path = opts.cwd } end,
    get_logical_lines_as_text = function() return opts.output or '' end,
    activate = function(self)
      opts.activations = (opts.activations or 0) + 1
      if opts.on_activate then opts.on_activate(self) end
    end,
    opts = opts,
  }
end

eq('process basename/unix', utilities_module.process_basename('/usr/bin/yazi'), 'yazi')
eq('process basename/windows', utilities_module.process_basename('C:\\tools\\keifu.exe'), 'keifu.exe')
eq('process basename/nil', utilities_module.process_basename(nil), nil)
eq(
  'url/vite loopback',
  utilities_module.extract_server_url('VITE ready\n  Local: http://localhost:5173/'),
  'http://localhost:5173/'
)
eq(
  'url/wildcard rewritten for browser',
  utilities_module.extract_server_url('Listening on http://0.0.0.0:3000.'),
  'http://127.0.0.1:3000'
)
eq(
  'url/ignores unrelated package link',
  utilities_module.extract_server_url('Dev server docs: https://bun.sh/docs\nno server yet'),
  nil
)
eq(
  'url/ipv6 wildcard rewritten for browser',
  utilities_module.extract_server_url('Listening on http://[::]:4321/'),
  'http://[::1]:4321/'
)
eq(
  'url/private 172 network',
  utilities_module.extract_server_url('Network: http://172.31.2.9:4173/'),
  'http://172.31.2.9:4173/'
)
eq(
  'url/private network server',
  utilities_module.extract_server_url('Network: http://192.168.1.8:4173/'),
  'http://192.168.1.8:4173/'
)
eq(
  'url/large output',
  utilities_module.extract_server_url(string.rep('x', 100000) .. '\nready at http://localhost:8080'),
  'http://localhost:8080'
)
eq('dev title/unix', utilities_module.dev_tab_title('/work/my-app/'), 'dev · my-app')
eq('dev title/windows', utilities_module.dev_tab_title('C:\\work\\my-app'), 'dev · my-app')

local config = {}
local utilities = utilities_module.setup(config)
local chord = config.key_tables.utility_chord
local chord_by_key = {}
for _, binding in ipairs(chord) do chord_by_key[binding.key] = binding end

eq('chord/name', utilities.activate_chord.value.name, 'utility_chord')
eq('chord/one shot', utilities.activate_chord.value.one_shot, true)
eq('chord/timeout', utilities.activate_chord.value.timeout_milliseconds, 2000)
eq('chord/yazi key', type(chord_by_key.e.action), 'function')
eq('chord/keifu key', type(chord_by_key.g.action), 'function')
eq('chord/terminal key', type(chord_by_key.t.action), 'function')
eq('chord/dev key', type(chord_by_key.d.action), 'function')

local shell = pane { id = 1, process = '/usr/bin/zsh', cwd = '/work/my-app' }
local keifu = pane { id = 2, process = '/usr/bin/keifu', cwd = '/work/my-app' }
local terminal = pane { id = 4, process = '/usr/bin/zsh', cwd = '/work/my-app' }
local current_active = shell
shell.opts.on_activate = function(target) current_active = target end
keifu.opts.on_activate = function(target) current_active = target end
terminal.opts.on_activate = function(target) current_active = target end
local tab_panes = { shell }
local split_options
shell.split = function(_, options)
  split_options = options
  local target = options.args and keifu or terminal
  tab_panes[#tab_panes + 1] = target
  return target
end

local original_activations = 0
local original_tab = {
  tab_id = function() return 42 end,
  panes = function() return tab_panes end,
  active_pane = function() return shell end,
  get_title = function() return 'shell' end,
  activate = function() original_activations = original_activations + 1 end,
}

local performed = {}
local toasts = {}
local spawned
local spawn_count = 0
local mux_tabs = { original_tab }
local mux_window = {
  tabs = function() return mux_tabs end,
  spawn_tab = function(_, options)
    spawn_count = spawn_count + 1
    spawned = options
    local server = pane {
      id = 3,
      process = '/usr/bin/bun',
      cwd = '/work/my-app',
      output = 'VITE ready\nLocal: http://0.0.0.0:5173/',
    }
    local title
    local server_tab = {
      set_title = function(_, value) title = value end,
      get_title = function() return title end,
      active_pane = function() return server end,
    }
    mux_tabs[#mux_tabs + 1] = server_tab
    return server_tab, server
  end,
}

local window = {
  active_tab = function() return original_tab end,
  mux_window = function() return mux_window end,
  perform_action = function(_, wezterm_action, _context_pane)
    -- CloseCurrentPane operates on the focused GUI pane, matching WezTerm's
    -- observed behavior when a mux pane is supplied as the context argument.
    local target = current_active
    performed[#performed + 1] = { action = wezterm_action, target = target }
    if wezterm_action.kind == 'CloseCurrentPane' then
      for i, candidate in ipairs(tab_panes) do
        if candidate == target then table.remove(tab_panes, i); break end
      end
      current_active = tab_panes[1]
    end
  end,
  toast_notification = function(_, _, message) toasts[#toasts + 1] = message end,
}

chord_by_key.g.action(window, shell)
eq('keifu/split direction', split_options.direction, 'Bottom')
eq('keifu/top-level split', split_options.top_level, true)
eq('keifu/split size', split_options.size, 0.40)
eq('keifu/command', split_options.args[1], 'keifu')
eq('keifu/activates new pane', keifu.opts.activations, 1)

-- Regression: after focusing the shell and starting Codex, toggling Keifu must
-- focus and close the tracked mux pane rather than closing the active Codex pane.
shell:activate()
shell.opts.process = '/usr/bin/codex'
keifu.opts.process = '/usr/bin/nvim'
chord_by_key.g.action(window, shell)
eq('keifu/toggle closes pane', performed[#performed].action.kind, 'CloseCurrentPane')
eq('keifu/toggle closes tracked pane', performed[#performed].target, keifu)
eq('keifu/toggle skips confirmation', performed[#performed].action.value.confirm, false)
eq('keifu/toggle preserves codex pane', tab_panes[1], shell)

chord_by_key.g.action(window, shell)
eq('keifu/next toggle reopens pane', #tab_panes, 2)

-- Never turn a utility toggle into an implicit close-tab operation.
tab_panes = { keifu }
current_active = keifu
local close_count = #performed
chord_by_key.g.action(window, keifu)
eq('keifu/last pane is not closed', #performed, close_count)
eq('keifu/last pane explains refusal', toasts[#toasts], 'keifu is the last pane; refusing to close the tab.')

-- The terminal split matches cmd+alt+; except for its requested 35% size, and
-- remains toggleable after reload despite matching the main zsh process.
tab_panes = { shell }
current_active = shell
chord_by_key.t.action(window, shell)
eq('terminal/split direction', split_options.direction, 'Bottom')
eq('terminal/uses default shell', split_options.args, nil)
eq('terminal/uses local split geometry', split_options.top_level, nil)
eq('terminal/uses 35 percent size', split_options.size, 0.35)
eq('terminal/opens below shell', tab_panes[2], terminal)

shell:activate()
local reloaded_config = {}
local reloaded_utilities = utilities_module.setup(reloaded_config)
local reloaded_chord = {}
for _, binding in ipairs(reloaded_config.key_tables.utility_chord) do
  reloaded_chord[binding.key] = binding
end
eq('terminal/reload preserves chord action', type(reloaded_chord.t.action), 'function')
reloaded_chord.t.action(window, shell)
eq('terminal/reload toggle closes terminal', performed[#performed].target, terminal)
eq('terminal/reload toggle preserves shell', tab_panes[1], shell)
eq('terminal/reload toggle leaves one pane', #tab_panes, 1)
eq('terminal/reload exposes activator', reloaded_utilities.activate_chord.value.name, 'utility_chord')

chord_by_key.d.action(window, shell)
eq('dev/command', table.concat(spawned.args, ' '), 'bun run dev')
eq('dev/cwd', spawned.cwd, '/work/my-app')
eq('dev/domain', spawned.domain, 'CurrentPaneDomain')
eq('dev/remains in original tab', original_activations, 1)
eq('dev/opens announced URL', opened_urls[#opened_urls], 'http://127.0.0.1:5173/')
eq('dev/immediate URL avoids polling', #scheduled, 0)

chord_by_key.d.action(window, shell)
eq('dev/reuses project server', spawn_count, 1)
eq('dev/reopens existing server URL', #opened_urls, 2)

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
