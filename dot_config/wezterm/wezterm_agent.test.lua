-- Behavioral tests for wezterm_agent.lua. Run: lua wezterm_agent.test.lua
-- A small WezTerm stub exercises observable state transitions without a GUI.

package.path = (arg[0]:match('(.*/)') or './') .. '?.lua;' .. package.path

local callbacks = {}
local clock_ms = 1000
package.preload.wezterm = function()
  return {
    on = function(name, callback) callbacks[name] = callback end,
    time = {
      now = function()
        return {
          format = function() return string.format('%.3f', clock_ms / 1000) end,
        }
      end,
    },
  }
end

local agent = require('wezterm_agent').setup()

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    io.write(string.format('FAIL %s\n  got:  [%s]\n  want: [%s]\n', name, tostring(got), tostring(want)))
  end
end

local function pane(id, process, user_vars)
  return {
    pane_id = function() return id end,
    get_foreground_process_name = function() return process end,
    get_user_vars = function() return user_vars or {} end,
  }
end

eq('registers status event', type(callbacks['user-var-changed']), 'function')
eq('identity/user-var', agent.of_pane('/usr/bin/zsh', { agent_kind = 'codex' }), 'codex')
eq('identity/process fallback', agent.of_pane('/opt/claude', {}), 'claude')
eq('identity/plain process', agent.of_pane('/usr/bin/zsh', {}), nil)

local p = pane(7, '/usr/bin/claude', { agent_status = 'working' })
eq('status/user-var fallback', agent.status_of(7, p:get_user_vars()), 'working')

callbacks['user-var-changed'](
  { window_id = function() return 11 end },
  p,
  'agent_status',
  'attention'
)
eq('status/event overrides var', agent.status_of(7, p:get_user_vars()), 'attention')

agent.mark_done(p)
eq('status/escape marks done', agent.status_of(7, p:get_user_vars()), 'done')

callbacks['user-var-changed'](
  { window_id = function() return 11 end },
  p,
  'agent_status',
  'working'
)
eq('status/new event resumes work', agent.status_of(7, p:get_user_vars()), 'working')
eq('animation/current window', agent.window_has_working(11, 3000), true)
eq('animation/other window', agent.window_has_working(12, 3000), false)

clock_ms = 5001
eq('animation/stale entry removed', agent.window_has_working(11, 3000), false)

eq('page keys/zsh scroll', agent.page_keys_scroll_terminal(pane(1, '/usr/bin/zsh')), true)
eq('page keys/codex scroll', agent.page_keys_scroll_terminal(pane(2, '/usr/bin/node', { agent_kind = 'codex' })), true)
eq('page keys/other app passes through', agent.page_keys_scroll_terminal(pane(3, '/usr/bin/micro')), false)

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
