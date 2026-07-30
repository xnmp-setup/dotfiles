-- WezTerm config — Windows port of the Ghostty config (dot_config/ghostty/config).
-- See the NOTES block at the bottom for things that don't translate 1:1.

local wezterm = require 'wezterm'
local act = wezterm.action
local config = wezterm.config_builder()

-- Pure, unit-tested tab-title truncation lives in tabtitle.lua (beside this
-- file, which wezterm puts on package.path). See tabtitle.test.lua for tests.
local compute_tab_title = require('tabtitle').compute_tab_title

-- Navigate panes within the current tab in book order (top-to-bottom, then
-- left-to-right). Only cross to the next/prev tab when already at the
-- last/first pane in that order.
local function pane_or_tab_nav(delta)
  return wezterm.action_callback(function(window, pane)
    local infos = window:active_tab():panes_with_info()
    table.sort(infos, function(a, b)
      if a.top ~= b.top then
        return a.top < b.top
      end
      return a.left < b.left
    end)
    local cur
    for i, info in ipairs(infos) do
      if info.is_active then
        cur = i
        break
      end
    end
    local target = cur + delta
    if target >= 1 and target <= #infos then
      infos[target].pane:activate()
    else
      window:perform_action(act.ActivateTabRelative(delta), pane)
    end
  end)
end

