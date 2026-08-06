-- Linux CPU scheduling boundaries for the GUI and its pane processes.
--
-- Hyprland launches the GUI in a high-weight systemd scope. A local pane would
-- normally inherit that scope, allowing a CPU-heavy build to compete with the
-- renderer at the same priority. The ExecDomain below instead starts every
-- pane in its own low-weight sibling scope. CPUWeight alone is work-conserving
-- and cannot eliminate scheduler latency when every logical CPU is saturated,
-- so pane scopes also exclude two complete physical cores. The unrestricted GUI
-- and compositor can use that reserved capacity immediately.
local wezterm = require 'wezterm'

local M = {
  PANE_CPU_WEIGHT = 10,
  PANE_DOMAIN = 'cpu-limited',
  PANE_RESERVED_PHYSICAL_CORES = 2,
}

local SYSTEMD_RUN = 'systemd-run'
local UNIT_FRAGMENT_LIMIT = 80
local MAX_CPU_INDEX = 8191
local MAX_CPU_COUNT = 8192

local function is_linux()
  return (wezterm.target_triple or ''):find('linux', 1, true) ~= nil
end

function M.pane_domain()
  return is_linux() and M.PANE_DOMAIN or nil
end

local function copy_array(values)
  local result = {}
  for index, value in ipairs(values or {}) do result[index] = value end
  return result
end

