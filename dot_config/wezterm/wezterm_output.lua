-- Copy shell-integrated command output without selecting scrollback text.
local wezterm = require 'wezterm'

local M = {}

local function output_zone(zones)
  if type(zones) ~= 'table' then return nil end
  for index = #zones, 1, -1 do
    local zone = zones[index]
    if type(zone) == 'table' and zone.semantic_type == 'Output' then
      return zone
    end
  end
end

local function human_size(bytes)
  if bytes < 1024 then return string.format('%d B', bytes) end
  if bytes < 1024 * 1024 then return string.format('%.1f KiB', bytes / 1024) end
  return string.format('%.1f MiB', bytes / (1024 * 1024))
end

function M.previous_command_output(pane)
  local zones_ok, zones = pcall(function() return pane:get_semantic_zones() end)
  if not zones_ok then return nil, 'unavailable' end

  local zone = output_zone(zones)
  if not zone then return nil, 'missing' end

  local text_ok, value = pcall(function()
    return pane:get_text_from_semantic_zone(zone)
  end)
  if not text_ok or type(value) ~= 'string' then return nil, 'unavailable' end
  if value:match('^%s*$') then return nil, 'empty' end
  return value
end

function M.setup()
  return {
    copy_previous_command = wezterm.action_callback(function(window, pane)
      local value, reason = M.previous_command_output(pane)
      if not value then
        local message = reason == 'empty'
            and 'The previous command produced no output.'
          or reason == 'missing'
            and 'No completed command output was found in this pane.'
          or 'Command output is unavailable for this pane.'
        window:toast_notification('WezTerm', message, nil, 3500)
        return
      end

      window:copy_to_clipboard(value, 'Clipboard')
      window:toast_notification(
        'WezTerm',
        'Copied previous command output (' .. human_size(#value) .. ').',
        nil,
        2200
      )
    end),
  }
end

return M