-- Navigate tabs, crossing into the next/previous window when already at the
-- last/first tab of the current window. ctrl+pgdown past the last tab lands on
-- the first tab of the next window; ctrl+pgup past the first tab lands on the
-- last tab of the previous window. Both wrap around.
--
-- Window order is by mux window-id, i.e. creation order. That's the closest
-- stable "book order" the API exposes — WezTerm doesn't let us query a window's
-- on-screen position, so spatial ordering isn't possible (the pathological case
-- the request anticipates: windows physically arranged out of creation order).
local function tab_nav_across_windows(delta)
  return wezterm.action_callback(function(window, pane)
    local mux_win = window:mux_window()
    local tabs = mux_win:tabs_with_info()
    local cur
    for _, info in ipairs(tabs) do
      if info.is_active then cur = info.index; break end -- index is 0-based
    end

    -- Still inside the current window's tab range — plain relative move.
    local target = (cur or 0) + delta
    if target >= 0 and target <= #tabs - 1 then
      window:perform_action(act.ActivateTabRelative(delta), pane)
      return
    end

    -- Need to cross a window boundary. Order all windows by id (creation order).
    local wins = wezterm.mux.all_windows()
    if #wins < 2 then
      window:perform_action(act.ActivateTabRelative(delta), pane) -- lone window: wrap in place
      return
    end
    table.sort(wins, function(a, b) return a:window_id() < b:window_id() end)

    local cur_id = mux_win:window_id()
    local pos
    for i, w in ipairs(wins) do
      if w:window_id() == cur_id then pos = i; break end
    end

    local next_pos = pos + delta
    if next_pos < 1 then next_pos = #wins end
    if next_pos > #wins then next_pos = 1 end

    local target_win = wins[next_pos]
    local target_tabs = target_win:tabs()
    -- Forward → first tab of the next window; backward → last tab of the prev.
    local target_tab = delta > 0 and target_tabs[1] or target_tabs[#target_tabs]
    if target_tab then
      target_tab:activate()
      local gui = target_win:gui_window()
      if gui then gui:focus() end
    end
  end)
end

-- Spawn a new tab immediately after the current one (not appended at end).
local function spawn_tab_next(domain)
  return wezterm.action_callback(function(win, pane)
    local idx
    for _, item in ipairs(win:mux_window():tabs_with_info()) do
      if item.is_active then idx = item.index; break end
    end
    win:perform_action(act.SpawnTab(domain), pane)
    win:perform_action(act.MoveTab(idx + 1), pane)
  end)
end

-- ---------- Background tabs (unix-domain detach/reattach) ----------
-- A "background tab" is a tab whose panes live in a dedicated unix multiplexer
-- domain (bg-1..bg-N) served by a wezterm-mux-server process that outlives this
-- GUI. ctrl+alt+t opens one; ctrl+shift+w detaches the current one (it vanishes
-- from the GUI but its shell + whatever it's running keep going in the server);
-- ctrl+shift+e reattaches a detached session. This is WezTerm's tmux-style
-- detach/attach, at tab granularity — DetachDomain is domain-wide, and since we
-- allocate one domain per bg tab, "detach the domain" == "background this tab"
-- (all its split panes go together; you can't background just one pane).
--
-- WHY A STATIC POOL: unix_domains is read only at config load — there is no API
-- to mint a domain at runtime — so we pre-declare a fixed pool. Domains are
-- served LAZILY: an unused bg-N never starts a server, so the pool is nearly
-- free until used. BG_POOL_SIZE caps how many bg tabs can exist at once.
--
-- CONSTRAINT: a process is only detachable if it was BORN in a bg domain; you
-- can't relocate a running local-domain pane into one after the fact (same
-- reason you can't retro-fit a running shell "into tmux"). Hence bg tabs are
-- created explicitly, never converted from normal tabs.
--
-- Windows-guarded: this is a macOS/Linux feature. AF_UNIX socket paths under the
-- home dir don't translate to the Windows port, and the daily driver there is
-- the WSL local domain, so we skip the pool + binds on Windows entirely.
local BG_POOL_SIZE = 8
local BG_SOCK_DIR = wezterm.home_dir .. '/.local/share/wezterm'
local BG_ENABLED = not wezterm.target_triple:find('windows')
-- Absolute path to the bundled mux-server. `wezterm-mux-server` is NOT on PATH
-- inside the macOS .app, so the default auto-serve (which invokes it bare) can't
-- be relied on — and even when found, a bare server ignores per-domain settings
-- (see the serve_command note below). wezterm.executable_dir points at the
-- Contents/MacOS dir holding all three binaries.
local BG_MUX_BIN = wezterm.executable_dir .. '/wezterm-mux-server'

-- Each bg-N needs its OWN mux-server bound to its OWN socket + pid file. The
-- critical gotcha (learned the hard way, verified by tracing the GUI log):
-- WezTerm's connect-time auto-spawn is HARDCODED to run a bare
-- `wezterm-mux-server --daemonize` — it does NOT honour the domain's
-- serve_command. A bare server binds the DEFAULT socket
-- (~/.local/share/wezterm/sock) and default pid file, never bg-N.sock, so the
-- client waits on a socket that never appears (the "No such file" error). Worse,
-- every bare server contends for the one default pid lock.
--
-- So we DISABLE auto-spawn (no_serve_automatically=true) and start the correct
-- per-domain server ourselves from the ctrl+alt+t callback via
-- background_child_process(bg_serve_command(name)) before spawning the tab. The
-- serve_command below is the exact argv we launch: a one-domain server (that
-- domain made default so it binds ITS socket) with a unique pid file.
-- --skip-config keeps this GUI file (with its gui-only handlers) out of the
-- headless server. Verified end-to-end: binds bg-N.sock + bg-N.pid, leaves the
-- default mux untouched, and the GUI then attaches cleanly.
local function bg_serve_command(name)
  local sock = BG_SOCK_DIR .. '/' .. name .. '.sock'
  local pidf = BG_SOCK_DIR .. '/' .. name .. '.pid'
  return {
    BG_MUX_BIN, '--daemonize', '--skip-config',
    '--config', "unix_domains={{name='" .. name .. "',socket_path='" .. sock .. "'}}",
    '--config', "default_domain='" .. name .. "'",
    '--config', "daemon_options={pid_file='" .. pidf .. "'}",
  }
end

if BG_ENABLED then
  config.unix_domains = {}
  for i = 1, BG_POOL_SIZE do
    local name = 'bg-' .. i
    -- socket_path: where the GUI client connects (and our liveness glob looks).
    -- no_serve_automatically: suppress WezTerm's broken bare auto-spawn; we
    -- pre-start the server ourselves (see spawn_bg_tab). serve_command is kept as
    -- the source of truth for that argv even though WezTerm won't invoke it.
    config.unix_domains[i] = {
      name = name,
      socket_path = BG_SOCK_DIR .. '/' .. name .. '.sock',
      serve_command = bg_serve_command(name),
      no_serve_automatically = true,
    }
  end
end

-- True while bg-N's mux-server is running. We can't use the mux API for this:
-- after DetachDomain the LOCAL mux drops the domain's panes, so has_any_panes()
-- reports false for a detached-but-alive session, indistinguishable from a
-- never-used slot. The socket file on disk is the reliable cross-process signal.
-- wezterm.glob avoids shelling out (the wezterm CLI isn't on PATH inside the
-- macOS app bundle anyway).
local function bg_domain_live(name)
  local hits = wezterm.glob(BG_SOCK_DIR .. '/' .. name .. '.sock')
  return hits ~= nil and #hits > 0
end

-- name -> "Attached"/"Detached" for the pool domains the local mux knows about.
-- Attached is reliable (those domains are live in this GUI right now).
local function bg_domain_states()
  local st = {}
  for _, d in ipairs(wezterm.mux.all_domains()) do
    local n = d:name()
    if n:match('^bg%-%d+$') then st[n] = d:state() end
  end
  return st
end

-- First pool slot with no live server (nil if the whole pool is occupied).
local function first_free_bg_domain()
  for i = 1, BG_POOL_SIZE do
    local name = 'bg-' .. i
    if not bg_domain_live(name) then return name end
  end
  return nil
end

-- Reattach candidates: a live server that isn't currently shown in this GUI.
local function detached_bg_domains()
  local states = bg_domain_states()
  local out = {}
  for i = 1, BG_POOL_SIZE do
    local name = 'bg-' .. i
    if bg_domain_live(name) and states[name] ~= 'Attached' then
      out[#out + 1] = name
    end
  end
  return out
end

-- Spawn a bg tab once its server's socket is live. WezTerm won't auto-start the
-- server (no_serve_automatically), and the daemonized server takes ~200-300ms to
-- create its socket, so we can't SpawnTab immediately — the connect would fail.
-- Poll off the GUI thread with time.call_after (NOT sleep_ms, which would freeze
-- the UI) and spawn as soon as the socket appears; give up after ~2s.
local function spawn_bg_tab_when_ready(win, pane, name, attempts)
  attempts = attempts or 0
  if bg_domain_live(name) then
    local idx
    for _, item in ipairs(win:mux_window():tabs_with_info()) do
      if item.is_active then idx = item.index; break end
    end
    win:perform_action(act.SpawnTab { DomainName = name }, pane)
    if idx then win:perform_action(act.MoveTab(idx + 1), pane) end
    return
  end
  if attempts >= 40 then  -- 40 * 50ms = 2s
    win:toast_notification('WezTerm',
      'Background server ' .. name .. ' did not come up. See wezterm-mux logs.', nil, 4000)
    return
  end
  wezterm.time.call_after(0.05, function()
    spawn_bg_tab_when_ready(win, pane, name, attempts + 1)
  end)
end

-- ctrl+alt+t: open a background tab in the first free pool domain, placed right
-- after the current tab (matching spawn_tab_next). We start the domain's own
-- mux-server ourselves (WezTerm's auto-spawn is broken — see the pool block
-- above), then spawn into it once its socket is live. Toast if the pool is full.
local function spawn_bg_tab()
  return wezterm.action_callback(function(win, pane)
    if not BG_ENABLED then
      win:toast_notification('WezTerm', 'Background tabs are macOS/Linux only.', nil, 3000)
      return
    end
    local free = first_free_bg_domain()
    if not free then
      win:toast_notification('WezTerm',
        'Background-tab pool full (' .. BG_POOL_SIZE .. ' in use). Reattach + close one first.',
        nil, 4000)
      return
    end
    -- Fire-and-forget the per-domain server; poll for its socket, then spawn.
    wezterm.background_child_process(bg_serve_command(free))
    spawn_bg_tab_when_ready(win, pane, free, 0)
  end)
end

-- ctrl+shift+w: detach IFF the active pane is in a bg domain — otherwise a stray
-- press would silently tear a normal tab's panes out of the GUI. Guarded on the
-- domain name (get_domain_name is reliable for the active local pane).
local function detach_bg_tab()
  return wezterm.action_callback(function(win, pane)
    local dom = pane:get_domain_name() or ''
    if dom:match('^bg%-%d+$') then
      win:perform_action(act.DetachDomain 'CurrentPaneDomain', pane)
    else
      win:toast_notification('WezTerm',
        'Not a background tab (domain: ' .. dom .. '). Use ctrl+alt+t to open one.',
        nil, 3000)
    end
  end)
end

-- ctrl+shift+e: pick a detached background session and reattach it.
local function reattach_bg_tab()
  return wezterm.action_callback(function(win, pane)
    local cands = detached_bg_domains()
    if #cands == 0 then
      win:toast_notification('WezTerm', 'No detached background tabs to reattach.', nil, 3000)
      return
    end
    local choices = {}
    for _, name in ipairs(cands) do
      choices[#choices + 1] = { label = name, id = name }
    end
    win:perform_action(act.InputSelector {
      title = 'Reattach background tab',
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(w, p, id, _label)
        if id then w:perform_action(act.AttachDomain(id), p) end
      end),
    }, pane)
  end)
end

-- ctrl+shift+m: move the current tab into an EXISTING window (picked from a
-- list), as opposed to ctrl+shift+n which always pops it into a brand new one.
-- There is no Lua API for this: pane:move_to_new_window()/move_to_new_tab()
-- only ever create a fresh window/tab, they can't target one that's already
-- open. `wezterm cli move-pane-to-new-tab --window-id` can, so shell out to it.
-- Same executable_dir rationale as BG_MUX_BIN above (the CLI isn't on PATH
-- inside the macOS .app bundle); '.exe' only applies on the Windows build.
local WEZTERM_CLI_BIN = wezterm.executable_dir .. '/wezterm' .. (wezterm.target_triple:find('windows') and '.exe' or '')

-- Basename of a pane's cwd (e.g. "dotfiles" from "/home/x/dotfiles"), or nil if
-- the pane has none. Same userdata/string Url handling as format-tab-title's
-- cwd branch further down, just without that code's editor-file-name special
-- case (not worth it for a one-line picker label).
local function short_cwd(pane)
  local cwd = pane:get_current_working_dir()
  if not cwd then return nil end
  local path
  if type(cwd) == 'userdata' then
    path = cwd.file_path
  else
    path = tostring(cwd):gsub('^file://[^/]*', '')
  end
  if not path or path == '' then return nil end
  return (path:gsub('/$', ''):match('[^/]+$')) or path
end

-- Human label for a mux window, used by the move-tab-to-window picker below so
-- entries read like "3 tabs — nvim · dotfiles" instead of a bare window id.
local SHELL_PROCS = { bash = 1, sh = 1, zsh = 1, fish = 1, tmux = 1, nu = 1, login = 1 }
local function window_label(mux_win)
  local tabs = mux_win:tabs_with_info()
  local active_pane
  for _, t in ipairs(tabs) do
    if t.is_active then
      active_pane = t.tab:active_pane()
      break
    end
  end
  local desc = 'empty'
  if active_pane then
    local proc = active_pane:get_foreground_process_name() or ''
    local base = (proc:match('[^/\\]+$') or ''):gsub('%.exe$', '')
    local cwd = short_cwd(active_pane)
    if base ~= '' and not SHELL_PROCS[base] then
      desc = cwd and (base .. ' · ' .. cwd) or base
    else
      desc = cwd or 'shell'
    end
  end
  local n = #tabs
  return string.format('%d tab%s — %s', n, n == 1 and '' or 's', desc)
end

-- Window title. This reproduces WezTerm's own default (the worked example in
-- the format-window-title docs) and exists only so the format is OURS: it lets
-- hypr_focus_window below predict a window's exact title, which is the only
-- handle we have on which OS window is which. Keep the two in sync — if this
-- and mux_window_title ever disagree, focus silently stops following.
local function format_title(zoomed, tab_index, tab_count, pane_title)
  local z = zoomed and '[Z] ' or ''
  local idx = tab_count > 1 and string.format('[%d/%d] ', tab_index + 1, tab_count) or ''
  return z .. idx .. pane_title
end

wezterm.on('format-window-title', function(tab, _pane, tabs, _panes, _config)
  return format_title(tab.active_pane.is_zoomed, tab.tab_index, #tabs, tab.active_pane.title)
end)

-- The same string, derived from mux data. format-window-title's TabInformation
-- is only available inside that synchronous callback, so anything outside it
-- has to rebuild the title from the mux.
local function mux_window_title(mux_win)
  local tabs = mux_win:tabs_with_info()
  for _, item in ipairs(tabs) do
    if item.is_active then
      local zoomed = false
      for _, p in ipairs(item.tab:panes_with_info()) do
        if p.is_active then zoomed = p.is_zoomed; break end
      end
      return format_title(zoomed, item.index, #tabs, item.tab:active_pane():get_title() or '')
    end
  end
  return nil
end

-- Raise an OS window under Hyprland. Wayland doesn't let a client focus itself
-- — window:focus() is documented as unsupported there and silently does
-- nothing — so the compositor has to be asked instead. Hyprland's dispatchers
-- match on title, and titles are the only wezterm state a compositor can see
-- (every GUI window shares one pid and one app_id), hence format-window-title
-- above. If two windows somehow carry the same title, Hyprland focuses the
-- first; wrong-window is the worst case, never a crash.
--
-- No-ops off Hyprland: on macOS, Windows and X11 window:focus() works on its
-- own, so nothing here needs a per-OS equivalent.
--
-- Lua dispatch syntax, matching open-link.sh's focus call — hyprctl on the Lua
-- config wraps its argument as `return hl.dispatch(<arg>)`, so `focuswindow
-- title:...` is a parse error. The matcher is passed as a long-bracket string
-- because it is Lua source: the regex's backslashes would otherwise be read as
-- escape sequences. On an older Hyprland this fails harmlessly to stderr and
-- focus just stays put.
local HYPR_RE_META = '[%^%$%(%)%.%[%]%*%+%?%{%}|\\]'
local function hypr_focus_window(mux_win)
  if not os.getenv('HYPRLAND_INSTANCE_SIGNATURE') then return end
  local title = mux_window_title(mux_win)
  if not title or title == '' then return end
  local matcher = 'title:^' .. title:gsub(HYPR_RE_META, '\\%0') .. '$'
  wezterm.background_child_process {
    'hyprctl', 'dispatch', 'hl.dsp.focus({ window = [==[' .. matcher .. ']==] })',
  }
end

-- The move above runs as a detached CLI child process, so there's no completion
-- signal to hook and nothing focuses the destination: the tab lands unselected
-- in a window that isn't even raised. Poll the mux for the moved pane (same
-- call_after-not-sleep_ms rationale as spawn_bg_tab_when_ready), then activate
-- its new tab and focus its window. Matching on pane id rather than parsing the
-- CLI's stdout keeps this independent of where in the tab bar it landed.
local function focus_moved_pane(target_id, pane_id, attempts)
  attempts = attempts or 0
  for _, w in ipairs(wezterm.mux.all_windows()) do
    if w:window_id() == target_id then
      for _, item in ipairs(w:tabs_with_info()) do
        for _, p in ipairs(item.tab:panes()) do
          if p:pane_id() == pane_id then
            item.tab:activate()
            local gui = w:gui_window()
            if gui then gui:focus() end
            -- Activation has to land in the title bar before Hyprland can be
            -- asked to match on it.
            wezterm.time.call_after(0.1, function() hypr_focus_window(w) end)
            return
          end
        end
      end
    end
  end
  if attempts >= 40 then return end  -- 40 * 50ms = 2s; move failed, leave focus be
  wezterm.time.call_after(0.05, function()
    focus_moved_pane(target_id, pane_id, attempts + 1)
  end)
end

local function move_tab_to_window()
  return wezterm.action_callback(function(win, pane)
    local cur_id = win:mux_window():window_id()
    local choices = {}
    for _, w in ipairs(wezterm.mux.all_windows()) do
      if w:window_id() ~= cur_id then
        choices[#choices + 1] = { label = window_label(w), id = tostring(w:window_id()) }
      end
    end
    if #choices == 0 then
      win:toast_notification('WezTerm', 'No other window to move this tab to.', nil, 3000)
      return
    end
    win:perform_action(act.InputSelector {
      title = 'Move tab to window',
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(_w, p, id, _label)
        if not id then return end
        local moved_pane_id = p:pane_id()
        wezterm.background_child_process {
          WEZTERM_CLI_BIN, 'cli', 'move-pane-to-new-tab',
          '--pane-id', tostring(moved_pane_id),
          '--window-id', id,
        }
        focus_moved_pane(tonumber(id), moved_pane_id)
      end),
    }, pane)
  end)
end

-- ---------- Session restore (windows, tabs, split layout, cwd) ----------
-- Restore the previous session on launch, Chrome-style: windows, their tabs,
-- each tab's split layout and each pane's cwd, with focus where you left it.
-- Running programs are deliberately NOT re-executed. Background (bg-N) tabs are
-- excluded — they already outlive the GUI in their own mux-server.
--
-- Lives in sessionstore.lua (the mux/filesystem adapter), over session.lua (the
-- pure, unit-tested state + split-layout logic). Shares BG_SOCK_DIR so the
-- session file sits beside the bg-tab sockets.
require('sessionstore').setup { dir = BG_SOCK_DIR }

-- Last known tab title — format-tab-title stashes here so overlays (InputSelector
-- etc.) that blank the active pane don't cause a flicker to an empty title.
local last_tab_title = {}

-- Per-window focus state, keyed by window-id, maintained by the
-- window-focus-changed handler below. format-tab-title reads it so an unfocused
-- window's active tab renders with the dulled inactive styling. nil = unknown
-- (before any focus event) → treated as focused so nothing dims on first paint.
local window_focus = {}

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
wezterm.on('user-var-changed', function(window, pane, name, value)
  if name == 'agent_status' or name == 'claude_status' then
    local pane_id = pane:pane_id()
    pane_status[pane_id] = value
    track_animation(pane_id, window:window_id(), value)
  end
end)

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

-- ---------- Default shell ----------
-- Default new tabs/windows to the WSL distro, but only on Windows: this domain
-- doesn't exist on Mac/Linux and setting it there errors at config load. There
-- the built-in local domain is used instead.
if wezterm.target_triple:find('windows') then
  config.default_domain = 'WSL:Ubuntu-24.04'
end

-- ---------- Renderer ----------
-- The default OpenGL path on this build uses a generic GL adapter and is slow
-- (laggy text selection / scrolling). Use WebGpu on the discrete GPU instead.
config.front_end = 'WebGpu'
config.webgpu_power_preference = 'HighPerformance'
config.max_fps = 120
for _, gpu in ipairs(wezterm.gui.enumerate_gpus()) do
  if gpu.backend == 'Vulkan' and gpu.device_type == 'DiscreteGpu' then
    config.webgpu_preferred_adapter = gpu
    break
  end
end

-- Disable macOS dead-key / IME composition so Option+key bindings work as raw keys.
config.send_composed_key_when_left_alt_is_pressed = false
config.send_composed_key_when_right_alt_is_pressed = false
config.use_ime = false
config.debug_key_events = false

-- ---------- Appearance ----------
-- Color schemes ported from the Ghostty themes (~/.config/ghostty/themes/).
-- WezTerm ships no cosmic-dusk/rapture builtins, so define them inline and pick
-- one via config.color_scheme. set-theme.sh sed-rewrites that line to switch.
config.color_schemes = {
  -- Ghostty "Cosmic Dusk" (~/.config/ghostty/themes/Cosmic Dusk).
  ['Cosmic Dusk'] = {
    background = '#0e1330',
    foreground = '#d8dce8',
    cursor_bg = '#d4607a',
    cursor_fg = '#0c1024',
    cursor_border = '#d4607a',
    selection_bg = '#2a3060',
    selection_fg = '#f0f2fa',
    ansi = { '#0c1024', '#d4607a', '#69db7c', '#fbbf24', '#6a7acc', '#b09ac0', '#7aadcc', '#d8dce8' },
    brights = { '#2a3060', '#e87898', '#7eeea0', '#ffd43b', '#7a8ae0', '#c4b0d8', '#8ac0e0', '#f0f2fa' },
  },
  -- "Rapture" — no Ghostty theme exists; palette matched to the other apps'
  -- rapture themes (Zed/Lite XL/Micro).
  ['Rapture'] = {
    background = '#111e2a',
    foreground = '#c0c9e5',
    cursor_bg = '#7afde1',
    cursor_fg = '#111e2a',
    cursor_border = '#7afde1',
    selection_bg = '#304b66',
    selection_fg = '#ffffff',
    ansi = { '#000000', '#fc644d', '#7afde1', '#fff09b', '#6c9bf5', '#ff4fa1', '#64e0ff', '#c0c9e5' },
    brights = { '#304b66', '#fc644d', '#7afde1', '#fff09b', '#6c9bf5', '#ff4fa1', '#64e0ff', '#ffffff' },
  },
}
-- NOTE: the "Set Theme..." palette entry persists your choice by rewriting the
-- color_scheme line in wezterm.config_file — i.e. in the APPLIED file, not this
-- source. So a `chezmoi apply` will reset the theme to whatever is written here.
-- Keep this line in sync with your current theme (or re-pick from the palette
-- after applying).
config.color_scheme = 'Cosmic Dusk'
config.font_size = 14
config.window_background_opacity = 0.92
config.window_padding = { left = 10, right = 10, top = 6, bottom = 6 }

-- Ghostty: macos-titlebar-style = tabs + hidden window buttons.
-- Windows nearest: integrate the min/max/close buttons into the tab bar.
config.window_decorations = 'RESIZE'
-- Hyprland (tiling Wayland) has no server-side title bar, so WezTerm draws its
-- own title strip + control buttons over the tab bar and the glyphs render as
-- broken empty squares. Hyprland handles move/resize itself, so drop decorations
-- entirely there. Other environments (e.g. GNOME) keep the resizable border.
local function running_under_hyprland()
  return os.getenv('HYPRLAND_INSTANCE_SIGNATURE') ~= nil
    or (os.getenv('XDG_CURRENT_DESKTOP') or ''):lower():find('hyprland') ~= nil
end
if running_under_hyprland() then
  config.window_decorations = 'NONE'
end
config.use_fancy_tab_bar = true
config.show_new_tab_button_in_tab_bar = false -- drop the "+" new-tab button
config.show_close_tab_button_in_tabs = false  -- drop the per-tab "x" (it overlapped the title)
-- Note: tab_max_width is ignored in fancy tab bar mode (tabs are sized by the
-- native widget / available width). Kept for the retro-bar fallback only. Our
-- own truncation in format-tab-title uses the per-tab max_width passed there.
config.tab_max_width = 32
local STATUS_UPDATE_INTERVAL_MS = 200
config.status_update_interval = STATUS_UPDATE_INTERVAL_MS
local scheme = config.color_schemes[config.color_scheme]
  or wezterm.color.get_builtin_schemes()[config.color_scheme]
  or { background = '#0e1330' }
config.window_frame = {
  -- Inter for the label text; fall back to Hack Nerd Font so the per-app tab
  -- icons (editor/git/docker/… — see APP_ICONS) have glyphs to render. Inter has
  -- no Private Use Area glyphs, so without the fallback they'd show as tofu.
  --
  -- Adwaita Mono is a third fallback purely for the Claude status stars ❋ (U+274B)
  -- and ✹ (U+2739): they exist in NO other installed font, so without this entry
  -- wezterm can only reach them via its ASYNC system-wide font search. That search
  -- can briefly gap across genuine config/theme reloads. Listing the font here
  -- resolves the glyphs synchronously from the configured stack.
  font = wezterm.font_with_fallback({ { family = 'Inter', weight = 'Medium' }, 'Hack Nerd Font', 'Adwaita Mono' }),
  font_size = 15,
  active_titlebar_bg = scheme.background,
  inactive_titlebar_bg = scheme.background,
  border_left_width = '1px',
  border_right_width = '1px',
  border_bottom_height = '1px',
  border_top_height = '1px',
  border_left_color = '#555555',
  border_right_color = '#555555',
  border_bottom_color = '#555555',
  border_top_color = '#555555',
}

-- split-divider-color = #FFBF00
config.colors = {
  split = '#FFBF00',
  tab_bar = {
    background = scheme.background,
    -- Fancy tab bar fills each button from these static colors (per-tab bg in
    -- format-tab-title only paints behind the text). Active tab a touch
    -- lighter than the bar; inactive matches the bar; hover between.
    active_tab   = { bg_color = '#2a3352', fg_color = '#ffffff' },
    inactive_tab = { bg_color = scheme.background, fg_color = '#aaaaaa' },
    inactive_tab_hover = { bg_color = '#1c2340', fg_color = '#dddddd' },
    new_tab = { bg_color = scheme.background, fg_color = '#888888' },
    new_tab_hover = { bg_color = '#1c2340', fg_color = '#dddddd' },
  },
}

-- copy-on-select = false (only copy via explicit ctrl+c)
config.mouse_bindings = {
  { event = { Up = { streak = 1, button = 'Left' } }, mods = 'NONE', action = act.Nop },
}

-- Close confirmation handled by ctrl+w callback below.
config.window_close_confirmation = 'NeverPrompt'

-- ---------- Keybinds ----------
config.keys = {
  -- config / palette
  { key = ',', mods = 'CTRL|SHIFT', action = act.ReloadConfiguration },
  { key = 'p', mods = 'CTRL|SHIFT', action = act.ActivateCommandPalette },

  -- tabs / windows / panes
  -- Close pane: immediate if only shell running, else prompt (Enter to confirm).
  { key = 'w', mods = 'CTRL', action = wezterm.action_callback(function(window, pane)
    local dominated_by_shell = true
    local procs = pane:get_foreground_process_name()
    if procs then
      local name = procs:match('[^/\\]+$') or procs
      local skip = { bash=1, sh=1, zsh=1, fish=1, tmux=1, nu=1, login=1 }
      if not skip[name] then
        dominated_by_shell = false
      end
    end
    if dominated_by_shell then
      window:perform_action(act.CloseCurrentPane { confirm = false }, pane)
    else
      window:perform_action(act.InputSelector {
        title = '🛑 Kill pane with running process? (Enter = yes, Esc = no)',
        choices = { { label = 'Yes, close pane' } },
        action = wezterm.action_callback(function(win, p, id, label)
          if label then
            win:perform_action(act.CloseCurrentPane { confirm = false }, p)
          end
        end),
      }, pane)
    end
  end) },
  -- Esc: interrupt handling. A user interrupt (Esc mid-response) fires no hook in
  -- either agent, so the agent_status var stays stuck on 'working' and the tab
  -- keeps spinning. Intercept Esc here: if the pane is running an agent, mark it
  -- 'done' in pane_status (the tab bar's source of truth) so it drops to idle
  -- immediately. This intentionally includes non-interrupt uses such as dismissing
  -- a /btw overlay. Always forward the Esc to the app afterwards, so the agent
  -- still receives it. A fresh prompt's 'working' var write overrides 'done'.
  { key = 'Escape', mods = 'NONE', action = wezterm.action_callback(function(window, pane)
    local proc = pane:get_foreground_process_name() or ''
    local pid = pane:pane_id()
    local agent = agent_of_pane(proc, pane:get_user_vars())
    if agent then
      pane_status[pid] = 'done'
    end
    window:perform_action(act.SendKey { key = 'Escape' }, pane)
  end) },
  { key = 't', mods = 'CTRL', action = spawn_tab_next('CurrentPaneDomain') },
  -- new PowerShell (pwsh) tab in the local Windows domain (default domain is WSL).
  -- Full path to the MSI install — avoids the slow WindowsApps execution-alias stub.
  { key = 't', mods = 'CTRL|SHIFT', action = wezterm.action_callback(function(win, pane)
    local idx
    for _, item in ipairs(win:mux_window():tabs_with_info()) do
      if item.is_active then idx = item.index; break end
    end
    win:perform_action(act.SpawnCommandInNewTab {
      domain = { DomainName = 'local' },
      args = { 'C:\\Program Files\\PowerShell\\7\\pwsh.exe' },
    }, pane)
    win:perform_action(act.MoveTab(idx + 1), pane)
  end) },
  { key = 'n', mods = 'CTRL', action = act.SpawnWindow },
  -- ctrl+shift+n: pop the current tab out into its own new window.
  { key = 'n', mods = 'CTRL|SHIFT', action = wezterm.action_callback(function(win, pane)
    local _, new_window = pane:move_to_new_window()
    local gui = new_window:gui_window()
    if gui then gui:focus() end
  end) },
  -- ctrl+shift+m: move the current tab into an existing window (pick from a list).
  { key = 'm', mods = 'CTRL|SHIFT', action = move_tab_to_window() },
  -- Background tabs: ctrl+alt+t opens one (unix-domain, survives GUI close),
  -- ctrl+shift+w detaches the current bg tab, ctrl+shift+e reattaches one. The
  -- callbacks no-op with a toast on non-macOS/Linux (BG_ENABLED). See the
  -- "Background tabs" block above for the full rationale.
  { key = 't', mods = 'CTRL|ALT', action = spawn_bg_tab() },
  { key = 'w', mods = 'CTRL|SHIFT', action = detach_bg_tab() },
  { key = 'e', mods = 'CTRL|SHIFT', action = reattach_bg_tab() },
  { key = 'PageUp', mods = 'CTRL', action = tab_nav_across_windows(-1) },
  { key = 'PageDown', mods = 'CTRL', action = tab_nav_across_windows(1) },

  -- clipboard
  -- ctrl+v: normal text paste. ctrl+shift+v: forward ^V to the app so Claude
  -- Code (running in WSL) fires its own image-paste handler — WezTerm's own
  -- PasteFrom only handles text and would drop clipboard images.
  { key = 'v', mods = 'CTRL', action = act.PasteFrom 'Clipboard' },
  { key = 'v', mods = 'CTRL|SHIFT', action = act.SendKey { key = 'v', mods = 'CTRL' } },
  { key = 'Insert', mods = 'SHIFT', action = act.PasteFrom 'Clipboard' },
  -- performable ctrl+c: copy if there's a selection, else send SIGINT (^C)
  {
    key = 'c',
    mods = 'CTRL',
    action = wezterm.action_callback(function(window, pane)
      local sel = window:get_selection_text_for_pane(pane)
      if sel and sel ~= '' then
        window:perform_action(act.CopyTo 'Clipboard', pane)
      else
        window:perform_action(act.SendKey { key = 'c', mods = 'CTRL' }, pane)
      end
    end),
  },

  -- unbind ghostty's ctrl+shift+left/right
  { key = 'LeftArrow', mods = 'CTRL|SHIFT', action = act.DisableDefaultAssignment },
  { key = 'RightArrow', mods = 'CTRL|SHIFT', action = act.DisableDefaultAssignment },

  -- scrolling
  { key = 'PageUp', mods = 'SHIFT', action = act.ScrollByPage(-1) },
  { key = 'PageDown', mods = 'SHIFT', action = act.ScrollByPage(1) },
  { key = 'PageUp', mods = 'NONE', action = wezterm.action_callback(function(window, pane)
    local proc = pane:get_foreground_process_name() or ''
    if agent_of_pane(proc, pane:get_user_vars()) == 'codex' then
      window:perform_action(act.ScrollByPage(-1), pane)
    else
      window:perform_action(act.SendKey { key = 'PageUp' }, pane)
    end
  end) },
  { key = 'PageDown', mods = 'NONE', action = wezterm.action_callback(function(window, pane)
    local proc = pane:get_foreground_process_name() or ''
    if agent_of_pane(proc, pane:get_user_vars()) == 'codex' then
      window:perform_action(act.ScrollByPage(1), pane)
    else
      window:perform_action(act.SendKey { key = 'PageDown' }, pane)
    end
  end) },

  -- panes: create (alt+super) and navigate (super). See NOTES re: Win key on Windows.
  { key = "'", mods = 'ALT|SUPER', action = act.SplitPane { direction = 'Right' } },
  { key = 't', mods = 'CTRL|SHIFT|ALT|SUPER', action = act.SplitPane { direction = 'Right' } },
  { key = 'h', mods = 'CTRL', action = act.SplitPane { direction = 'Right' } },
  { key = 'l', mods = 'ALT|SUPER', action = act.SplitPane { direction = 'Left' } },
  { key = 'p', mods = 'ALT|SUPER', action = act.SplitPane { direction = 'Up' } },
  { key = ';', mods = 'ALT|SUPER', action = act.SplitPane { direction = 'Down' } },
  { key = 'o', mods = 'ALT', action = act.TogglePaneZoomState },
  { key = 'RightArrow', mods = 'SUPER', action = act.ActivatePaneDirection 'Right' },
  { key = 'LeftArrow', mods = 'SUPER', action = act.ActivatePaneDirection 'Left' },
  { key = 'UpArrow', mods = 'SUPER', action = act.ActivatePaneDirection 'Up' },
  { key = 'DownArrow', mods = 'SUPER', action = act.ActivatePaneDirection 'Down' },

  -- raw escape / CSI-u sequences
  { key = '/', mods = 'SUPER', action = act.SendString '\x1f' },
  { key = 'l', mods = 'SUPER', action = act.SendString '\x1bl' },
  { key = 'p', mods = 'SUPER', action = act.SendString '\x1bp' },
  { key = ';', mods = 'SUPER', action = act.SendString '\x1b;' },
  { key = "'", mods = 'SUPER', action = act.SendString "\x1b'" },
  { key = 'Enter', mods = 'CTRL', action = act.SendString '\x1b[13;5u' },
  { key = 'Enter', mods = 'SHIFT', action = act.SendString '\x1b[13;2u' },
  { key = 'Backspace', mods = 'ALT', action = act.SendString '\x1b\x7f' },
  { key = 'Backspace', mods = 'CTRL', action = act.SendString '\x17' },
  { key = 'Delete', mods = 'ALT', action = act.SendString '\x1bd' },
  { key = 'Delete', mods = 'CTRL', action = act.SendString '\x1bd' },
  -- Word nav: karabiner rewrites ctrl+left/right => alt(option)+left/right,
  -- so the terminal sees Alt+Arrow. Emit the real ctrl+arrow CSI sequences
  -- (zsh binds these to backward-word/forward-word; TUIs read them too).
  { key = 'LeftArrow', mods = 'ALT', action = act.SendString '\x1b[1;5D' },
  { key = 'RightArrow', mods = 'ALT', action = act.SendString '\x1b[1;5C' },
  { key = 'k', mods = 'CTRL|SHIFT', action = act.SendString '\x0b' },
  { key = 'Home', mods = 'SHIFT', action = act.SendString '\x1b[1;2H' },
  { key = 'End', mods = 'SHIFT', action = act.SendString '\x1b[1;2F' },
}

-- ---------- Tab bar styling ----------
-- Agent session status, set per-pane via the OSC 1337 SetUserVar "agent_status"
-- escape sequence emitted by ~/.local/bin/wezterm-agent-status. Drives a leading
-- glyph + tab tint so you can see at a glance which tabs are working vs waiting.
-- Each state has an emphasized active bg and a dulled inactive bg.
local STATUS_STYLE = {
  working   = { glyph = '', active_bg = '#4C6B8A', inactive_bg = '#2C3E50' },
  -- stopped / turn finished: claude orange (matches the no-status fallback).
  -- No glyph — the claude icon in the title already marks these tabs.
  done      = { glyph = '', active_bg = '#C0623A', inactive_bg = '#7A3D24' },
  -- vivid saturated red, kept distinct from the muted claude-orange "done"
  attention = { glyph = '', active_bg = '#E5252B', inactive_bg = '#8A1418' },
}

-- Per-app tab icons for non-claude tabs. Keyed by the foreground process
-- basename (what pane:get_foreground_process_name reports, sans path/.exe).
-- When a running command matches, its Nerd Font glyph replaces the default ❯
-- prompt marker so you can tell editor/git/file-manager/… tabs apart at a
-- glance. All glyphs are from Hack Nerd Font (the window_frame fallback above);
-- text-default codepoints so they take our marker_fg tint, not emoji coloring.
-- App choices seeded from the user's atuin history (micro, keifu/gg, yazi,
-- zellij, docker, cargo, bun, python/uv, codex, ssh, vim/nvim, top-tools, git).
-- Glyphs written as \u{} escapes (NOT raw bytes): raw Nerd Font PUA codepoints
-- get silently stripped when this file is edited through some tooling, leaving
-- empty strings that render as no marker. All codepoints verified present in
-- Hack Nerd Font (the window_frame fallback).
local APP_ICONS = {
  -- editors
  micro = '\u{eae9}',  nano = '\u{eae9}',  vim = '\u{e62b}',  nvim = '\u{e62b}',  vi = '\u{e62b}',
  hx = '\u{f0e7}',  helix = '\u{f0e7}',  emacs = '\u{e632}',
  -- git / version control (keifu is the user's `gg` git TUI)
  keifu = '\u{e725}',  git = '\u{e702}',  lazygit = '\u{e702}',  gitui = '\u{e702}',  tig = '\u{e702}',
  -- file managers
  yazi = '\u{ea83}',  ranger = '\u{ea83}',  nnn = '\u{ea83}',  lf = '\u{ea83}',  broot = '\u{ea83}',
  -- multiplexers / sessions
  zellij = '\u{f489}',  tmux = '\u{ebc7}',  screen = '\u{ebc7}',
  -- containers / infra
  docker = '\u{f308}',  ['docker-compose'] = '\u{f308}',  kubectl = '\u{f10fe}',  k9s = '\u{f10fe}',
  -- languages / runtimes
  cargo = '\u{e7a8}',  rustc = '\u{e7a8}',  bun = '\u{e76f}',  node = '\u{e718}',  deno = '\u{e718}',
  python = '\u{e606}',  python3 = '\u{e606}',  uv = '\u{e606}',  ['python3.12'] = '\u{e606}',
  go = '\u{e626}',  ruby = '\u{e739}',  lua = '\u{e620}',
  -- ai clis
  codex = '\u{f0ea0}',  openclaw = '\u{f0ea0}',
  -- remote / net
  ssh = '\u{f08c0}',  mosh = '\u{f08c0}',  ping = '\u{f0200}',  curl = '\u{f0ee}',  wget = '\u{f0ee}',
  -- monitors
  htop = '\u{f0e4}',  btop = '\u{f0e4}',  top = '\u{f0e4}',  btm = '\u{f0e4}',
  -- misc common
  fzf = '\u{f422}',  rg = '\u{f422}',  make = '\u{e673}',  bat = '\u{f0e7}',  less = '\u{f15c}',
  man = '\u{f02d}',  brew = '\u{f0f4}',  psql = '\u{e76e}',  redis = '\u{e76d}',  sqlite3 = '\u{e7c4}',
}

-- Per-agent tab markers. Shape identifies the agent; color identifies whether it
-- is working, idle or waiting for input. Working markers animate from wall-clock
-- time; their repaint signal uses only the local animated_panes cache.
-- Every glyph carries VARIATION SELECTOR-15 (\u{FE0E}) to force TEXT presentation
-- — bare shapes in these blocks can render as emoji that ignore our color. All of
-- them come from Adwaita Mono, the third window_frame fallback (Inter and Hack
-- Nerd Font have none of these codepoints), same as the Claude stars always have.
--
-- Adding an agent = one entry here plus one branch in agent_of_pane.
local function pingpong(ramp)
  local result = {}
  for i = 1, #ramp do result[#result + 1] = ramp[i] end
  for i = #ramp - 1, 2, -1 do result[#result + 1] = ramp[i] end
  return result
end

local function frame_at(now, ramp, period_ms)
  return ramp[(math.floor(now / period_ms) % #ramp) + 1]
end

local GLYPH_MS = 333
local COLOR_MS = 250
local SHIMMER_MS = 60

local AGENT_MARKERS = {
  claude = {
    idle       = '❋\u{FE0E}',  -- U+274B heavy eight-teardrop asterisk
    idle_fg    = '#C0623A',    -- claude orange (matches STATUS_STYLE.done)
    -- Needs input: a CHUNKIER star than idle — ✹ (U+2739, twelve-pointed filled
    -- black star) is denser than the ❋ outline, so the tab stands out twice over
    -- (shape + red).
    attention  = '✹\u{FE0E}',
    frames = pingpong({
      '✢\u{FE0E}', '✶\u{FE0E}', '✻\u{FE0E}', '✽\u{FE0E}',
    }),
    colors = pingpong({
      '#4a7fd6', '#4aa6c8', '#3fb8a8', '#4fc785', '#63d46b',
    }),
  },
  codex = {
    idle       = '⬢\u{FE0E}',  -- U+2B22 black hexagon — OpenAI's mark is hexagonal
    idle_fg    = '#B23A48',    -- muted crimson
    attention  = '⬣\u{FE0E}',  -- U+2B23 horizontal black hexagon: wider, denser
    frames = pingpong({
      '⬩\u{FE0E}', '⬦\u{FE0E}', '◈\u{FE0E}', '⬥\u{FE0E}',
    }),
    colors = pingpong({
      '#0E8C6E', '#10A37F', '#1FBF93', '#45D6A8', '#6FE8C0',
    }),
  },
}

local function shimmer_grey(lo, hi, amount, dither)
  local value = math.floor(lo + (hi - lo) * amount + 0.5)
  return string.format('#%02x%02x%02x', value, value, value - dither)
end

local function shimmer_runs(title, phase, is_active)
  local lo, hi = is_active and 0xcc or 0x8e, is_active and 0xff or 0xbe
  local runs = {}
  local index = 0
  for _, codepoint in utf8.codes(title) do
    local wave = (math.cos((index - phase) * 0.5) + 1) / 2
    runs[#runs + 1] = {
      Foreground = {
        Color = shimmer_grey(lo, hi, wave, index % 2),
      },
    }
    runs[#runs + 1] = { Text = utf8.char(codepoint) }
    index = index + 1
  end
  return runs
end

wezterm.on('format-tab-title', function(tab, tabs, panes, cfg, hover, max_width)
  local pane_info = tab.active_pane
  local title = pane_info.title or ''
  local proc = pane_info.foreground_process_name or ''

  -- An active tab in an unfocused window should look inactive: fold the window's
  -- focus state into is_active so all the styling below (intensity, underline,
  -- bg tint) dims to match the greyed-out window contents. focus default is nil
  -- (treated as focused) so tabs don't dim before the first focus event.
  local window_focused = window_focus[tab.window_id] ~= false
  local is_active = tab.is_active and window_focused

  -- Overlays (InputSelector, etc.) replace the active pane with one that has no
  -- cwd and no foreground process. Fall back to the last known rendered title.
  if not pane_info.current_working_dir and (proc == '' or proc == nil) then
    local cached = last_tab_title[tostring(tab.tab_id)]
    if cached then
      return cached
    end
  end

  -- Which agent (if any) owns this pane. `agent` drives the status marker for
  -- both Claude and Codex; `is_claude` additionally drives the TITLE source,
  -- because only Claude's pane title is a useful label (its current task).
  -- Codex titles its pane with its own run-state text, which duplicates what our
  -- marker already says, so codex tabs take the normal cwd path below.
  local agent = agent_of_pane(proc, pane_info.user_vars)
  local is_claude = agent == 'claude'

  -- On exit Claude blanks its pane title (renders as a lone "_") for a frame
  -- before the shell repaints. proc still reads "claude" that frame, so the
  -- overlay guard above misses it (it requires no proc) and we'd flash an
  -- orange "_" tab. Treat a blank title while proc is still "claude" as the
  -- teardown frame and render it as a normal shell tab (cwd, black bg) right
  -- away, instead of holding the orange claude styling until the shell repaints.
  if is_claude and (title == '' or title == '_') then
    is_claude = false
    agent = nil
    proc = ''  -- so the branch below takes the plain-cwd path, not "cwd: _"
  end

  -- For non-claude tabs, show "cwd" or "cwd: command" if a process is running
  if not is_claude then
    local cwd = pane_info.current_working_dir
    local basename = ''
    if cwd then
      local path
      if type(cwd) == 'userdata' then
        -- Url object. file_path (already decoded) is nil when the OSC-7 host !=
        -- local host, so fall back to the percent-encoded .path and decode that.
        -- Never call string methods on the userdata, or the handler errors and
        -- wezterm shows the raw full-path title.
        path = cwd.file_path
        if not path or path == '' then
          path = (cwd.path or ''):gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
        end
      else
        -- Legacy string form: "file://host/path"
        path = tostring(cwd):gsub('^file://[^/]*', '')
      end
      path = path:gsub('[/\\]+$', '')
      basename = path:match('[^/\\]+$') or path
    end

    local proc_name = (proc:match('[^/\\]+$') or ''):gsub('%.exe$', '')
    local shells = { bash=1, sh=1, zsh=1, fish=1, nu=1, login=1 }
    if proc_name ~= '' and not shells[proc_name] then
      if APP_ICONS[proc_name] then
        -- Known app: its marker icon (set below) already names the app, so show
        -- just the cwd — no redundant "cwd: micro". Reading an editor's argv to
        -- recover its filename is intentionally avoided in this GUI-thread hook.
        title = basename
      else
        -- Unknown command — show "cwd: command args" from pane title.
        -- pane title is usually set to the running command by the shell.
        local cmd = pane_info.title or proc_name
        title = basename .. ': ' .. cmd
      end
    else
      title = basename
    end
  end

  -- Append pane count if more than one
  local pane_count = #tab.panes
  if pane_count > 1 then
    title = title .. ' (' .. pane_count .. ')'
  end

  -- Fancy tab bar renders each tab as its own rounded button and only fills the
  -- whole button from the static config.colors.tab_bar.* palette — a per-tab
  -- Background here paints just a rectangle behind the text, not the tab. So
  -- instead of tinting the tab bg, we lead with a colored status dot: claude
  -- tabs get an orange dot (or the working/attention status color), plain tabs
  -- get none. Underline marks the active tab; the button bg stays uniform.
  -- Keep intensity CONSTANT across focus. Previously active=Normal / inactive=Half:
  -- bold (Normal) glyphs are wider, so the same title rendered wider when focused,
  -- changing the visible length and clipping the '…' on the active tab. Fixing the
  -- weight makes width focus-independent; active tabs are still distinguished by
  -- underline, brighter fg, and the active_tab bg color.
  local intensity = 'Normal'
  local underline = is_active and 'Single' or 'None'

  -- Claude Code prefixes its pane title with its own animated spinner — a glyph
  -- (star ✳/✻/✽ or braille ⠐⠓⠋…) that lives in the U+2xxx range = 3-byte UTF-8
  -- starting 0xE2 — sometimes preceded by a "N: " tool/step count. We render our
  -- own marker, so strip both, otherwise two spinners compete. Loop so "3: ⠐ x"
  -- collapses to "x" in one pass.
  if is_claude then
    local changed = true
    while changed do
      changed = false
      -- Leading "N: " count prefix.
      local t = title:gsub('^%s*%d+:%s+', '')
      if t ~= title then title = t; changed = true end
      -- Leading 3-byte-glyph spinner token (0xE2 ...) + trailing space.
      t = title:gsub('^%s*\226[\128-\191][\128-\191]%s+', '')
      if t ~= title then title = t; changed = true end
    end
  end

  -- No custom separator glyph: fancy bar draws its own faint divider between
  -- buttons, and any glyph we add lands *inside* the button (a second, offset
  -- bar). Tab separation instead comes from distinct button bg colors set in
  -- config.colors.tab_bar.* (active vs inactive contrast).
  --
  -- Resolve the leading marker glyph + its color for the current state first, so
  -- we know how many cells it consumes before deciding how much title fits.
  local marker, marker_fg, title_fg
  local is_working = false
  if agent then
    local m = AGENT_MARKERS[agent]
    local status = agent_status_of(pane_info.pane_id, pane_info.user_vars)
    track_animation(pane_info.pane_id, tab.window_id, status)
    local style = status and STATUS_STYLE[status]
    if status == 'working' then
      is_working = true
      local now = now_ms()
      marker = frame_at(now, m.frames, GLYPH_MS)
      marker_fg = frame_at(now, m.colors, COLOR_MS)
    elseif status == 'attention' then
      -- Needs input: loud red, and a chunkier glyph than idle, so a tab awaiting
      -- input stands out twice over (shape + color).
      marker = m.attention
      marker_fg = '#F26D64'
    else
      -- done / idle: the agent's own glyph in its own color. Note these are all
      -- text-presentation codepoints — an emoji variant would be font-colored
      -- (e.g. ✳ renders green) and would ignore the tint we set here.
      marker = m.idle
      -- STATUS_STYLE.done carries claude's orange, so only claude reads from it;
      -- every other agent uses its own idle color.
      marker_fg = (agent == 'claude' and style and style.active_bg) or m.idle_fg
    end
    -- Attention also reddens the title text (not just the glyph) so the whole
    -- label shouts. Fancy bar blocks per-tab *background* color but per-item
    -- *foreground* is fine, so red text works here.
    if status == 'attention' then
      title_fg = '#F58A82'
    else
      title_fg = is_active and '#ffffff' or '#bbbbbb'
    end
  else
    -- Non-agent tabs: default to a terminal prompt glyph (❯ U+276F, text-
    -- presentation, needs no Nerd Font), dimmed so it reads as a marker not part
    -- of the name. If a known app is the foreground process, swap in its Nerd
    -- Font icon (see APP_ICONS) — strip any path and a trailing .exe first.
    local pname = (proc:match('[^/\\]+$') or ''):gsub('%.exe$', '')
    marker = APP_ICONS[pname] or '❯'
    -- Focused: rich saturated blue. Unfocused: muted slate (was grey).
    marker_fg = is_active and '#4a90e2' or '#5a7a9a'
    title_fg = is_active and '#ffffff' or '#aaaaaa'
  end

  -- Truncate via the pure helper. Use a conservative fixed budget rather than
  -- synchronously querying the mux from this GUI-thread callback.
  title = compute_tab_title {
    title = title,
    marker = marker,
    ntabs = #tabs,
    window_cols = 200,
    max_chars = 24,
    marker_pad = 3,  -- '  ' before + ' ' after the marker
    width = wezterm.column_width,
    truncate = wezterm.truncate_right,
  }

  local result = {
    { Attribute = { Intensity = intensity } },
    { Attribute = { Underline = underline } },
    { Foreground = { Color = marker_fg } },
    { Text = '  ' .. marker .. ' ' },
  }
  if is_working then
    local phase = math.floor(now_ms() / SHIMMER_MS)
    for _, run in ipairs(shimmer_runs(title, phase, is_active)) do
      result[#result + 1] = run
    end
    result[#result + 1] = { Text = ' ' }
  else
    result[#result + 1] = { Foreground = { Color = title_fg } }
    result[#result + 1] = { Text = title .. ' ' }
  end

  last_tab_title[tostring(tab.tab_id)] = result
  return result
end)

-- ---------- Dim unfocused windows' tab titles ----------
-- Record per-window focus state so format-tab-title renders an unfocused
-- window's active tab with the dulled inactive styling (it gates underline /
-- intensity on `tab.is_active and window_focused`), then force the tab bar to
-- repaint immediately.
--
-- format-tab-title recomputing does not itself repaint the GUI surface, so write
-- a focus-specific zero-width right status to invalidate the tab bar. This uses
-- the same cheap path as the agent animation and avoids the measured ~116-135ms
-- full config reload previously caused by set_config_overrides. Two characters
-- distinguish focus invalidations from the animation's one-character payload;
-- all remain zero-width, so the tab-bar layout is unchanged.
wezterm.on('window-focus-changed', function(window, pane)
  local focused = window:is_focused()
  window_focus[window:window_id()] = focused

  local payload = focused and '\u{200b}\u{200b}' or '\u{feff}\u{feff}'
  window:set_right_status(wezterm.format({ { Text = payload } }))
end)

-- Repaint animated titles from local state only. Entries not observed by a tab
-- render recently are discarded, covering closed panes and hidden windows
-- without querying the mux from the GUI event loop.
wezterm.on('update-status', function(window, pane)
  local now = now_ms()
  local window_id = window:window_id()
  local any_working = false

  for pane_id, state in pairs(animated_panes) do
    if now - state.last_seen > 3000 then
      animated_panes[pane_id] = nil
    elseif state.window_id == window_id then
      any_working = true
    end
  end

  local payload = '\u{200b}'
  if any_working and math.floor(now / STATUS_UPDATE_INTERVAL_MS) % 2 == 1 then
    payload = '\u{feff}'
  end
  window:set_right_status(wezterm.format({ { Text = payload } }))
end)

-- ---------- Command palette: Set Theme ----------
local function persist_color_scheme(name)
  local config_path = wezterm.config_file
  local fh = io.open(config_path, 'r')
  if not fh then return end
  local content = fh:read('*a')
  fh:close()
  local updated = content:gsub(
    "(config%.color_scheme%s*=%s*)('[^']*')",
    "%1'" .. name:gsub("'", "\\'") .. "'"
  )
  local out = io.open(config_path, 'w')
  if out then
    out:write(updated)
    out:close()
  end
end

wezterm.on('augment-command-palette', function(window, pane)
  return {
    {
      brief = 'Set Theme...',
      icon = 'md_palette',
      action = wezterm.action_callback(function(win, p)
        local schemes = wezterm.get_builtin_color_schemes()
        for name, _ in pairs(config.color_schemes or {}) do
          schemes[name] = true
        end
        local choices = {}
        for name, _ in pairs(schemes) do
          table.insert(choices, { label = name })
        end
        table.sort(choices, function(a, b) return a.label < b.label end)

        win:perform_action(act.InputSelector {
          title = 'Set Theme',
          choices = choices,
          fuzzy = true,
          action = wezterm.action_callback(function(w, _, _, label)
            if label then
              local overrides = w:get_config_overrides() or {}
              overrides.color_scheme = label
              w:set_config_overrides(overrides)
              persist_color_scheme(label)
            end
          end),
        }, p)
      end),
    },
  }
end)

return config

-- ---------- NOTES: things that don't port from the Ghostty config ----------
-- * quick-terminal-* : macOS-only Ghostty feature. On Windows your AutoHotkey
--   F9 dropdown (terminal_dropdown.ahk) fills this role instead.
-- * custom-shader (enter-ripple.glsl) : WezTerm has no GLSL shader hook.
-- * font-thicken / font-thicken-strength : no direct equivalent. Closest is
--   picking a heavier font weight via config.font = wezterm.font(name, {weight=...}).
-- * write_screen_file:paste (ctrl+shift+c) : no equivalent; left as default copy.
-- * ctrl+,=open_config and ctrl+shift+t=undo : no built-in WezTerm actions.
-- * SUPER == the Windows key, which Windows reserves (Win+L locks, Win+P projects)
--   and your AHK script also intercepts (Win+Arrows, LWin remap). The super+arrow
--   pane nav and super+l/p/; binds above likely won't reach WezTerm. If you want
--   them to actually fire, say so and I'll remap those to ALT or CTRL+ALT.
