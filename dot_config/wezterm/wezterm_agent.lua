-- Per-pane coding-agent identity, lifecycle state and animation bookkeeping.
local wezterm = require 'wezterm'

local M = {}
local diagnostic_log = function() end

-- Per-pane coding-agent status (Claude Code or Codex), keyed by pane-id. This is
-- the SOURCE OF TRUTH the tab bar reads — NOT the raw agent_status user var —
-- because the var gets stuck.
--
-- The agent_status OSC var is set by ~/.local/bin/wezterm-agent-status on hook
-- events (working / attention / done); both agents run the same script, wired up
-- in ~/.claude/settings.json and ~/.codex/hooks.json respectively. But a user
-- INTERRUPT (Esc mid-response) fires no hook in either agent, so the var stays
-- "working" forever and the spinner animates on a tab that's actually idle. We
-- can't fix that from the hook side.
--
-- Instead: the user-var-changed handler mirrors every var write into this table
-- (so normal hook-driven transitions, including working again on the next
-- prompt, flow through unchanged), AND the Esc keybind writes 'done' here
-- directly. That gives interrupt a path the hooks can't provide, while a fresh
-- prompt's 'working' write immediately overrides it back — no stuck state, no
-- background watchdog. Keyed by pane_id; nil → fall back to the var / no status.
local pane_status = {}
local animated_panes = {}

local function now_ms()
  local ok, value = pcall(function()
    return wezterm.time.now():format('%s%.3f')
  end)
  return ok and (tonumber(value) or 0) * 1000 or 0
end

-- Maintain animation state from OSC user-variable events and tab renders. This
-- cache is deliberately GUI-local: update-status must never walk the mux.
local function track_animation(pane_id, window_id, status, observed_at)
  if status == 'working' then
    animated_panes[pane_id] = {
      window_id = window_id,
      last_seen = observed_at or now_ms(),
    }
  else
    animated_panes[pane_id] = nil
  end
end

-- Resolve a pane's effective agent status: the table (source of truth) wins,
-- else the raw user var (covers panes that set the var before this session's
-- user-var-changed handler had seen them, e.g. a config reload mid-session).
-- claude_status is the var's former, Claude-only name — still read so agent
-- sessions started before this config landed keep reporting until they exit.
local function agent_status_of(pane_id, user_vars)
  local vars = user_vars or {}
  return pane_status[pane_id] or vars.agent_status or vars.claude_status
end

-- Mirror every agent_status var write into pane_status. Fires on each OSC
-- SetUserVar receipt, so a fresh 'working' on the next prompt overrides an
-- Esc-set 'done' automatically.
function M.setup(opts)
  diagnostic_log = (opts or {}).log or function() end
  wezterm.on('user-var-changed', function(window, pane, name, value)
    if name == 'agent_status' or name == 'claude_status' then
      local pane_id = pane:pane_id()
      pane_status[pane_id] = value
      track_animation(pane_id, window:window_id(), value)
    end
  end)
  return M
end

local function user_var(user_vars, name)
  local ok, value = pcall(function() return user_vars and user_vars[name] end)
  return ok and value or nil
end

local function agent_named_in(s)
  if not s or s == '' then return nil end
  s = s:lower()
  if s:find('claude') then return 'claude' end
  if s:find('codex') then return 'codex' end
  return nil
end

-- Agent identity is emitted by wezterm-agent-status as a pane user variable.
-- Never inspect argv here: format-tab-title runs on WezTerm's GUI thread, and a
-- synchronous mux/process query in this path can freeze both rendering and the
-- embedded mux. Direct process-name matching remains only as a compatibility
-- fallback for native Claude panes created before agent_kind was introduced.
local function agent_of_pane(proc, user_vars)
  local kind = user_var(user_vars, 'agent_kind')
  if kind == 'claude' or kind == 'codex' then return kind end
  return agent_named_in(proc)
end

local function valid_session_id(value)
  if type(value) ~= 'string' then return nil end
  -- Claude and Codex both expose UUID session/thread ids. Restricting this to a
  -- UUID prevents a forged OSC user variable from being interpreted as a CLI
  -- option; an invalid or missing id simply falls back to the agent's picker.
  if value:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') then
    return value
  end
end

-- Fixed allowlist of programs that have an explicit, non-destructive resume
-- protocol. Everything else restores as a fresh shell; replaying arbitrary argv
-- could silently re-run builds, migrations or destructive commands.
local function resume_args_for(pane)
  local got_vars, user_vars = pcall(function() return pane:get_user_vars() end)
  if not got_vars or user_vars == nil then user_vars = {} end

  local kind = agent_of_pane(nil, user_vars)
  local proc
  if not kind then
    local got_proc
    got_proc, proc = pcall(function() return pane:get_foreground_process_name() end)
    if got_proc then kind = agent_of_pane(proc, user_vars) end
  end

  local raw_session_id = user_var(user_vars, 'agent_session_id')
  local session_id = valid_session_id(raw_session_id)
  diagnostic_log('agent.resume_args', {
    agent_kind_var = user_var(user_vars, 'agent_kind') or 'none',
    kind = kind or 'none',
    process = (proc and proc:match('[^/\\]+$')) or 'not_queried',
    session_id_present = raw_session_id ~= nil and raw_session_id ~= '',
    session_id_valid = session_id ~= nil,
    user_vars_type = type(user_vars),
  })
  if not kind then return nil end

  if kind == 'claude' then
    return session_id and { 'claude', '--resume', session_id } or { 'claude', '--resume' }
  end
  return session_id and { 'codex', 'resume', session_id } or { 'codex', 'resume' }
end

-- Plain page keys scroll terminal history only when zsh itself or Codex owns
-- the pane. Other foreground programs retain their native PageUp/PageDown.
local function page_keys_scroll_terminal(pane)
  local proc = pane:get_foreground_process_name() or ''
  local proc_name = (proc:match('[^/\\]+$') or ''):gsub('%.exe$', ''):lower()
  return proc_name == 'zsh'
    or agent_of_pane(proc, pane:get_user_vars()) == 'codex'
end

-- Clear a stuck working state when Escape interrupts or dismisses an agent UI.
-- This runs on EVERY bare Escape press (the keybind forwards the key after),
-- so it must never query the foreground process — that's a synchronous /proc
-- walk on the GUI thread, paid in vim/helix hundreds of times a minute. The
-- pane_status table (fed by user-var-changed) answers for any pane whose agent
-- has ever fired a hook this session; user vars cover panes from before a
-- config reload (fresh Lua state, empty table, but the var persists in the
-- pane). A pane with neither has no working state to clear, so doing nothing
-- is correct — not just cheap.
function M.mark_done(pane)
  local pane_id = pane:pane_id()
  if pane_status[pane_id] ~= nil then
    pane_status[pane_id] = 'done'
    return
  end
  local vars = pane:get_user_vars() or {}
  if vars.agent_kind or vars.agent_status or vars.claude_status then
    pane_status[pane_id] = 'done'
  end
end

-- Drop stale animation entries and report whether this window still has work.
function M.window_has_working(window_id, stale_after_ms, observed_at)
  local now = observed_at or now_ms()
  local any_working = false
  for pane_id, state in pairs(animated_panes) do
    if now - state.last_seen > stale_after_ms then
      animated_panes[pane_id] = nil
    elseif state.window_id == window_id then
      any_working = true
    end
  end
  return any_working
end

M.now_ms = now_ms
M.track_animation = track_animation
M.status_of = agent_status_of
M.of_pane = agent_of_pane
M.resume_args_for = resume_args_for
M.page_keys_scroll_terminal = page_keys_scroll_terminal

return M
