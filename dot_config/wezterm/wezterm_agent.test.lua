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

local diagnostics = {}
local agent = require('wezterm_agent').setup {
  log = function(event, fields)
    diagnostics[#diagnostics + 1] = { event = event, fields = fields }
  end,
}

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

local function args_eq(name, got, want)
  eq(name .. '/count', #(got or {}), #want)
  for i, value in ipairs(want) do eq(name .. '/' .. i, got and got[i], value) end
end

eq('registers status event', type(callbacks['user-var-changed']), 'function')
eq('identity/user-var', agent.of_pane('/usr/bin/zsh', { agent_kind = 'codex' }), 'codex')
eq('identity/process fallback', agent.of_pane('/opt/claude', {}), 'claude')
eq('identity/plain process', agent.of_pane('/usr/bin/zsh', {}), nil)
eq(
  'state cache/path namespaces gui and pane',
  agent.state_cache_path('/run/user/1000', 42, 7, 'codex'),
  '/run/user/1000/wezterm-agent-state.gui-sock-42.7.codex'
)
eq('state cache/rejects relative root', agent.state_cache_path('tmp', 42, 7, 'codex'), nil)
eq('state cache/rejects unknown kind', agent.state_cache_path('/tmp', 42, 7, 'other'), nil)

local session_id = '12345678-1234-4abc-9def-1234567890ab'
args_eq('resume/claude exact', agent.resume_args_for(
  pane(30, '/usr/bin/zsh', { agent_kind = 'claude', agent_session_id = session_id })
), { 'claude', '--resume', session_id })
args_eq('resume/codex exact', agent.resume_args_for(
  pane(31, '/usr/bin/zsh', { agent_kind = 'codex', agent_session_id = session_id })
), { 'codex', 'resume', session_id })
eq('resume/diagnostic event', diagnostics[#diagnostics].event, 'agent.resume_args')
eq('resume/diagnostic kind', diagnostics[#diagnostics].fields.kind, 'codex')
eq('resume/diagnostic valid id', diagnostics[#diagnostics].fields.session_id_valid, true)
args_eq('resume/agent without id opens picker', agent.resume_args_for(
  pane(32, '/usr/bin/claude', {})
), { 'claude', '--resume' })
args_eq('resume/malformed id cannot become option', agent.resume_args_for(
  pane(33, '/usr/bin/zsh', { agent_kind = 'codex', agent_session_id = '--dangerously-bypass-approvals-and-sandbox' })
), { 'codex', 'resume' })
eq('resume/unrecognized process', agent.resume_args_for(pane(34, '/usr/bin/helix')), nil)

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

-- mark_done must never query the foreground process: it runs on every bare
-- Escape press. A pane already tracked in pane_status takes the table path;
-- an untracked pane may consult user vars only.
local function proc_forbidden_pane(id, user_vars)
  return {
    pane_id = function() return id end,
    get_foreground_process_name = function()
      error('mark_done must not query the foreground process')
    end,
    get_user_vars = function() return user_vars or {} end,
  }
end

agent.mark_done(proc_forbidden_pane(7))
eq('mark done/tracked pane skips process query', agent.status_of(7, {}), 'done')

agent.mark_done(proc_forbidden_pane(21, { agent_kind = 'codex' }))
eq('mark done/untracked agent pane via vars', agent.status_of(21, {}), 'done')

agent.mark_done(proc_forbidden_pane(22, { claude_status = 'working' }))
eq('mark done/legacy var name recognised', agent.status_of(22, {}), 'done')

agent.mark_done(proc_forbidden_pane(23))
eq('mark done/plain pane untouched', agent.status_of(23, {}), nil)

eq('page keys/zsh scroll', agent.page_keys_scroll_terminal(pane(1, '/usr/bin/zsh')), true)
eq('page keys/codex scroll', agent.page_keys_scroll_terminal(pane(2, '/usr/bin/node', { agent_kind = 'codex' })), true)
eq('page keys/other app passes through', agent.page_keys_scroll_terminal(pane(3, '/usr/bin/micro')), false)

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
