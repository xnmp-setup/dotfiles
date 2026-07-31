-- Project-scoped utility panes and launchers behind the alt+m chord.
local wezterm = require 'wezterm'
local act = wezterm.action

local M = {}

local DEV_TAB_PREFIX = 'dev · '
local URL_POLL_INTERVAL_SECONDS = 0.1
local URL_POLL_ATTEMPTS = 200
local BOTTOM_PANE_SIZE = 0.40
local TERMINAL_PANE_SIZE = 0.35
local UTILITY_PANE_STATE_KEY = 'utility_pane_ids'
local TERMINAL_OWNER_STATE_KEY = 'utility_terminal_owner_ids'
local TOOL_SHELF = 'tool_shelf'

local UTILITY_PANES = {
  yazi = {
    id = 'yazi',
    command = 'yazi',
    pass_cwd_as_entry = true,
    set_environment_variables = { YAZI_UTILITY_PANE = '1' },
    shelf = TOOL_SHELF,
    top_level = true,
    size = BOTTOM_PANE_SIZE,
  },
  keifu = {
    id = 'keifu',
    command = 'keifu',
    shelf = TOOL_SHELF,
    top_level = true,
    size = BOTTOM_PANE_SIZE,
  },
}

local function pane_id(pane)
  local ok, id = pcall(function() return pane:pane_id() end)
  return ok and id or nil
end

function M.process_basename(process)
  if not process or process == '' then return nil end
  local name = (process:match('[^/\\]+$') or process):gsub(' %(deleted%)$', '')
  return name
end

local function pane_running(pane, command)
  local ok, process = pcall(function() return pane:get_foreground_process_name() end)
  return ok and M.process_basename(process) == command
end

local function find_pane(panes, command, remembered_id)
  for _, candidate in ipairs(panes) do
    if (remembered_id and pane_id(candidate) == remembered_id)
        or (command and pane_running(candidate, command)) then
      return candidate
    end
  end
end

local function find_shelf_anchor(panes, remembered_panes, spec)
  if not spec.shelf then return nil end

  for id, candidate_spec in pairs(UTILITY_PANES) do
    if id ~= spec.id and candidate_spec.shelf == spec.shelf then
      local candidate = find_pane(panes, candidate_spec.command, remembered_panes[id])
      if candidate then return candidate end
    end
  end
end

local function find_other_pane(panes, excluded)
  for _, candidate in ipairs(panes) do
    if candidate ~= excluded then return candidate end
  end
end

local function terminal_is_hidden(tab, terminal_id)
  for _, info in ipairs(tab:panes_with_info()) do
    if info.is_zoomed then return info.pane_id ~= terminal_id end
  end
  return false
end

local function cwd_path(pane)
  local ok, cwd = pcall(function() return pane:get_current_working_dir() end)
  if not ok or cwd == nil then return nil end
  if type(cwd) == 'string' then
    return cwd:match('^file://[^/]*(/.*)$') or cwd
  end

  local got_path, file_path = pcall(function() return cwd.file_path end)
  if got_path and file_path and file_path ~= '' then return file_path end

  local value = tostring(cwd)
  return value:match('^file://[^/]*(/.*)$') or value
end

local function trim_url(url)
  local trimmed = url:gsub("[%)%]%}>,;%.\"']+$", '')
  return trimmed
end

local function browser_url(url)
  return url
    :gsub('^(https?://)0%.0%.0%.0', '%1127.0.0.1', 1)
    :gsub('^(https?://)%[::%]', '%1[::1]', 1)
end

local function is_local_url(url)
  local host = url:match('^https?://%[([^%]]+)%]')
    or url:match('^https?://([^/:]+)')
  if not host then return false end
  local second_octet = tonumber(host:match('^172%.(%d+)%.'))
  return host == 'localhost'
    or host == '0.0.0.0'
    or host == '127.0.0.1'
    or host == '::'
    or host == '::1'
    or host:match('^10%.') ~= nil
    or host:match('^192%.168%.') ~= nil
    or (second_octet ~= nil and second_octet >= 16 and second_octet <= 31)
end

-- Extract the URL a dev server announces, ignoring unrelated links emitted by
-- package managers. Loopback/private addresses win; otherwise the line must
-- describe a server becoming available.
function M.extract_server_url(text)
  local contextual
  for line in (text or ''):gmatch('[^\r\n]+') do
    local lower = line:lower()
    for raw in line:gmatch('https?://[^%s]+') do
      local url = trim_url(raw)
      if is_local_url(url) then return browser_url(url) end
      local announces_server = lower:match('local%s*:')
        or lower:match('network%s*:')
        or lower:match('listen')
        or lower:match('ready%s+at')
        or lower:match('started%s+at')
        or lower:match('available%s+at')
        or lower:match('url%s*:')
      if not contextual and announces_server then
        contextual = url
      end
    end
  end
  return contextual
