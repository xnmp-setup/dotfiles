-- Behavioral tests for wezterm_output.lua. Run: lua wezterm_output.test.lua

package.path = (arg[0]:match('(.*/)') or './') .. '?.lua;' .. package.path

package.preload.wezterm = function()
  return {
    action_callback = function(callback) return callback end,
  }
end

local output = require 'wezterm_output'

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    io.write(string.format('FAIL %s\n  got:  [%s]\n  want: [%s]\n', name, tostring(got), tostring(want)))
  end
end

local function pane(zones, text_by_zone, failure)
  return {
    get_semantic_zones = function()
      if failure == 'zones' then error('zones unavailable') end
      return zones
    end,
    get_text_from_semantic_zone = function(_, zone)
      if failure == 'text' then error('text unavailable') end
      return text_by_zone[zone]
    end,
  }
end

local prompt = { semantic_type = 'Prompt' }
local first = { semantic_type = 'Output' }
local second = { semantic_type = 'Output' }
local value, reason = output.previous_command_output(pane(
  { first, prompt, second },
  { [first] = 'old\n', [second] = 'latest\n' }
))
eq('output/latest semantic output', value, 'latest\n')
eq('output/latest success has no reason', reason, nil)

value, reason = output.previous_command_output(pane({ prompt }, {}))
eq('output/missing value', value, nil)
eq('output/missing reason', reason, 'missing')

value, reason = output.previous_command_output(pane({ second }, { [second] = '\n  \t' }))
eq('output/empty value', value, nil)
eq('output/empty reason', reason, 'empty')

value, reason = output.previous_command_output(pane({}, {}, 'zones'))
eq('output/zone failure value', value, nil)
eq('output/zone failure reason', reason, 'unavailable')

value, reason = output.previous_command_output(pane({ second }, {}, 'text'))
eq('output/text failure value', value, nil)
eq('output/text failure reason', reason, 'unavailable')

local huge = string.rep('x', 2 * 1024 * 1024)
value = output.previous_command_output(pane({ second }, { [second] = huge }))
eq('output/large output is not truncated', #value, #huge)

local copy = output.setup().copy_previous_command
local copied = {}
local toasts = {}
local window = {
  copy_to_clipboard = function(_, text, destination)
    copied[#copied + 1] = { text = text, destination = destination }
  end,
  toast_notification = function(_, _, message)
    toasts[#toasts + 1] = message
  end,
}

copy(window, pane({ second }, { [second] = 'hello\n' }))
eq('action/copies exact output', copied[#copied].text, 'hello\n')
eq('action/uses system clipboard', copied[#copied].destination, 'Clipboard')
eq('action/reports copied size', toasts[#toasts], 'Copied previous command output (6 B).')

copy(window, pane({ second }, { [second] = '' }))
eq('action/empty does not overwrite clipboard', #copied, 1)
eq('action/empty explains result', toasts[#toasts], 'The previous command produced no output.')

copy(window, pane({}, {}))
eq('action/missing explains shell integration', toasts[#toasts], 'No completed command output was found in this pane.')

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
