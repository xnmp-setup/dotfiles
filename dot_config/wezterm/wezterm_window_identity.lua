-- Invisible, stable OS-window identity shared with the Hyprland status collector.
--
-- Unicode tag characters are default-ignorable: compositors retain them in the
-- title string while renderers do not draw them. This gives Hyprland a true mux
-- window ID without adding visual noise to WezTerm's title bar.

local M = {}

local TAG_OFFSET = 0xE0000
local CANCEL_TAG = utf8.char(0xE007F)

function M.tag(window_id)
  local payload = 'wid:' .. tostring(window_id)
  local encoded = payload:gsub('.', function(character)
    return utf8.char(TAG_OFFSET + string.byte(character))
  end)
  return encoded .. CANCEL_TAG
end

return M