end

function M.dev_tab_title(cwd)
  local normalized = cwd:gsub('[\\/]+$', '')
  return DEV_TAB_PREFIX .. (normalized:match('[^/\\]+$') or normalized)
end

local function find_dev_tab(mux_window, cwd)
  local title = M.dev_tab_title(cwd)
  for _, tab in ipairs(mux_window:tabs()) do
    local pane = tab:active_pane()
    if tab:get_title() == title and cwd_path(pane) == cwd then
      return tab, pane
    end
  end
end

local function poll_for_server_url(window, server_pane, attempt, on_finished)
  local ok, output = pcall(function()
    return server_pane:get_logical_lines_as_text(200)
  end)
  if not ok then
    on_finished(nil)
    window:toast_notification(
      'WezTerm',
      'Dev server exited before publishing a URL.',
      nil,
      4000
    )
    return
  end

  local url = M.extract_server_url(output)
  if url then
    on_finished(url)
    wezterm.open_with(url)
    window:toast_notification('WezTerm', 'Opened ' .. url, nil, 2500)
    return
  end

  if attempt >= URL_POLL_ATTEMPTS then
    on_finished(nil)
    window:toast_notification(
      'WezTerm',
      'Dev server is still running, but did not publish a URL.',
      nil,
      4000
    )
    return
  end

  wezterm.time.call_after(URL_POLL_INTERVAL_SECONDS, function()
    poll_for_server_url(window, server_pane, attempt + 1, on_finished)
  end)
end

