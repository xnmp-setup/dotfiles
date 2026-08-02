-- Behavioral tests for wezterm_clipboard.lua. Run: lua wezterm_clipboard.test.lua

package.path = (arg[0]:match('(.*/)') or './') .. '?.lua;' .. package.path

local actions = {
  PasteFrom = function(source) return { kind = 'paste', source = source } end,
  SendKey = function(key) return { kind = 'send-key', key = key } end,
}

package.preload.wezterm = function()
  return {
    action = actions,
    action_callback = function(callback) return callback end,
    run_child_process = function() return false, '', 'unused' end,
    target_triple = 'x86_64-unknown-linux-gnu',
  }
end

local clipboard = require 'wezterm_clipboard'

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    io.write(string.format('FAIL %s\n  got:  [%s]\n  want: [%s]\n', name, tostring(got), tostring(want)))
  end
end

eq('mime/png', clipboard.has_image_mime('text/plain\nimage/png\n'), true)
eq('mime/jpeg case insensitive', clipboard.has_image_mime('IMAGE/JPEG\r\n'), true)
eq('mime/text only', clipboard.has_image_mime('text/plain;charset=utf-8\nUTF8_STRING\n'), false)
eq('mime/malformed', clipboard.has_image_mime(nil), false)
eq('mime/huge', clipboard.has_image_mime(string.rep('text/plain\n', 100000) .. 'image/webp\n'), true)

local linux = clipboard.clipboard_type_command('x86_64-unknown-linux-gnu')
eq('command/linux executable', linux[1], 'wl-paste')
eq('command/linux argument', linux[2], '--list-types')
eq('command/unsupported', clipboard.clipboard_type_command('unknown'), nil)

local function image_runner()
  return true, 'text/plain\nimage/png\n', ''
end
local function text_runner()
  return true, 'text/plain\n', ''
end
local function failed_runner()
  return false, '', 'clipboard unavailable'
end
local function crashing_runner()
  error('clipboard unavailable')
end

eq('probe/image', clipboard.clipboard_has_image(image_runner, 'linux'), true)
eq('probe/text', clipboard.clipboard_has_image(text_runner, 'linux'), false)
eq('probe/failure', clipboard.clipboard_has_image(failed_runner, 'linux'), false)
eq('probe/exception', clipboard.clipboard_has_image(crashing_runner, 'linux'), false)

local performed = {}
local window = {
  perform_action = function(_, action)
    performed[#performed + 1] = action
  end,
}

clipboard.paste_action {
  run_child_process = image_runner,
  target_triple = 'linux',
}(window, {})
eq('action/image forwards control key', performed[#performed].kind, 'send-key')
eq('action/image forwards ctrl-v', performed[#performed].key.mods, 'CTRL')

clipboard.paste_action {
  run_child_process = text_runner,
  target_triple = 'linux',
}(window, {})
eq('action/text uses terminal paste', performed[#performed].kind, 'paste')
eq('action/text uses clipboard', performed[#performed].source, 'Clipboard')

clipboard.paste_action {
  run_child_process = failed_runner,
  target_triple = 'linux',
}(window, {})
eq('action/probe failure preserves text paste', performed[#performed].kind, 'paste')

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
