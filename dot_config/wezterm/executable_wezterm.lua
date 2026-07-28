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
    pane_status[pane:pane_id()] = value
  end
end)

-- Runtimes that run an agent as a SCRIPT, so the process name is the runtime and
-- says nothing about which agent (if any) it is hosting — see agent_of_proc.
local JS_RUNTIMES = { node = 1, bun = 1, deno = 1 }

local function agent_named_in(s)
  if not s or s == '' then return nil end
  if s:find('claude') then return 'claude' end
  if s:find('codex') then return 'codex' end
  return nil
end

-- Which coding agent (if any) a pane's foreground process is: 'claude' | 'codex'
-- | nil. Drives both the Esc interrupt fix-up and the tab-bar status styling, so
-- adding an agent is a one-line change in agent_named_in.
--
-- The process path alone is NOT enough. Only a natively-installed Claude Code
-- names itself in its executable path (~/.local/share/claude/versions/<ver>);
-- Codex — and an npm-installed Claude Code — run as a node script, so the
-- executable is .../bin/node and the agent's name appears only in the ARGV:
--     node /home/you/.nvm/versions/node/vX/bin/codex
-- Matching the path alone therefore silently missed every Codex pane, which then
-- fell through to the generic per-app icon and rendered as APP_ICONS.node — the
-- Node.js hexagon, static and status-less. So when the foreground process is a JS
-- runtime, fall back to scanning argv.
--
-- argv is fetched through a callback, not passed in, so the (cheap but non-zero)
-- /proc read only happens for panes that are actually running a JS runtime —
-- format-tab-title calls this for every tab on every repaint.
--
-- Known imprecision: `node ~/Repos/codex-experiments/x.js` would read as a Codex
-- pane. It only costs a wrong tab icon, and requires a JS runtime whose argv
-- names an agent, so it's not worth a heavier check.
local function agent_of_proc(proc, argv_fn)
  if not proc or proc == '' then return nil end
  local direct = agent_named_in(proc)
  if direct then return direct end

  local pname = (proc:match('[^/\\]+$') or ''):gsub('%.exe$', '')
  if not JS_RUNTIMES[pname] then return nil end

  for _, a in ipairs((argv_fn and argv_fn()) or {}) do
    local hosted = agent_named_in(a)
    if hosted then return hosted end
  end
  return nil
end

-- argv of a pane's foreground process, or {} when unavailable. Everything is
-- pcall'd: format-tab-title runs on every repaint and an error there drops the
-- whole tab back to wezterm's raw default title.
local function pane_argv(pane_id)
  local ok, pane = pcall(wezterm.mux.get_pane, pane_id)
  if not ok or not pane then return {} end
  local ok2, info = pcall(function() return pane:get_foreground_process_info() end)
  if not ok2 or not info or not info.argv then return {} end
  return info.argv
end

-- Wall clock in milliseconds. THE reference for everything animated or expiring
-- below, deliberately in place of counting update-status events.
--
-- update-status does NOT fire on a fixed interval. It fires on the interval AND
-- on every repaint — and because the handler ends by writing a right-status that
-- differs each time, it invalidates the tab bar, which repaints, which fires the
-- handler again. Measured: ~24 events/sec in a single window, in bursts as close
-- as 9ms apart, against the 200ms status_update_interval you'd expect. Anything
-- paced by counting those events therefore runs at repaint rate and drifts with
-- machine load. Pacing off the clock instead makes the cadence exact and
-- independent of how often the handler happens to run.
--
-- Uses chrono's %s (epoch seconds) + %.3f (fractional part) via the wezterm.time
-- API; pcall'd, falling back to 0 so a missing/changed API degrades to a frozen
-- animation rather than an error in the middle of format-tab-title.
local function now_ms()
  local ok, s = pcall(function() return wezterm.time.now():format('%s%.3f') end)
  if not ok then return 0 end
  return (tonumber(s) or 0) * 1000
end

-- Ticks once per update-status event. Only used to vary the right-status payload
-- (see the bottom of that handler) — NOT for timing anything.
local status_tick = 0

