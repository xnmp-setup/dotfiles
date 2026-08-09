package.path = (arg[0]:match('^(.*)/') or '.') .. '/?.lua;' .. package.path

local global = {}
package.preload.wezterm = function()
  return {
    GLOBAL = global,
    procinfo = { pid = function() return 1234 end },
  }
end

local identity = require 'wezterm_window_identity'
local tag = identity.tag(42)

local function decode(value)
  local decoded = {}
  for _, codepoint in utf8.codes(value) do
    if codepoint ~= 0xE007F then
      decoded[#decoded + 1] = string.char(codepoint - 0xE0000)
    end
  end
  return table.concat(decoded)
end

assert(decode(tag) == 'wid:1234-42')
assert(utf8.codepoint(tag, utf8.offset(tag, -1)) == 0xE007F)
assert(identity.remember(42, '777-3'))
assert(identity.id(42) == '777-3')
assert(decode(identity.tag(42)) == 'wid:777-3')
assert(not identity.remember(42, '../session'))

local original_getenv = os.getenv
os.getenv = function(name)
  if name == 'HYPR_WEZTERM_RESTORE_WINDOW_ID' then return '888-7' end
  return original_getenv(name)
end
package.loaded.wezterm_window_identity = nil
local restored_identity = require 'wezterm_window_identity'
assert(restored_identity.id(51) == '1234-51')
assert(restored_identity.activate_restore('888-7'))
assert(restored_identity.id(51) == '888-7')
assert(restored_identity.id(51) == '888-7')
assert(restored_identity.id(52) == '1234-52')
assert(not restored_identity.activate_restore('999-1'))
os.getenv = original_getenv

print('12 checks, 0 failures')
