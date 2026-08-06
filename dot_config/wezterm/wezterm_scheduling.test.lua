-- Behavioral tests for CPU scheduling boundaries. Run: lua wezterm_scheduling.test.lua
package.path = (arg[0]:match('(.*/)') or './') .. '?.lua;' .. package.path

local fake_wezterm = {
  target_triple = 'x86_64-unknown-linux-gnu',
  exec_domain = function(name, fixup) return { name = name, fixup = fixup } end,
}
package.preload.wezterm = function() return fake_wezterm end

local scheduling = require 'wezterm_scheduling'
local passed, failed = 0, 0

local function eq(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    io.write(string.format('FAIL %s\n  got:  [%s]\n  want: [%s]\n', name, tostring(got), tostring(want)))
  end
end

local function contains(values, wanted)
  for _, value in ipairs(values or {}) do
    if value == wanted then return true end
  end
  return false
end

local original = { 'zsh', '-l' }
eq('Linux exposes the scheduled pane domain', scheduling.pane_domain(), 'cpu-limited')
local wrapped = scheduling.scope_command(original, {
  allowed_cpus = '2-3,6-7',
  unit = 'pane-1',
})
eq('linux command uses systemd-run', wrapped[1], 'systemd-run')
eq('pane scope has low CPU weight', contains(wrapped, '--property=CPUWeight=10'), true)
eq('pane scope excludes reserved cores',
  contains(wrapped, '--property=AllowedCPUs=2-3,6-7'), true)
eq('pane scope preserves argv', wrapped[#wrapped - 1], 'zsh')
eq('pane scope preserves final argument', wrapped[#wrapped], '-l')
eq('scope adapter does not mutate argv', #original, 2)

local function topology(values)
  return function(path) return values[path] end
end

local four_smt_cores = {
  ['/sys/devices/system/cpu/online'] = '0-7',
  ['/sys/devices/system/cpu/cpu0/topology/thread_siblings_list'] = '0,4',
  ['/sys/devices/system/cpu/cpu1/topology/thread_siblings_list'] = '1,5',
  ['/sys/devices/system/cpu/cpu2/topology/thread_siblings_list'] = '2,6',
  ['/sys/devices/system/cpu/cpu3/topology/thread_siblings_list'] = '3,7',
}
eq('two complete physical cores are reserved',
  scheduling.workload_cpu_set(topology(four_smt_cores)), '2-3,6-7')
eq('reservation count can be overridden',
  scheduling.workload_cpu_set(topology(four_smt_cores), 1), '1-3,5-7')
eq('missing topology falls back to one logical CPU per core',
  scheduling.workload_cpu_set(topology({
    ['/sys/devices/system/cpu/online'] = '0-3',
  })), '2-3')
eq('small systems retain a workload core',
  scheduling.workload_cpu_set(topology({
    ['/sys/devices/system/cpu/online'] = '0-1',
  })), '1')
eq('one physical core cannot be safely isolated',
  scheduling.workload_cpu_set(topology({
    ['/sys/devices/system/cpu/online'] = '0-1',
    ['/sys/devices/system/cpu/cpu0/topology/thread_siblings_list'] = '0-1',
  })), nil)
eq('missing online CPU data disables isolation',
  scheduling.workload_cpu_set(topology({})), nil)
eq('malformed online CPU data disables isolation',
  scheduling.workload_cpu_set(topology({
    ['/sys/devices/system/cpu/online'] = '0-nope',
  })), nil)
eq('unreasonably large CPU ranges are rejected',
  scheduling.workload_cpu_set(topology({
    ['/sys/devices/system/cpu/online'] = '0-999999',
  })), nil)

local config = { exec_domains = { { name = 'existing' } } }
scheduling.apply(config)
eq('existing exec domains survive', config.exec_domains[1].name, 'existing')
eq('CPU-limited domain is appended', config.exec_domains[2].name, 'cpu-limited')
eq('CPU-limited domain becomes the default', config.default_domain, 'cpu-limited')

local spawn = {
  args = { 'bun', 'run', 'test:e2e' },
  cwd = '/repo',
  set_environment_variables = {
    WEZTERM_PANE = '42',
    WEZTERM_UNIX_SOCKET = '/run/user/1000/wezterm/gui-sock-7',
  },
}
local revised = config.exec_domains[2].fixup(spawn)
eq('fixup preserves SpawnCommand fields', revised.cwd, '/repo')
eq('fixup does not mutate caller args', spawn.args[1], 'bun')
eq('pane and GUI socket identify the scope',
  contains(revised.args, '--unit=wezterm-pane-42-on-gui-sock-7'), true)
eq('explicit command remains intact', revised.args[#revised.args - 2], 'bun')
eq('explicit subcommand remains intact', revised.args[#revised.args], 'test:e2e')

local malformed = scheduling.pane_scope_command({ set_environment_variables = {
  WEZTERM_PANE = ('!'):rep(1000),
  WEZTERM_UNIX_SOCKET = ('/'):rep(1000),
} }, '/bin/fallback-shell')
local malformed_unit
for _, value in ipairs(malformed) do
  if value:match('^%-%-unit=') then malformed_unit = value end
end
eq('missing args use the default shell', malformed[#malformed], '/bin/fallback-shell')
eq('malformed identifiers remain bounded', #malformed_unit <= 200, true)

fake_wezterm.target_triple = 'aarch64-apple-darwin'
eq('non-Linux has no scheduled pane domain', scheduling.pane_domain(), nil)
local mac_args = { 'zsh', '-l' }
local mac_result = scheduling.scope_command(mac_args)
eq('non-Linux command is unchanged', table.concat(mac_result, '|'), 'zsh|-l')
eq('non-Linux result is an independent table', mac_result == mac_args, false)
local mac_config = { default_domain = 'local' }
scheduling.apply(mac_config)
eq('non-Linux default domain is untouched', mac_config.default_domain, 'local')
eq('non-Linux adds no exec domains', mac_config.exec_domains, nil)

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
