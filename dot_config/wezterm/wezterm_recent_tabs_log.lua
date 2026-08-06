-- Narrow diagnostic sink for recently-closed-tab capture and restore.
-- This intentionally records only identifiers, counts and errors; it does not
-- record cwd values, terminal contents or full command lines.
local wezterm = require 'wezterm'

local M = {}

M.path = wezterm.home_dir .. '/.local/share/wezterm/recent-tabs.log'

local function escaped(value)
  local text = tostring(value):gsub('[\r\n\t]', ' ')
  return text
end

function M.emit(event, fields)
  -- Diagnostics must never interfere with closing or restoring a tab.
  pcall(function()
    local keys = {}
    for key in pairs(fields or {}) do keys[#keys + 1] = key end
    table.sort(keys)

    local parts = { os.date('%Y-%m-%dT%H:%M:%S%z'), escaped(event) }
    for _, key in ipairs(keys) do
      parts[#parts + 1] = escaped(key) .. '=' .. escaped(fields[key])
    end

    local file = assert(io.open(M.path, 'a'))
    file:write(table.concat(parts, ' '), '\n')
    file:close()
  end)
end

return M
