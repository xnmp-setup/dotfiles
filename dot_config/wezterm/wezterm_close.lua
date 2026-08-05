-- Process-aware pane and tab closing with a centered confirmation overlay.
--
-- The prompt is WezTerm's built-in Confirmation overlay (centered message +
-- [Y]es/[N]o buttons). Its input handling is hardcoded to y/n/Esc/mouse
-- (wezterm-gui/src/overlay/confirm.rs), so Enter-to-confirm is implemented in
-- the Enter keybinding instead: while a confirmation from this module is
-- pending and the active pane is the overlay, Enter is translated to y (see
-- confirmation_active + wezterm_keybindings.lua).
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

-- Path components that never identify an app when a versioned binary needs a
-- readable name (e.g. ~/.local/share/claude/versions/2.1.222 -> "claude").
local GENERIC_PATH_COMPONENTS = {
  ['bin'] = true,
  ['current'] = true,
  ['dist'] = true,
  ['libexec'] = true,
  ['versions'] = true,
}

local function is_version_like(name)
  return name:match('^v?%d+[%.%d]*$') ~= nil
end

-- Human-readable name for a process path: the basename, unless that is a bare
-- version number, in which case the deepest meaningful path component wins.
function M.display_name(process)
  local name = M.process_basename(process)
  if not name or not is_version_like(name) then return name end
  local better
  for component in tostring(process):gmatch('[^/\\]+') do
    local clean = component:gsub(' %(deleted%)$', '')
    if not is_version_like(clean) and not GENERIC_PATH_COMPONENTS[clean] then
      better = clean
    end
  end
  return better or name
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
  if M.is_stateful_process(name) then return M.display_name(name) end
  for _, child in pairs(info.children or {}) do
    local stateful = M.find_stateful_process(child)
    if stateful then return stateful end
  end
end

local function pane_stateful_process(pane)
  local got_info, info = pcall(function() return pane:get_foreground_process_info() end)
  if got_info and info then return M.find_stateful_process(info) end

  local got_name, name = pcall(function() return pane:get_foreground_process_name() end)
  if got_name and M.is_stateful_process(name) then return M.display_name(name) end
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

-- window_id -> tab_id that is showing our confirmation overlay. Used by the
-- Enter keybinding to decide when Enter should mean y. Entries are cleared by
-- the overlay's action/cancel callbacks, which fire on every resolution
-- (y/n/Esc/mouse).
local pending = {}

-- True iff the overlay from this module is up in front of the active pane:
-- the pending tab must be active AND the pane must be the overlay itself,
-- recognizable by having no foreground process (termwiz overlay panes run
-- nothing). The process check keeps Enter normal when focus moved to a
-- sibling pane while the overlay is still showing elsewhere in the tab.
local function confirmation_active(window, pane)
  local tab = window:active_tab()
  if not tab or pending[window:window_id()] ~= tab:tab_id() then return false end
  local ok, name = pcall(function() return pane:get_foreground_process_name() end)
  return not ok or name == nil or name == ''
end

local function confirm_or_close(window, pane, scope, panes)
  local process = first_stateful_process(panes)
  local action = close_action(scope)
  if not process then
    window:perform_action(action, pane)
    return
  end

  pending[window:window_id()] = window:active_tab():tab_id()
  window:perform_action(act.Confirmation {
    message = confirmation_message(scope, process),
    action = wezterm.action_callback(function(confirm_window, confirm_pane)
      pending[confirm_window:window_id()] = nil
      confirm_window:perform_action(action, confirm_pane)
    end),
    cancel = wezterm.action_callback(function(confirm_window)
      pending[confirm_window:window_id()] = nil
    end),
  }, pane)
end

function M.setup()
  return {
    confirmation_active = confirmation_active,
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
