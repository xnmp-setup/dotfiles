-- Behavioral tests for wezterm_links.lua. Run: lua wezterm_links.test.lua

package.path = (arg[0]:match('(.*/)') or './') .. '?.lua;' .. package.path

local handlers = {}
local opened = {}
local action = {
  Nop = { kind = 'Nop' },
  OpenLinkAtMouseCursor = { kind = 'OpenLinkAtMouseCursor' },
}

package.preload.wezterm = function()
  return {
    action = action,
    default_hyperlink_rules = function()
      return { { regex = 'https?://\\S+', format = '$0' } }
    end,
    home_dir = '/home/chong',
    on = function(name, callback) handlers[name] = callback end,
    open_with = function(path) opened[#opened + 1] = path end,
  }
end

local links = require 'wezterm_links'

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    io.write(string.format('FAIL %s\n  got:  [%s]\n  want: [%s]\n', name, tostring(got), tostring(want)))
  end
end

eq('resolve/unix absolute', links.resolve_image_path('/tmp/a.png', '/work/app', '/home/me'), '/tmp/a.png')
eq('resolve/windows absolute', links.resolve_image_path('C:\\tmp\\a.png', 'C:\\work', 'C:\\Users\\me'), 'C:\\tmp\\a.png')
eq('resolve/UNC absolute', links.resolve_image_path('\\\\server\\share\\a.png', 'C:\\work', 'C:\\Users\\me'), '\\\\server\\share\\a.png')
eq('resolve/home', links.resolve_image_path('~/shots/a.webp', '/work/app', '/home/me'), '/home/me/shots/a.webp')
eq('resolve/relative', links.resolve_image_path('shots/a.png', '/work/app/', '/home/me'), '/work/app/shots/a.png')
eq('resolve/relative without cwd', links.resolve_image_path('shots/a.png', nil, '/home/me'), nil)
eq('resolve/malformed', links.resolve_image_path(nil, '/work/app', '/home/me'), nil)

local config = { mouse_bindings = { { mods = 'NONE' } } }
links.setup(config)

eq('rules/default retained', config.hyperlink_rules[1].format, '$0')
eq('rules/image appended', config.hyperlink_rules[2].format, 'wezterm-image:$1')
eq('mouse/existing binding retained', config.mouse_bindings[1].mods, 'NONE')
eq('mouse/eight bindings added', #config.mouse_bindings, 9)

local click_bindings = {}
for _, binding in ipairs(config.mouse_bindings) do
  if binding.mods ~= 'NONE' then
    local event = binding.event.Up and 'Up' or 'Down'
    click_bindings[binding.mods .. '/' .. event .. '/' .. tostring(binding.mouse_reporting)] = binding.action.kind
  end
end
for _, mods in ipairs { 'CTRL', 'ALT' } do
  for _, reporting in ipairs { false, true } do
    local suffix = '/' .. tostring(reporting)
    eq('mouse/' .. mods .. '/down' .. suffix, click_bindings[mods .. '/Down' .. suffix], 'Nop')
    eq('mouse/' .. mods .. '/up' .. suffix, click_bindings[mods .. '/Up' .. suffix], 'OpenLinkAtMouseCursor')
  end
end

-- The image rule is executed by WezTerm's Rust regex engine, not by Lua
-- patterns, so it is exercised against a real PCRE2 engine (`rg -P`) when the
-- machine has one and skipped otherwise. PCRE2 and fancy-regex agree on every
-- construct the rule uses. These cases pin the accepted language and document
-- that dot-dense non-matching lines stay non-matching.
local image_regex = config.hyperlink_rules[2].regex

local function shell_quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function capture(command)
  local handle = io.popen(command)
  if not handle then return nil end
  local output = handle:read('*a')
  handle:close()
  return output
end

local function first_match(line)
  local output = capture(string.format(
    'printf %%s %s | rg -oP %s 2>/dev/null',
    shell_quote(line),
    shell_quote(image_regex)
  ))
  return output and output:match('^[^\n]+') or nil
end

if capture("printf 'x.png' | rg -oP 'x\\.png' 2>/dev/null") == 'x.png\n' then
  eq('rule/unix path', first_match('open /tmp/image.png now'), '/tmp/image.png')
  eq('rule/relative path', first_match('see ./image.webp here'), './image.webp')
  eq('rule/home path', first_match('~/shots/a.jpg'), '~/shots/a.jpg')
  eq('rule/windows path', first_match('C:\\Users\\me\\pic.jpeg'), 'C:\\Users\\me\\pic.jpeg')
  eq('rule/trailing sentence period excluded', first_match('Look at image.png.'), 'image.png')
  eq('rule/near-miss extension rejected', first_match('a.pngx'), nil)
  eq(
    'rule/dotted tokens do not match',
    first_match('a.b.c.d.e.f.g.h.i.j.k.l.m.n.o.p...q.r.s.t.u.v.w.x.y.z'),
    nil
  )
  eq(
    'rule/minified json does not match',
    first_match('{"a":1,"b":{"c":2},"d":[3,4],"e":"f.g.h","i":"j.k.l"}'),
    nil
  )
  eq(
    'rule/stack trace frame does not match',
    first_match('File "/app/src/main.py", line 12, in <module>'),
    nil
  )
  -- The segment group must stay lazy: greedy fuses two paths joined by
  -- non-whitespace into one match spanning both. The leading `[` / `IMAGES=`
  -- in the expectations is a quirk shared with the original rule (the class
  -- admits those characters); what these cases pin is that the match stops at
  -- the FIRST extension instead of running on to the second path.
  eq('rule/markdown link stops at first path', first_match('[assets/a.png](docs/b.png)'), '[assets/a.png')
  eq('rule/comma-joined paths stop at first', first_match('IMAGES=logo.png,icon.svg'), 'IMAGES=logo.png')
  eq('rule/query string stops at extension', first_match('test.png?v=1&fallback=old.png'), 'test.png')
else
  io.write('skip: rg with PCRE2 support not available; image rule cases not run\n')
end

local toasts = {}
local window = {
  toast_notification = function(_, _, message) toasts[#toasts + 1] = message end,
}
local pane = {
  get_current_working_dir = function() return { file_path = '/work/app' } end,
}

eq('open-uri/regular URL not handled', handlers['open-uri'](window, pane, 'https://example.com'), nil)
eq('open-uri/image suppresses browser', handlers['open-uri'](window, pane, 'wezterm-image:shots/a.png'), false)
eq('open-uri/image opens resolved path', opened[#opened], '/work/app/shots/a.png')

local unknown_cwd_pane = { get_current_working_dir = function() return nil end }
eq('open-uri/unresolved suppresses browser', handlers['open-uri'](window, unknown_cwd_pane, 'wezterm-image:a.png'), false)
eq('open-uri/unresolved explains failure', toasts[#toasts], 'Could not resolve that image path from this pane.')

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
