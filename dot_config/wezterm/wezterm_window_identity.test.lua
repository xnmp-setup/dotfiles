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

print('6 checks, 0 failures')
