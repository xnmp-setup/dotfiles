-- Per-pane coding-agent identity, lifecycle state and animation bookkeeping.
local wezterm = require 'wezterm'

local M = {}

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
local function track_animation(pane_id, window_id, status)
  if status == 'working' then
    animated_panes[pane_id] = {
      window_id = window_id,
      last_seen = now_ms(),
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
function M.setup()
  wezterm.on('user-var-changed', function(window, pane, name, value)
    if name == 'agent_status' or name == 'claude_status' then
      local pane_id = pane:pane_id()
      pane_status[pane_id] = value
      track_animation(pane_id, window:window_id(), value)
    end
  end)
  return M
end

local function agent_named_in(s)
  if not s or s == '' then return nil end
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
  local kind = (user_vars or {}).agent_kind
  if kind == 'claude' or kind == 'codex' then return kind end
  return agent_named_in(proc)
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
function M.mark_done(pane)
  local proc = pane:get_foreground_process_name() or ''
  if agent_of_pane(proc, pane:get_user_vars()) then
    pane_status[pane:pane_id()] = 'done'
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
M.page_keys_scroll_terminal = page_keys_scroll_terminal

return M
