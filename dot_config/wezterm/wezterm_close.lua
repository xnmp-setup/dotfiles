-- Process-aware pane and tab closing with a compact confirmation overlay.
local wezterm = require 'wezterm'
local act = wezterm.action

local M = {}

local STATELESS_PROCESSES = {
  ['bash'] = true,
  ['cmd.exe'] = true,
  ['fish'] = true,
  ['login'] = true,
  ['nu'] = true,
  ['powershell.exe'] = true,
  ['pwsh.exe'] = true,
  ['sh'] = true,
  ['tmux'] = true,
  ['zsh'] = true,
}

function M.process_basename(process)
  if not process or process == '' then return nil end
  return (process:match('[^/\\]+$') or process):gsub(' %(deleted%)$', '')
end

function M.is_stateful_process(process)
  local name = M.process_basename(process)
  if not name or STATELESS_PROCESSES[name] then return false end
  -- Powerlevel10k keeps this shell helper alive at an otherwise idle prompt.
  if name:match('^gitstatusd%-') then return false end
  return true
end

local function process_name(info)
  if not info then return nil end
  if info.executable and info.executable ~= '' then return info.executable end
  return info.name
end

function M.find_stateful_process(info)
  if not info then return nil end
  local name = process_name(info)
  if M.is_stateful_process(name) then return M.process_basename(name) end
  for _, child in pairs(info.children or {}) do
    local stateful = M.find_stateful_process(child)
    if stateful then return stateful end
  end
end

local function pane_stateful_process(pane)
  local got_info, info = pcall(function() return pane:get_foreground_process_info() end)
  if got_info and info then return M.find_stateful_process(info) end

  local got_name, name = pcall(function() return pane:get_foreground_process_name() end)
  if got_name and M.is_stateful_process(name) then return M.process_basename(name) end
end

local function first_stateful_process(panes)
  for _, pane in ipairs(panes) do
    local process = pane_stateful_process(pane)
    if process then return process end
  end
end

local function confirmation_message(scope, process)
  local noun = scope == 'tab' and 'tab' or 'pane'
  local consequence = scope == 'tab'
      and 'All panes in this tab will be terminated.'
    or 'This process will be terminated.'

  return wezterm.format {
    { Foreground = { Color = '#e87898' } },
    { Attribute = { Intensity = 'Bold' } },
    { Text = '  ⚠  Close this ' .. noun .. '?  ' },
    'ResetAttributes',
    { Text = '\n\n' },
    { Foreground = { Color = '#9aa4c8' } },
    { Text = 'Running process  ' },
    { Foreground = { Color = '#fbbf24' } },
    { Attribute = { Intensity = 'Bold' } },
    { Text = process },
    'ResetAttributes',
    { Text = '\n' },
    { Foreground = { Color = '#9aa4c8' } },
    { Text = consequence },
    'ResetAttributes',
  }
end

local function close_action(scope)
  if scope == 'tab' then return act.CloseCurrentTab { confirm = false } end
  return act.CloseCurrentPane { confirm = false }
end

local function confirm_or_close(window, pane, scope, panes)
  local process = first_stateful_process(panes)
  local action = close_action(scope)
  if not process then
    window:perform_action(action, pane)
    return
  end

  window:perform_action(act.Confirmation {
    message = confirmation_message(scope, process),
    action = wezterm.action_callback(function(confirm_window, confirm_pane)
      confirm_window:perform_action(action, confirm_pane)
    end),
  }, pane)
end

function M.setup()
  return {
    close_pane = function()
      return wezterm.action_callback(function(window, pane)
        confirm_or_close(window, pane, 'pane', { pane })
      end)
    end,
    close_tab = function()
      return wezterm.action_callback(function(window, pane)
        confirm_or_close(window, pane, 'tab', window:active_tab():panes())
      end)
    end,
  }
end

return M