-- agent_of_proc memo, keyed by pane-id: { proc = <the process path it was
-- resolved from>, agent = 'claude'|'codex'|false, tick = <status_tick then> }.
--
-- Necessary because the argv lookup reads /proc through the mux, while
-- format-tab-title runs on EVERY tab-bar repaint (~8-24x/sec per window). Doing
-- that read per tab per frame made the whole terminal visibly laggy.
--
-- Two invalidations, because neither alone is sufficient:
--   - proc changed → the foreground process was replaced (agent exited back to
--     the shell, or a command started). Catches every common transition, and is
--     free: we already have proc in hand.
--   - TTL → catches the case proc CAN'T: one node process replaced by another
--     node process, where the path is identical but the argv is not. Rare, so a
--     couple of seconds of a stale icon is the right trade for the frames saved.
local AGENT_CACHE_TTL_MS = 2000
local agent_cache = {}

local function agent_of_pane(pane_id, proc)
  local hit = agent_cache[pane_id]
  local now = now_ms()
  if hit and hit.proc == proc and (now - hit.at) < AGENT_CACHE_TTL_MS then
    return hit.agent or nil
  end
  local agent = agent_of_proc(proc, function() return pane_argv(pane_id) end)
  -- `false`, not nil: a table lookup can't distinguish "cached as not-an-agent"
  -- from "never looked up", and not-an-agent is the common case worth caching.
  agent_cache[pane_id] = { proc = proc, agent = agent or false, at = now }
  return agent
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
config.debug_key_events = true

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
-- Drives the update-status timer cadence = spinner animation frame rate. The
-- handler repaints via set_right_status (cheap, no config reload), so a fast
-- cadence is fine here. 200ms = 5fps — a lively star grow/shrink.
config.status_update_interval = 200
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
  -- result is flushed by the full config reload the window-focus-changed handler
  -- forces (see below), so for a frame after every focus change the idle star drew
  -- as .notdef (a tall box with a slash). Listing the font here makes the glyphs
  -- resolve synchronously from the configured stack, so the reload can't gap them.
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
  -- keeps spinning. Intercept Esc here: if the pane is running an agent AND it's
  -- currently 'working', mark it 'done' in pane_status (the tab bar's source of
  -- truth) so it drops to idle immediately. The 'working' guard is what keeps
  -- non-interrupt uses of Esc from touching state: dismissing a /btw overlay
  -- (or any Esc from an already-idle prompt) leaves status untouched, since only
  -- a genuinely in-progress response is 'working'. Always forward the Esc to the
  -- app afterwards, so this is purely additive — the agent still receives the
  -- interrupt. A fresh prompt's 'working' var write overrides 'done' right back.
  { key = 'Escape', mods = 'NONE', action = wezterm.action_callback(function(window, pane)
    local proc = pane:get_foreground_process_name() or ''
    local pid = pane:pane_id()
    local agent = agent_of_pane(pid, proc)
    if agent and agent_status_of(pid, pane:get_user_vars()) == 'working' then
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

-- Apps whose tab title should show the open FILE's basename instead of just the
-- cwd (e.g. " .zshrc" for a micro session editing ~/.zshrc). Editors/pagers
-- take a file path as an argument; we pull it from the process argv. Value is
-- unused (set membership only).
local APP_SHOWS_FILE = {
  micro=1, nano=1, vim=1, nvim=1, vi=1, hx=1, helix=1, emacs=1, bat=1, less=1, man=1,
}

-- Resolve the basename of the file a known editor has open, from its argv.
-- pane_id → mux pane → get_foreground_process_info().argv. Returns nil when the
-- API/info is unavailable or no file argument is present (e.g. `micro` with no
-- file), so the caller falls back to a cwd-only title. Picks the LAST non-flag
-- argv entry — editors put the file after any options, and if several files are
-- open the active/last one is the most useful label.
local function editor_open_file(pane_id)
  local argv = pane_argv(pane_id)
  for i = #argv, 2, -1 do  -- skip argv[1] (the program itself)
    local a = argv[i]
    if a and a ~= '' and a:sub(1, 1) ~= '-' then
      local base = a:gsub('[/\\]+$', ''):match('[^/\\]+$')
      if base and base ~= '' then return base end
    end
  end
  return nil
end

-- Spinner animation for "working" tabs. format-tab-title normally renders a
-- static ⬤ dot; while a claude pane reports status=working we twinkle Claude's
-- own star glyph in its place — the shape grows/shrinks (· → ✦ → ✳ → ✷ → …) and
-- the color pulses dim→bright, so it reads as a blinking Claude icon rather than
-- a generic spinner. WezTerm only repaints the tab bar on an invalidation (not a
-- timer), so the update-status handler forces a repaint while any pane is
-- working — ONLY then, so idle tabs don't churn repaints. WHICH frame gets drawn
-- is a pure function of the clock (see now_ms / GLYPH_MS), not of how many
-- repaints have happened.
--
-- Claude Code's own "working" spinner, replicated. Claude cycles a GROWING STAR
-- (not a rotation or color pulse): it eases up from a dot to a big asterisk and
-- back, ping-pong, over a 2000ms period with cosine timing. Glyphs (from the
-- Claude Code binary): · U+00B7, ✢ U+2722, ✳ U+2733, ✶ U+2736, ✻ U+273B,
-- ✽ U+273D. We list the forward ramp and mirror it in code for the ping-pong.
--
-- Each glyph carries a trailing \u{FE0E} (VARIATION SELECTOR-15) to force TEXT
-- presentation — bare ✳ would render as a green emoji that ignores our color.
-- With VS15 they're monochrome and obey the orange Foreground below.
--
-- Claude's TUI is monospace so its star can change width freely; our fancy tab
-- bar is proportional (Inter), so differing glyph widths would shift the title.
-- The marker is therefore rendered in a fixed-width wrapper (see format below).
-- Claude's ramp starts with · (U+00B7 middle dot), but in the proportional tab
-- font the dot is far narrower than the stars and its frame visibly shifted the
-- title. Dropped it: the remaining star-family glyphs are near-equal width, so
-- the grow/shrink still reads while the text barely moves.
--
-- Also dropped ✳ (U+2733): it has EMOJI presentation by default and our VS15
-- override doesn't stick in this wezterm build, so that one frame rendered as a
-- big green emoji star. The remaining glyphs are text-default and stay orange.
local SPINNER_RAMP = {
  '✢\u{FE0E}', '✶\u{FE0E}', '✻\u{FE0E}', '✽\u{FE0E}',
}

-- Working spinner color: a HUE CYCLE sweeping blue → teal → green and back,
-- deliberately different from the orange done/idle star so an in-progress tab is
-- unmistakable. The hue ramp is ping-ponged (blue→green then green→blue) for a
-- seamless loop, and stepped on its OWN period (see COLOR_MS) rather than the
-- glyph's — the two periods differ, so color drifts against size instead of
-- locking to it, giving a livelier shimmer.
local SPINNER_COLOR_RAMP = { '#4a7fd6', '#4aa6c8', '#3fb8a8', '#4fc785', '#63d46b' }

-- Animation periods, in MILLISECONDS PER STEP — the actual cadence you see,
-- because the indices below are computed from now_ms() rather than from a count
-- of update-status events (which fire ~24x/sec; see now_ms).
--
-- Claude Code's own spinner runs a ~2000ms grow/shrink cycle. Our ping-ponged
-- ramp is 6 frames, so 333ms/frame reproduces that period — about 3 steps/sec,
-- an unhurried pulse. COLOR_MS is deliberately NOT a divisor of GLYPH_MS so the
-- two cycles beat against each other instead of marching in lockstep.
local GLYPH_MS = 333
local COLOR_MS = 250
-- The title shimmer is a travelling band, not a blink, so it wants to be smooth:
-- fast enough to read as a sweep, slow enough not to strobe.
local SHIMMER_MS = 60

-- Index into a ping-ponged ramp for the current instant. Wall-clock derived, so
-- every window/tab showing the same agent animates in lockstep, and the cadence
-- holds no matter how often (or unevenly) the tab bar repaints.
local function frame_at(now, ramp, period_ms)
  return ramp[(math.floor(now / period_ms) % #ramp) + 1]
end

-- Ping-pong a ramp: 1..n then n-1..2, so it loops smoothly with no repeated peak.
local function pingpong(ramp)
  local out = {}
  for i = 1, #ramp do out[#out + 1] = ramp[i] end
  for i = #ramp - 1, 2, -1 do out[#out + 1] = ramp[i] end
  return out
end

-- Per-agent tab markers. COLOR encodes the STATE (in-progress hue cycle / idle /
-- red for needs-input) and is shared, so a red tab means the same thing whichever
-- agent it is; the GLYPH FAMILY encodes WHICH agent, so you can tell a Claude tab
-- from a Codex one at a glance:
--   claude — Claude's own growing star (✢✶✻✽), idle ❋, orange when idle
--   codex  — OpenAI's hexagon: outline ⬡ ↔ filled ⬢ pulse, idle ⬢, teal when idle
-- Every glyph carries VARIATION SELECTOR-15 (\u{FE0E}) to force TEXT presentation
-- — bare shapes in these blocks can render as emoji that ignore our color. All of
-- them come from Adwaita Mono, the third window_frame fallback (Inter and Hack
-- Nerd Font have none of these codepoints), same as the Claude stars always have.
--
-- Adding an agent = one entry here plus one line in agent_of_proc.
local AGENT_MARKERS = {
  claude = {
    idle       = '❋\u{FE0E}',  -- U+274B heavy eight-teardrop asterisk
    idle_fg    = '#C0623A',    -- claude orange (matches STATUS_STYLE.done)
    -- Needs input: a CHUNKIER star than idle — ✹ (U+2739, twelve-pointed filled
    -- black star) is denser than the ❋ outline, so the tab stands out twice over
    -- (shape + red).
    attention  = '✹\u{FE0E}',
    frames     = pingpong(SPINNER_RAMP),
    colors     = pingpong(SPINNER_COLOR_RAMP),
  },
  codex = {
    idle       = '⬢\u{FE0E}',  -- U+2B22 black hexagon — OpenAI's mark is hexagonal
    idle_fg    = '#10A37F',    -- OpenAI teal
    attention  = '⬣\u{FE0E}',  -- U+2B23 horizontal black hexagon: wider, denser
    -- Working: a diamond that grows AND fills — small solid ⬩, then medium
    -- outline ⬦, outline-with-core ◈, solid ⬥ — ping-ponged, so it swells and
    -- settles the way Claude's star does, in a different shape family.
    --
    -- All four are deliberately from the U+2B2x/U+25C8 set rather than the
    -- obvious ◆ ◇ (U+25C6/U+25C7): those two exist in Inter, which sits FIRST in
    -- the window_frame stack, so they'd resolve from a PROPORTIONAL font while
    -- their neighbours resolved from Adwaita Mono — different advance widths,
    -- and the title would visibly shift each frame. Every glyph below is absent
    -- from both Inter and Hack Nerd Font, so all four come from Adwaita Mono;
    -- being monospaced, it gives them one identical advance width. That's also
    -- why the small ⬩ frame is safe here, where Claude's ramp had to drop its
    -- narrow · (that one came from a proportional font).
    frames     = pingpong({ '⬩\u{FE0E}', '⬦\u{FE0E}', '◈\u{FE0E}', '⬥\u{FE0E}' }),
    -- Teal → mint, a hue cycle in Codex's own colour rather than Claude's blue→green,
    -- so even the working animation says which agent is running.
    colors     = pingpong({ '#0E8C6E', '#10A37F', '#1FBF93', '#45D6A8', '#6FE8C0' }),
  },
}

-- Title-text shimmer for "working" tabs. Claude Code shimmers its status text
-- (combobulating/lollygagging/…) with a bright band that sweeps across the
-- letters; we replicate it on the tab title. Each character is emitted as its
-- own colored run whose lightness is a cosine of (char_index - phase), so the
-- peak (a bright grey) travels left→right while the rest sits a shade dimmer.
-- The phase is derived from the clock (SHIMMER_MS per step) and only applied to
-- working tabs, so idle tabs render a flat title and don't churn repaints. The
-- band stays within the bright greys (dim floor well above black) so the title
-- never loses legibility — this is a subtle sheen, not a blink.

-- Grey between dim `lo` and bright `hi` (both 0..255) by t in [0,1]. `dither`
-- nudges the blue channel by ±0 (visually nothing) purely so that two adjacent
-- characters NEVER emit the exact same color string — see shimmer_runs.
local function shimmer_grey(lo, hi, t, dither)
  local v = math.floor(lo + (hi - lo) * t + 0.5)
  -- Subtract (never add): v can reach the 255 ceiling at the peak where adding
  -- would clamp and re-collide with a neighbour. v >= lo (>=0x8e) so v-1 is safe.
  local b = v - dither
  return string.format('#%02x%02x%02x', v, v, b)
end

-- Per-character colored runs for a shimmering title. Active tabs sweep brighter
-- (dimmer band is still legible); inactive/unfocused tabs use a lower ceiling so
-- they read as backgrounded, matching the rest of the dulled styling.
--
-- WezTerm coalesces adjacent runs that share identical styling, then shapes each
-- merged run as a unit — applying proportional kerning across the pair. Near the
-- cosine peak/trough the wave is flat, so neighbours would quantize to the SAME
-- grey and merge; as the band sweeps, WHICH neighbours merge changes each frame,
-- so the kerned pairs change and the title width jitters slightly. Defeat it by
-- dithering the blue channel with index parity: neighbours can never be byte-
-- identical, so every char stays its own run every frame → constant shaping, no
-- shift. The ±1 blue on a grey is imperceptible.
local function shimmer_runs(title, phase, is_active)
  local lo, hi = is_active and 0xcc or 0x8e, is_active and 0xff or 0xbe
  local runs = {}
  local i = 0
  for _, cp in utf8.codes(title) do
    local wave = (math.cos((i - phase) * 0.5) + 1) / 2  -- 0..1
    runs[#runs + 1] = { Foreground = { Color = shimmer_grey(lo, hi, wave, i % 2) } }
    runs[#runs + 1] = { Text = utf8.char(cp) }
    i = i + 1
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
  local agent = agent_of_pane(pane_info.pane_id, proc)
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
        -- just the cwd — no redundant "cwd: micro". For editors/pagers, show the
        -- open file's basename instead (" .zshrc"), falling back to cwd when no
        -- file arg is present.
        local file = APP_SHOWS_FILE[proc_name] and editor_open_file(pane_info.pane_id)
        title = file and (basename .. ': ' .. file) or basename
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
    local style = status and STATUS_STYLE[status]
    if status == 'working' then
      is_working = true
      -- Animate the agent's glyph with a synced color pulse — both glyph and
      -- color come from the current ping-pong frame, so the marker brightens as
      -- it animates. The working hue is deliberately not the idle hue, so an
      -- in-progress tab reads as in-progress even out of the corner of your eye.
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

  -- Truncate via the pure helper. window_cols comes from the mux (a stable input)
  -- — NOT the content-driven max_width param, which feeds back on itself. See the
  -- long note on compute_tab_title above.
  local mux_win = wezterm.mux.get_window(tab.window_id)
  local window_cols = mux_win and mux_win:active_tab():get_size().cols or 200
  title = compute_tab_title {
    title = title,
    marker = marker,
    ntabs = #tabs,
    window_cols = window_cols,
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
    -- Shimmering title: one colored run per char, bright band sweeps L→R.
    for _, run in ipairs(shimmer_runs(title, math.floor(now_ms() / SHIMMER_MS), is_active)) do
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
-- Subtlety that cost real debugging time: format-tab-title recomputing does NOT
-- repaint the GUI surface — wezterm calls it constantly (~8-24x/sec per window)
-- but the visible tab bar only updates on an explicit invalidation. The reliable
-- trigger is the window-config-reloaded event, which set_config_overrides emits
-- — but ONLY when the override values actually CHANGE. Re-setting an unchanged
-- table is silently a no-op (verified: zero reload events), so the title would
-- lag 1-2s until the next surface refresh and the just-blurred window often
-- wouldn't update at all. So we flip an override every focus change.
--
-- The reload→repaint round trip costs ~135ms regardless of WHICH override is
-- flipped (measured: identical for opacity vs this), so latency isn't the reason
-- for the choice. But the override must be visually INERT, else it adds its own
-- cost/flicker on top: foreground_text_hsb re-renders every glyph (the original
-- ~2s lag), window_background_opacity recomposites the translucent surface (risk
-- of a faint opacity flicker). status_update_interval only changes a timer
-- cadence — no glyph render, no recomposite, no possible visual — so flipping it
-- 1000<->1001 is the cleanest pure repaint trigger. ~135ms is the floor for this
-- approach; wezterm exposes no cheaper tab-bar invalidation. window-focus-changed
-- fires for both the losing and gaining window, so both tab bars repaint at once.
wezterm.on('window-focus-changed', function(window, pane)
  local focused = window:is_focused()
  window_focus[window:window_id()] = focused

  -- Flip the (inert) interval by 1ms to force a tab-bar repaint. Stay at the
  -- 200ms base so we don't change the spinner clock. See long note above re: why
  -- this specific override is the cheapest invalidation trigger.
  local overrides = window:get_config_overrides() or {}
  overrides.status_update_interval = focused and 200 or 201
  window:set_config_overrides(overrides)
end)

-- ---------- Working spinner animation ----------
-- Fires every status_update_interval ms. If any pane in any window reports
-- agent_status=working, advance the spinner frame and force a tab-bar
-- repaint so format-tab-title re-renders the new frame.
--
-- CRITICAL: the repaint is done with set_right_status, NOT set_config_overrides.
-- The override trick used by window-focus-changed forces a full CONFIG RELOAD
-- (~135ms) every call — fine for an occasional focus change, but at animation
-- cadence it made tab switches visibly laggy. set_right_status is WezTerm's
-- intended per-frame update path: it invalidates and repaints the tab bar (which
-- re-runs format-tab-title) cheaply, with no reload. We stash the frame in a
-- module global and write an (empty) right status purely to trigger the repaint.
wezterm.on('update-status', function(window, pane)
  -- Fires on a fixed interval whether or not anything is working, so it doubles
  -- as the clock the agent_of_pane cache expires against.
  status_tick = status_tick + 1

  local any_working = false
  for _, w in ipairs(wezterm.mux.all_windows()) do
    for _, tab in ipairs(w:tabs()) do
      for _, p in ipairs(tab:panes()) do
        local st = agent_status_of(p:pane_id(), p:get_user_vars())
        if st == 'working' then any_working = true; break end
      end
      if any_working then break end
    end
    if any_working then break end
  end

  if not any_working then
    -- Keep a constant zero-width payload even when idle: toggling between empty
    -- and non-empty adds/removes the right-status region and reflows the tab bar
    -- vertically (a 1-2px jitter every frame). Always-present, always zero-width
    -- = stable layout.
    window:set_right_status(wezterm.format({ { Text = '\u{200b}' } }))
    return
  end

  -- NOTE: no frame counters are advanced here. The glyph, its color and the title
  -- shimmer are all computed from now_ms() at render time (see GLYPH_MS /
  -- COLOR_MS / SHIMMER_MS), because this handler does NOT fire on a fixed
  -- interval — the invalidation below re-triggers it, so it runs at repaint rate
  -- (~24x/sec, measured). Advancing a frame per call made the animation run at
  -- that rate instead of the intended ~3 steps/sec. All this handler still owes
  -- the animation is a steady stream of repaints, which is what the status write
  -- below buys.
  --
  -- Alternate between two DIFFERENT zero-width chars (ZWSP U+200B / ZWNBSP
  -- U+FEFF) so the value changes each tick — an unchanged right status is a
  -- no-op and wouldn't repaint. Both are zero-width, so the region's size never
  -- changes and the tab bar doesn't shift. The chars are never visibly rendered;
  -- they exist only to invalidate the tab bar so format-tab-title re-runs.
  window:set_right_status(wezterm.format({ { Text = (status_tick % 2 == 0) and '\u{200b}' or '\u{feff}' } }))
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
