package.path = (arg[0]:match('^(.*)/') or '.') .. '/?.lua;' .. package.path

local identity = require 'wezterm_window_identity'
local tag = identity.tag(42)
local decoded = {}

for _, codepoint in utf8.codes(tag) do
  if codepoint ~= 0xE007F then
    decoded[#decoded + 1] = string.char(codepoint - 0xE0000)
  end
end

assert(table.concat(decoded) == 'wid:42')
assert(utf8.codepoint(tag, utf8.offset(tag, -1)) == 0xE007F)

print('2 checks, 0 failures')
