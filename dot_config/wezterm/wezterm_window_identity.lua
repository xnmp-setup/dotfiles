-- Invisible, stable OS-window identity shared with the Hyprland status collector.
--
-- Unicode tag characters are default-ignorable: compositors retain them in the
-- title string while renderers do not draw them. This gives Hyprland a true mux
-- window ID without adding visual noise to WezTerm's title bar.

local wezterm = require 'wezterm'

local M = {}

local TAG_OFFSET = 0xE0000
local CANCEL_TAG = utf8.char(0xE007F)

local function valid(value)
  if type(value) ~= 'string' then return nil end
  if value:match('^%d+$') or value:match('^%d+%-%d+$') then return value end
end

-- A mux window id is only unique inside one WezTerm process. Prefix new ids
-- with the GUI pid so two independently launched GUI processes cannot overwrite
-- one another's workspace snapshots. Restored windows retain their old identity
-- through wezterm.GLOBAL, so subsequent saves update the same snapshot.
local process_id = wezterm.procinfo and wezterm.procinfo.pid
  and wezterm.procinfo.pid() or 0

local function remembered()
  if not wezterm.GLOBAL then return {} end
  local value = wezterm.GLOBAL.hypr_window_identities
  return type(value) == 'table' and value or {}
end

function M.valid(value)
  return valid(tostring(value or ''))
end

function M.id(window_id)
  local key = tostring(window_id)
  return valid(remembered()[key]) or string.format('%d-%s', process_id, key)
end

function M.remember(window_id, identity)
  identity = valid(tostring(identity or ''))
  if not identity or not wezterm.GLOBAL then return false end
  local identities = remembered()
  identities[tostring(window_id)] = identity
  wezterm.GLOBAL.hypr_window_identities = identities
  return true
end

function M.tag(window_id)
  local payload = 'wid:' .. M.id(window_id)
  local encoded = payload:gsub('.', function(character)
    return utf8.char(TAG_OFFSET + string.byte(character))
  end)
  return encoded .. CANCEL_TAG
end

return M
