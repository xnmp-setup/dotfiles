-- Persistent background tabs backed by one unix mux domain per tab.
local wezterm = require 'wezterm'
local act = wezterm.action

local M = {}

function M.setup(config)
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

  return {
    socket_dir = BG_SOCK_DIR,
    spawn_tab = spawn_bg_tab,
    detach_tab = detach_bg_tab,
    reattach_tab = reattach_bg_tab,
  }
end

return M