local function parse_cpu_list(value)
  if type(value) ~= 'string' or value:match('^%s*$') then return nil end

  local cpus, seen = {}, {}
  for token in value:gmatch('[^,%s]+') do
    local first, last = token:match('^(%d+)%-(%d+)$')
    if first then
      first, last = tonumber(first), tonumber(last)
    else
      first = tonumber(token:match('^(%d+)$'))
      last = first
    end
    if not first or first > last or last > MAX_CPU_INDEX then return nil end
    for cpu = first, last do
      if not seen[cpu] then
        if #cpus >= MAX_CPU_COUNT then return nil end
        seen[cpu] = true
        cpus[#cpus + 1] = cpu
      end
    end
  end
  if #cpus == 0 then return nil end
  table.sort(cpus)
  return cpus
end

local function format_cpu_list(cpus)
  if not cpus or #cpus == 0 then return nil end

  local ranges = {}
  local first, last = cpus[1], cpus[1]
  for index = 2, #cpus + 1 do
    local cpu = cpus[index]
    if cpu == last + 1 then
      last = cpu
    else
      ranges[#ranges + 1] = first == last and tostring(first)
        or string.format('%d-%d', first, last)
      first, last = cpu, cpu
    end
  end
  return table.concat(ranges, ',')
end

local function read_line(path)
  local file = io.open(path, 'r')
  if not file then return nil end
  local value = file:read('*l')
  file:close()
  return value
end

-- Derive the workload CPU set from kernel topology rather than assuming a CPU
-- count or SMT layout. Reserving whole sibling groups prevents a busy pane from
-- occupying the other hardware thread of a core intended for the UI.
function M.workload_cpu_set(reader, requested_reservations)
  reader = reader or read_line
  local online = parse_cpu_list(reader('/sys/devices/system/cpu/online'))
  if not online then return nil end

  local online_set = {}
  for _, cpu in ipairs(online) do online_set[cpu] = true end

  local groups, claimed = {}, {}
  for _, cpu in ipairs(online) do
    if not claimed[cpu] then
      local siblings = parse_cpu_list(reader(string.format(
        '/sys/devices/system/cpu/cpu%d/topology/thread_siblings_list', cpu)))
      local group, includes_cpu = {}, false
      for _, sibling in ipairs(siblings or {}) do
        if online_set[sibling] and not claimed[sibling] then
          group[#group + 1] = sibling
          includes_cpu = includes_cpu or sibling == cpu
        end
      end
      if not includes_cpu then group[#group + 1] = cpu end
      table.sort(group)
      for _, sibling in ipairs(group) do claimed[sibling] = true end
      groups[#groups + 1] = group
    end
  end

  -- Always leave at least one physical core for workloads on small machines.
  local reservations = math.min(
    requested_reservations or M.PANE_RESERVED_PHYSICAL_CORES,
    math.max(0, #groups - 1))
  if reservations == 0 then return nil end

  local reserved = {}
  for index = 1, reservations do
    for _, cpu in ipairs(groups[index]) do reserved[cpu] = true end
  end
  local allowed = {}
  for _, cpu in ipairs(online) do
    if not reserved[cpu] then allowed[#allowed + 1] = cpu end
  end
  return format_cpu_list(allowed)
end

local cached_pane_cpus
local pane_cpus_computed = false

function M.pane_allowed_cpus()
  if not is_linux() then return nil end
  if not pane_cpus_computed then
    cached_pane_cpus = M.workload_cpu_set()
    pane_cpus_computed = true
  end
  return cached_pane_cpus
end

local function basename(value)
  local text = tostring(value or '')
  return text:match('[^/\\]+$') or text
end

-- systemd unit names accept more characters when escaped, but a deliberately
-- small alphabet makes the generated identity safe without another process.
local function unit_fragment(value, fallback)
  local result = tostring(value or ''):gsub('[^%w_.-]', '_')
  if result == '' then result = fallback end
  return result:sub(1, UNIT_FRAGMENT_LIMIT)
end

-- Pure command adapter shared with the persistent background mux servers.
-- Non-Linux hosts receive an independent copy of the original argv.
function M.scope_command(args, options)
  local command = copy_array(args)
  if not is_linux() then return command end

  options = options or {}
  local allowed_cpus = options.allowed_cpus
  if allowed_cpus == nil then allowed_cpus = M.pane_allowed_cpus() end
  local wrapped = {
    SYSTEMD_RUN,
    '--user',
    '--scope',
    '--quiet',
    '--collect',
    '--property=CPUWeight=' .. tostring(options.cpu_weight or M.PANE_CPU_WEIGHT),
  }
  if allowed_cpus then
    wrapped[#wrapped + 1] = '--property=AllowedCPUs=' .. allowed_cpus
  end
  if options.same_dir ~= false then wrapped[#wrapped + 1] = '--same-dir' end
  if options.description then
    wrapped[#wrapped + 1] = '--description=' .. options.description
  end
  if options.unit then wrapped[#wrapped + 1] = '--unit=' .. options.unit end
  wrapped[#wrapped + 1] = '--'
  for _, value in ipairs(command) do wrapped[#wrapped + 1] = value end
  return wrapped
end

function M.pane_scope_command(cmd, default_shell)
  cmd = cmd or {}
  local env = cmd.set_environment_variables or {}
  local pane = unit_fragment(env.WEZTERM_PANE, 'unknown')
  local socket = unit_fragment(basename(env.WEZTERM_UNIX_SOCKET), 'local')
  local args = cmd.args or { default_shell or os.getenv('SHELL') or '/bin/sh' }

  return M.scope_command(args, {
    cpu_weight = M.PANE_CPU_WEIGHT,
    description = 'Process started by WezTerm pane ' .. pane,
    unit = 'wezterm-pane-' .. pane .. '-on-' .. socket,
  })
end

function M.apply(config)
  if not M.pane_domain() then return config end

  local domains = copy_array(config.exec_domains)
  domains[#domains + 1] = wezterm.exec_domain(M.PANE_DOMAIN, function(cmd)
    -- Return a new SpawnCommand table so the caller-owned value remains intact.
    local revised = {}
    for key, value in pairs(cmd or {}) do revised[key] = value end
    revised.args = M.pane_scope_command(cmd)
    return revised
  end)
  config.exec_domains = domains
  config.default_domain = M.PANE_DOMAIN
  return config
end

return M
