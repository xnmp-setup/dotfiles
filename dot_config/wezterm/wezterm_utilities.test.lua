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
      call_after = function(delay, callback)
        scheduled[#scheduled + 1] = { delay = delay, run = callback }
      end,
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
    get_logical_lines_as_text = function(_, lines)
      opts.requested_lines = lines
      return opts.output or ''
    end,
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
-- Announcing is a property of the line, not of each URL on it: the first URL
-- on the first announcing line is the fallback, and a line that announces
-- nothing contributes no fallback however many URLs it carries.
eq(
  'url/announcing line contributes its first URL',
  utilities_module.extract_server_url('ready at https://a.example.com https://b.example.com'),
  'https://a.example.com'
)
eq(
  'url/non-announcing line contributes nothing',
  utilities_module.extract_server_url('deps https://a.example.com https://b.example.com'),
  nil
)
eq(
  'url/first announcing line wins',
  utilities_module.extract_server_url(
    'docs https://x.example.com\nlisten https://a.example.com\nready at https://b.example.com'
  ),
  'https://a.example.com'
)

-- Poll schedule: fast while a quick dev server is plausible, then backed off,
-- covering roughly twenty seconds of wall clock in total.
eq('poll/first gap is fast', utilities_module.url_poll_delay(1), 0.1)
eq('poll/fast phase continues', utilities_module.url_poll_delay(9), 0.1)
eq('poll/backs off after the fast phase', utilities_module.url_poll_delay(10), 0.5)
eq('poll/stays backed off', utilities_module.url_poll_delay(47), 0.5)
eq('poll/stops at the end of the window', utilities_module.url_poll_delay(48), nil)
eq('poll/stops beyond the end of the window', utilities_module.url_poll_delay(100), nil)

local schedule_total, schedule_reads, schedule_fast = 0, 1, 0
while utilities_module.url_poll_delay(schedule_reads) do
  local delay = utilities_module.url_poll_delay(schedule_reads)
  schedule_total = schedule_total + delay
  if delay == 0.1 then schedule_fast = schedule_fast + 1 end
  schedule_reads = schedule_reads + 1
end
eq('poll/fast phase covers about a second', string.format('%.1f', schedule_fast * 0.1), '0.9')
eq('poll/covers about twenty seconds', string.format('%.1f', schedule_total), '19.9')
eq('poll/reads far fewer than 200 times', schedule_reads, 48)

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
local yazi = pane { id = 5, process = '/usr/bin/yazi', cwd = '/work/my-app' }
local secondary = pane { id = 6, process = '/usr/bin/zsh', cwd = '/work/other' }
local current_active = shell
local zoomed_pane
shell.opts.on_activate = function(target) current_active = target end
keifu.opts.on_activate = function(target) current_active = target end
terminal.opts.on_activate = function(target) current_active = target end
yazi.opts.on_activate = function(target) current_active = target end
secondary.opts.on_activate = function(target) current_active = target end
local tab_panes = { shell }
local split_options
local split_source
local panes_by_command = { keifu = keifu, yazi = yazi }
local function add_split_behavior(source)
  source.split = function(_, options)
    split_source = source
    split_options = options
    local target = options.args and panes_by_command[options.args[1]] or terminal
    tab_panes[#tab_panes + 1] = target
    return target
  end
end
add_split_behavior(shell)
add_split_behavior(keifu)
add_split_behavior(yazi)
add_split_behavior(secondary)

local original_activations = 0
local original_tab = {
  tab_id = function() return 42 end,
  panes = function() return tab_panes end,
  panes_with_info = function()
    local result = {}
    for _, candidate in ipairs(tab_panes) do
      result[#result + 1] = {
        pane_id = candidate:pane_id(),
        is_zoomed = candidate == zoomed_pane,
      }
    end
    return result
  end,
  set_zoomed = function(_, zoomed)
    local prior = zoomed_pane ~= nil
    zoomed_pane = zoomed and current_active or nil
    return prior
  end,
  active_pane = function() return shell end,
  get_title = function() return 'shell' end,
  activate = function() original_activations = original_activations + 1 end,
}

local performed = {}
local toasts = {}
local spawned
local spawned_pane
local spawn_count = 0
local mux_tabs = { original_tab }
local spawn_output = 'VITE ready\nLocal: http://0.0.0.0:5173/'
local mux_window = {
  tabs = function() return mux_tabs end,
  spawn_tab = function(_, options)
    spawn_count = spawn_count + 1
    spawned = options
    local server = pane {
      id = 3,
      process = '/usr/bin/bun',
      cwd = '/work/my-app',
      output = spawn_output,
    }
    spawned_pane = server
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
      if zoomed_pane == target then zoomed_pane = nil end
    end
  end,
  toast_notification = function(_, _, message) toasts[#toasts + 1] = message end,
}

chord_by_key.g.action(window, shell)
eq('keifu/split direction', split_options.direction, 'Bottom')
eq('keifu/top-level split', split_options.top_level, true)
eq('keifu/split size', split_options.size, 0.40)
eq('keifu/command', split_options.args[1], 'keifu')
eq('keifu/does not use compact Yazi profile', split_options.set_environment_variables, nil)
eq('keifu/inherits invoking pane cwd', split_options.cwd, '/work/my-app')
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

-- Yazi and Keifu occupy one bottom shelf. Opening the second tool splits the
-- shelf horizontally, so the main pane is not resized repeatedly as tools are
-- independently opened and closed.
tab_panes = { shell }
current_active = shell
chord_by_key.e.action(window, shell)
eq('shelf/first tool splits main pane', split_source, shell)
eq('shelf/first tool opens below', split_options.direction, 'Bottom')
eq('shelf/first tool is top level', split_options.top_level, true)
eq('shelf/first tool uses 40 percent', split_options.size, 0.40)
eq(
  'shelf/yazi uses compact profile',
  split_options.set_environment_variables.YAZI_UTILITY_PANE,
  '1'
)
eq('shelf/yazi inherits invoking pane cwd', split_options.cwd, '/work/my-app')
eq('shelf/yazi opens invoking cwd as entry', split_options.args[2], '/work/my-app')

chord_by_key.g.action(window, yazi)
eq('shelf/second tool splits existing shelf', split_source, yazi)
eq('shelf/second tool opens beside first', split_options.direction, 'Right')
eq('shelf/second tool is local', split_options.top_level, nil)
eq('shelf/tools share width equally', split_options.size, 0.5)
eq('shelf/keifu peer does not use compact profile', split_options.set_environment_variables, nil)
eq('shelf/peer inherits invoking pane cwd', split_options.cwd, '/work/my-app')
eq('shelf/keifu has no cwd argument', split_options.args[2], nil)
eq('shelf/both tools are present', #tab_panes, 3)

chord_by_key.e.action(window, keifu)
eq('shelf/closing first tool preserves main and peer', #tab_panes, 2)
eq('shelf/first close targets yazi', performed[#performed].target, yazi)
chord_by_key.g.action(window, shell)
eq('shelf/closing final tool leaves main pane', #tab_panes, 1)
eq('shelf/final close targets keifu', performed[#performed].target, keifu)
eq('shelf/main pane survives both closes', tab_panes[1], shell)

chord_by_key.g.action(window, shell)
eq('shelf/reverse order starts below main', split_source, shell)
chord_by_key.e.action(window, keifu)
eq('shelf/reverse order reuses existing shelf', split_source, keifu)
eq('shelf/reverse order opens peer beside first', split_options.direction, 'Right')
chord_by_key.g.action(window, yazi)
chord_by_key.e.action(window, shell)
eq('shelf/reverse order also restores main pane', tab_panes[1], shell)
eq('shelf/reverse order closes both tools', #tab_panes, 1)

-- The initial shelf split is tab-level, so a tab that is already split still
-- gets one full-width utility shelf at the bottom rather than a nested pane.
tab_panes = { shell, secondary }
current_active = secondary
chord_by_key.e.action(window, secondary)
eq('shelf/pre-split tab uses invoking pane', split_source, secondary)
eq('shelf/pre-split tab opens at tab level', split_options.top_level, true)
eq('shelf/pre-split tab keeps 40 percent size', split_options.size, 0.40)
eq('shelf/pre-split tab preserves existing panes', #tab_panes, 3)
chord_by_key.e.action(window, shell)
eq('shelf/pre-split tab restores existing panes', #tab_panes, 2)

-- The terminal split matches cmd+alt+; except for its requested 35% size. Its
-- PTY remains in the tab while hidden so long-running jobs survive the toggle.
tab_panes = { shell }
current_active = shell
zoomed_pane = nil
chord_by_key.t.action(window, shell)
eq('terminal/split direction', split_options.direction, 'Bottom')
eq('terminal/uses default shell', split_options.args, nil)
eq('terminal/uses tab-level split geometry', split_options.top_level, true)
eq('terminal/uses 35 percent size', split_options.size, 0.35)
eq('terminal/opens below shell', tab_panes[2], terminal)

terminal.opts.process = '/usr/bin/bun'
shell:activate()
local close_count_before_hide = #performed
chord_by_key.t.action(window, shell)
eq('terminal/hide keeps pane alive', #tab_panes, 2)
eq('terminal/hide does not close pane', #performed, close_count_before_hide)
eq('terminal/hide zooms owner', zoomed_pane, shell)
eq('terminal/hide preserves running process', terminal.opts.process, '/usr/bin/bun')

chord_by_key.t.action(window, shell)
eq('terminal/show restores split layout', zoomed_pane, nil)
eq('terminal/show activates existing pane', current_active, terminal)
eq('terminal/show reuses original pane', tab_panes[2], terminal)

-- Pane and owner ids survive config reload; a shell-only persistent terminal is
-- still found by id without misidentifying the main shell.
terminal.opts.process = '/usr/bin/zsh'
shell:activate()
local reloaded_config = {}
local reloaded_utilities = utilities_module.setup(reloaded_config)
local reloaded_chord = {}
for _, binding in ipairs(reloaded_config.key_tables.utility_chord) do
  reloaded_chord[binding.key] = binding
end
eq('terminal/reload preserves chord action', type(reloaded_chord.t.action), 'function')
reloaded_chord.t.action(window, shell)
eq('terminal/reload toggle keeps terminal', tab_panes[2], terminal)
eq('terminal/reload toggle hides terminal', zoomed_pane, shell)
reloaded_chord.t.action(window, shell)
eq('terminal/reload toggle restores terminal', current_active, terminal)
eq('terminal/reload toggle retains two panes', #tab_panes, 2)
eq('terminal/reload exposes activator', reloaded_utilities.activate_chord.value.name, 'utility_chord')

tab_panes = { terminal }
current_active = terminal
zoomed_pane = nil
local terminal_pane_count = #tab_panes
reloaded_chord.t.action(window, terminal)
eq('terminal/last pane remains alive', #tab_panes, terminal_pane_count)
eq(
  'terminal/last pane directs user to close tab',
  toasts[#toasts],
  'The persistent terminal is the last pane; close the tab to stop it.'
)

tab_panes = { shell, terminal }
current_active = shell

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

-- A server that never announces a URL is polled on the backed-off schedule,
-- reads only a bounded slice of scrollback, and eventually explains itself
-- rather than polling forever.
local polling_config = {}
utilities_module.setup(polling_config)
local polling_chord = {}
for _, binding in ipairs(polling_config.key_tables.utility_chord) do
  polling_chord[binding.key] = binding
end

spawn_output = ''
scheduled = {}
polling_chord.d.action(window, secondary)
eq('dev/reads a bounded slice of scrollback', spawned_pane.opts.requested_lines, 60)
eq('dev/silent server schedules a retry', #scheduled, 1)
eq('dev/first retry is fast', scheduled[1].delay, 0.1)

local observed_reads, observed_total = 1, 0
while #scheduled > 0 do
  local next_poll = table.remove(scheduled, 1)
  observed_total = observed_total + next_poll.delay
  observed_reads = observed_reads + 1
  next_poll.run()
end
eq('dev/silent server is read 48 times', observed_reads, 48)
eq('dev/silent server is polled for about twenty seconds', string.format('%.1f', observed_total), '19.9')
eq(
  'dev/silent server explains itself',
  toasts[#toasts],
  'Dev server is still running, but did not publish a URL.'
)

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