function M.setup(config)
  -- Pane ids are persisted for the GUI process lifetime so the shell-only
  -- terminal toggle survives config reloads. TUI process-name discovery is an
  -- additional fallback for Yazi/Keifu.
  local utility_panes = wezterm.GLOBAL[UTILITY_PANE_STATE_KEY]
  if type(utility_panes) ~= 'table' then utility_panes = {} end
  local terminal_owners = wezterm.GLOBAL[TERMINAL_OWNER_STATE_KEY]
  if type(terminal_owners) ~= 'table' then terminal_owners = {} end
  local dev_urls = {}
  local polling_panes = {}

  local function persist_utility_panes()
    wezterm.GLOBAL[UTILITY_PANE_STATE_KEY] = utility_panes
    wezterm.GLOBAL[TERMINAL_OWNER_STATE_KEY] = terminal_owners
  end

  local function toggle_bottom_pane(spec)
    return wezterm.action_callback(function(window, active_pane)
      local tab = window:active_tab()
      local tab_id = tostring(tab:tab_id())
      utility_panes[tab_id] = utility_panes[tab_id] or {}

      local panes = tab:panes()
      local existing = find_pane(panes, spec.command, utility_panes[tab_id][spec.id])
      if existing then
        if #panes == 1 then
          window:toast_notification(
            'WezTerm',
            spec.id .. ' is the last pane; refusing to close the tab.',
            nil,
            3500
          )
          return
        end
        -- CloseCurrentPane acts on the focused GUI pane. `existing` came from
        -- MuxTab:panes(), so passing it as perform_action context does not retarget
        -- the action; focus the tracked utility pane explicitly first.
        existing:activate()
        window:perform_action(act.CloseCurrentPane { confirm = false }, existing)
        utility_panes[tab_id][spec.id] = nil
        persist_utility_panes()
        return
      end

      -- Yazi and Keifu share one top-level bottom shelf. Once the shelf exists,
      -- split it sideways instead of adding another top-level vertical split.
      -- That keeps the main pane at one stable height while tools are added or
      -- removed, and leaves only one resize notification when the shelf closes.
      local split_target = active_pane
      local shelf_anchor = find_shelf_anchor(panes, utility_panes[tab_id], spec)
      local split = { direction = 'Bottom' }
      if shelf_anchor then
        split_target = shelf_anchor
        split.direction = 'Right'
        split.size = 0.5
      end
      local invoking_cwd = cwd_path(active_pane)
      if spec.command then
        split.args = { spec.command }
        -- WezTerm nightly currently ignores `Pane:split`'s explicit cwd for
        -- this local mux pane. Yazi accepts an initial entry, so give it the
        -- same resolved path rather than depending on the process cwd alone.
        if spec.pass_cwd_as_entry and invoking_cwd then
          split.args[#split.args + 1] = invoking_cwd
        end
      end
      if spec.set_environment_variables then
        split.set_environment_variables = spec.set_environment_variables
      end
      -- Supplying args bypasses reliable implicit cwd inheritance in some
      -- domains. Resolve the pane that invoked the chord and pass its directory
      -- explicitly, even when an existing shelf pane is the split target.
      split.cwd = invoking_cwd
      if not shelf_anchor then
        if spec.top_level ~= nil then split.top_level = spec.top_level end
        if spec.size ~= nil then split.size = spec.size end
      end

      local new_pane = split_target:split(split)
      utility_panes[tab_id][spec.id] = pane_id(new_pane)
      persist_utility_panes()
      new_pane:activate()
    end)
  end

  local function toggle_persistent_terminal()
    return wezterm.action_callback(function(window, active_pane)
      local tab = window:active_tab()
      local tab_id = tostring(tab:tab_id())
      utility_panes[tab_id] = utility_panes[tab_id] or {}

      local panes = tab:panes()
      local remembered_id = utility_panes[tab_id].terminal
      local existing = find_pane(panes, nil, remembered_id)
      if existing then
        if terminal_is_hidden(tab, pane_id(existing)) then
          tab:set_zoomed(false)
          existing:activate()
          return
        end

        local owner = find_pane(panes, nil, terminal_owners[tab_id])
          or find_other_pane(panes, existing)
        if not owner then
          window:toast_notification(
            'WezTerm',
            'The persistent terminal is the last pane; close the tab to stop it.',
            nil,
            3500
          )
          return
        end

        owner:activate()
        tab:set_zoomed(true)
        terminal_owners[tab_id] = pane_id(owner)
        persist_utility_panes()
        return
      end

      -- The terminal stays in this tab for its whole lifetime. Hiding it zooms
      -- its owner rather than closing the PTY, so foreground jobs keep running;
      -- closing the tab still terminates both panes together.
      tab:set_zoomed(false)
      local new_pane = active_pane:split { direction = 'Bottom', size = TERMINAL_PANE_SIZE }
      utility_panes[tab_id].terminal = pane_id(new_pane)
      terminal_owners[tab_id] = pane_id(active_pane)
      persist_utility_panes()
      new_pane:activate()
    end)
  end

  local function start_dev_server()
    return wezterm.action_callback(function(window, active_pane)
      local cwd = cwd_path(active_pane)
      if not cwd or cwd == '' then
        window:toast_notification('WezTerm', 'Could not determine the project directory.', nil, 3500)
        return
      end

      local mux_window = window:mux_window()
      local title = M.dev_tab_title(cwd)
      local _, server_pane = find_dev_tab(mux_window, cwd)

      if not server_pane then
        dev_urls[cwd] = nil
        local original_tab = window:active_tab()
        local server_tab
        server_tab, server_pane = mux_window:spawn_tab {
          args = { 'bun', 'run', 'dev' },
          cwd = cwd,
          domain = 'CurrentPaneDomain',
        }
        server_tab:set_title(title)
        original_tab:activate()
      end

      if dev_urls[cwd] then
        wezterm.open_with(dev_urls[cwd])
        window:toast_notification('WezTerm', 'Opened ' .. dev_urls[cwd], nil, 2500)
        return
      end

      if polling_panes[server_pane] then
        window:toast_notification('WezTerm', 'Waiting for the dev server URL…', nil, 2500)
        return
      end

      polling_panes[server_pane] = true
      poll_for_server_url(window, server_pane, 0, function(url)
        polling_panes[server_pane] = nil
        if url then dev_urls[cwd] = url end
      end)
    end)
  end

  config.key_tables = config.key_tables or {}
  config.key_tables.utility_chord = {
    { key = 'e', mods = 'NONE', action = toggle_bottom_pane(UTILITY_PANES.yazi) },
    { key = 'g', mods = 'NONE', action = toggle_bottom_pane(UTILITY_PANES.keifu) },
    { key = 't', mods = 'NONE', action = toggle_persistent_terminal() },
    { key = 'd', mods = 'NONE', action = start_dev_server() },
    { key = 'Escape', mods = 'NONE', action = act.PopKeyTable },
  }

  return {
    activate_chord = act.ActivateKeyTable {
      name = 'utility_chord',
      one_shot = true,
      timeout_milliseconds = 2000,
      until_unknown = true,
      prevent_fallback = true,
    },
  }
end

return M
