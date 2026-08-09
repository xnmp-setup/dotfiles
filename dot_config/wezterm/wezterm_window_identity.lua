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

-- A Hyprland workspace restore always starts a fresh GUI process and rebuilds
-- exactly one OS window. Keep the requested identity in this config evaluation
-- itself: wezterm.GLOBAL is not guaranteed to bridge the mux-side gui-startup
-- evaluation and the GUI-side format-window-title evaluation.
local restore_identity = valid(os.getenv('HYPR_WEZTERM_RESTORE_WINDOW_ID'))
local restore_window_id
local restore_succeeded = false

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
  if restore_succeeded and restore_identity
    and (not restore_window_id or restore_window_id == key)
  then
    restore_window_id = key
    return restore_identity
  end
  return valid(remembered()[key]) or string.format('%d-%s', process_id, key)
end

-- The launcher environment is only an intention. A missing/corrupt per-window
-- file falls back to a plain WezTerm window; tagging that fallback with the saved
-- identity would make Hyprland treat the one-tab fallback as a successful restore
-- and overwrite the richer source snapshot. Sessionstore activates the identity
-- only after every saved tab has been rebuilt.
function M.activate_restore(identity)
  identity = valid(tostring(identity or ''))
  if not identity or identity ~= restore_identity then return false end
  restore_succeeded = true
  return true
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
