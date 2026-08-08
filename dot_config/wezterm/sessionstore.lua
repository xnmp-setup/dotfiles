-- Session persistence for the wezterm config: capture the live layout, write it
-- to disk, and rebuild it on next launch. Chrome-style — you quit, you reopen,
-- your windows and tabs are where you left them.
--
-- This is the IMPURE half. Everything that reasons about state shape or split
-- geometry lives in session.lua, which is pure and unit-tested (session.test.lua);
-- this module is the adapter that talks to the wezterm mux and the filesystem.
--
-- Usage from wezterm.lua:
--
--   require('sessionstore').setup { dir = SOME_DIR }
--
-- What comes back: every window (at its old size), its tabs in order, each tab's
-- split layout, and each pane's cwd — with the previously focused tab and pane
-- refocused.
--
-- What does NOT come back, deliberately: the programs that were running. A
-- terminal's analogue of "reload the page" is re-running a command, and silently
-- re-executing whatever was in each pane at quit (a build, a migration, an rm)
-- is not something to do behind the user's back. Panes come back as fresh shells
-- in the right directory. Scrollback isn't restored either — it would mean
-- writing every pane's visible output to a plaintext file on disk, which is the
-- known footgun of this feature elsewhere in the ecosystem.
--
-- Background tabs (bg-N unix domains) are excluded — they already outlive the
-- GUI in their own mux-server, so restoring them would spawn a duplicate shell
-- beside the still-running one. session.sanitize does that filtering.

local wezterm = require('wezterm')
local session = require('session')

local M = {}

-- Defaults; setup() may override the directory.
local session_dir = wezterm.home_dir .. '/.local/share/wezterm'
local session_file = session_dir .. '/session.json'
local restored_local_domain = nil

-- Floor on how often the layout is written. WezTerm has no "about to quit" hook,
-- so the saved state is only ever this stale — the tradeoff is between losing a
-- late change and rewriting the file constantly.
local SAVE_INTERVAL = 10  -- seconds

local last_digest = nil
local last_save = 0

-- ---------- capture ----------

-- Capture runs in two passes because the per-pane queries are not all the same
-- price. tabs_with_info/panes_with_info are local and hand over geometry, focus
-- and is_zoomed for free; get_domain_name and especially get_current_working_dir
-- are per-pane calls that, for a pane living in a bg-N unix domain, cross a
-- socket to that mux-server and block the GUI thread while they do. So the first
-- pass collects only free information and gives anything that can veto a query a
-- chance to run before one is issued.

-- Pass one: the mux handles, plus the zoom veto.
--
-- A zoomed pane reports the whole tab's size while its siblings keep theirs, so
-- the rectangles overlap and describe no real layout; the save is skipped and the
-- last good one kept. (Measured; see session.lua.) Returning nil here means not
-- one cwd is asked for on the way to discovering that — including in windows
-- walked before the zoomed one.
local function scan_tab(tab)
  local pane_infos = tab:panes_with_info()
  for _, pane_info in ipairs(pane_infos) do
    if pane_info.is_zoomed then return nil end
  end
  return pane_infos
end

local function scan()
  local windows = {}
  for _, mux_win in ipairs(wezterm.mux.all_windows()) do
    local tabs = {}
    for _, tab_info in ipairs(mux_win:tabs_with_info()) do
      local pane_infos = scan_tab(tab_info.tab)
      if not pane_infos then return nil end
      tabs[#tabs + 1] = { tab = tab_info.tab, active = tab_info.is_active, panes = pane_infos }
    end
    windows[#windows + 1] = tabs
  end
  return windows
end

-- Query a scanned set of panes. `resume_args_for` is deliberately optional:
-- periodic session persistence restores only shells, while the in-memory
-- recently-closed stack may decorate recognized coding-agent panes with a safe
-- resume argv. A broken decorator cannot prevent the tab layout being saved.
local function capture_panes(pane_infos, resume_args_for)
  local panes = {}
  for _, pane_info in ipairs(pane_infos) do
    local p = pane_info.pane
    -- Domain first, cwd only for panes that will survive sanitize. A background
    -- pane is dropped whatever its cwd, and that cwd query crosses a mux socket.
    local domain = p:get_domain_name()
    if session.is_restorable_domain(domain) then
      local pane_state = {
        cwd = session.normalize_cwd(p:get_current_working_dir()),
        domain = domain,
        left = pane_info.left, top = pane_info.top,
        width = pane_info.width, height = pane_info.height,
        active = pane_info.is_active,
      }
      if resume_args_for then
        local ok, args = pcall(resume_args_for, p)
        if ok then pane_state.args = args end
      end
      panes[#panes + 1] = pane_state
    end
  end
  return panes
end

-- Pass two: the queries, into a plain state table (shape documented in
-- session.lua). Returns nil when the scan declined.
local function capture()
  local scanned = scan()
  if not scanned then return nil end
  local windows = {}
  for _, win_tabs in ipairs(scanned) do
    local tabs, size = {}, nil
    for _, tab in ipairs(win_tabs) do
      local panes = capture_panes(tab.panes)
      size = size or tab.tab:get_size()
      tabs[#tabs + 1] = { panes = panes, active = tab.active }
    end
    windows[#windows + 1] = {
      tabs = tabs,
      cols = size and size.cols,
      rows = size and size.rows,
    }
  end
  return { windows = windows }
end

-- Capture one live tab for browser-style reopen. The result is plain data, so
-- it is safe to retain in wezterm.GLOBAL across a configuration reload.
function M.capture_tab(tab, resume_args_for)
  if not tab then return nil, 'missing tab' end
  local pane_infos = scan_tab(tab)
  if not pane_infos then return nil, 'zoomed pane' end

  local title
  local got_title, value = pcall(function() return tab:get_title() end)
  if got_title and type(value) == 'string' and value ~= '' then title = value end

  local state = session.sanitize({ windows = { { tabs = { {
    active = true,
    title = title,
    panes = capture_panes(pane_infos, resume_args_for),
  } } } } }, { preserve_resume_args = true })
  if session.is_empty(state) then return nil, 'no restorable panes' end
  return state.windows[1].tabs[1]
end

-- ---------- save ----------

-- Lua has no mkdir, so the directory is created out-of-process, once, and only
-- after a write has actually failed — the common case (it already exists) costs
-- nothing. The failed save isn't retried here; the next tick picks it up.
local session_dir_created = false
local function ensure_dir()
  if session_dir_created then return end
  session_dir_created = true
  if wezterm.target_triple:find('windows') then
    wezterm.background_child_process({ 'cmd', '/c', 'mkdir', (session_dir:gsub('/', '\\')) })
  else
    wezterm.background_child_process({ 'mkdir', '-p', session_dir })
  end
end

local function write(state)
  local encoded = wezterm.json_encode(state)
  -- Write-then-rename: a crash or a power cut mid-write can otherwise leave a
  -- truncated file that fails to parse, losing the session it was meant to save.
  local tmp = session_file .. '.tmp'
  local fh = io.open(tmp, 'w')
  if not fh then
    ensure_dir()
    return false
  end
  fh:write(encoded)
  fh:close()
  -- POSIX rename replaces atomically; Windows refuses when the target exists, so
  -- only there do we drop the old file first (and give up atomicity).
  if not os.rename(tmp, session_file) then
    os.remove(session_file)
    if not os.rename(tmp, session_file) then
      os.remove(tmp)
      return false
    end
  end
  return true
end

-- Capture and persist, unless nothing changed or the capture isn't trustworthy.
-- Exposed for tests/manual use; setup() calls it on a throttle.
function M.save()
  local raw = capture()
  -- nil means the capture wasn't trustworthy (zoom; see scan()) — keep the last
  -- good save rather than persist over it.
  if not raw then return end
  local state = session.sanitize(raw)
  -- Never replace a real session with an empty one. During teardown the mux can
  -- briefly report no windows, and that's exactly when the file must survive.
  if session.is_empty(state) then return end
  local digest = session.digest(state)
  if digest == last_digest then return end
  if write(state) then last_digest = digest end
end

-- ---------- restore ----------

-- Domains that can't be spawned into (a dead SSH host, a mux-server that's gone)
-- would abort the restore. Panes in one fall back to the default domain instead,
-- so a stale domain costs you that pane's domain, not the whole session.
local function domain_is_spawnable(name)
  if type(name) ~= 'string' or name == '' then return false end
  local ok, domain = pcall(wezterm.mux.get_domain, name)
  if not ok or not domain then return false end
  local ok_spawn, spawnable = pcall(function() return domain:is_spawnable() end)
  return ok_spawn and spawnable or false
end

local function spawn_args_for(pane_state)
  local args = { cwd = pane_state.cwd }
  if pane_state.args then args.args = pane_state.args end
  -- Existing Linux snapshots name the built-in local domain. When pane
  -- scheduling is enabled, migrate those panes into its ExecDomain on restore;
  -- otherwise they would inherit the high-priority GUI scope indefinitely.
  local domain_name = pane_state.domain
  if domain_name == 'local' and restored_local_domain then
    domain_name = restored_local_domain
  end
  if domain_is_spawnable(domain_name) then
    args.domain = { DomainName = domain_name }
  end
  return args
end

-- Rebuild one tab's splits around the pane it was spawned with. Each split is
-- individually pcall'd: one pane failing to spawn costs that pane, not the tab.
local function restore_tab_panes(base_pane, tab_state, plan)
  local panes = { [plan.base] = base_pane }
  for _, op in ipairs(plan.ops) do
    local from = panes[op.from]
    local target = tab_state.panes[op.new]
    if from and target then
      local args = spawn_args_for(target)
      args.direction = op.direction
      args.size = op.size
      local ok, new_pane = pcall(function() return from:split(args) end)
      if ok and new_pane then panes[op.new] = new_pane end
    end
  end
  local active_pane = base_pane
  for i, p in ipairs(tab_state.panes) do
    if p.active and panes[i] then
      active_pane = panes[i]
      active_pane:activate()
    end
  end
  return active_pane
end

local function finish_restored_tab(tab, pane, tab_state, plan)
  local active_pane = restore_tab_panes(pane, tab_state, plan)
  if tab_state.title then pcall(function() tab:set_title(tab_state.title) end) end
  return active_pane
end

-- Restore one captured tab into an existing mux window. Returns the new tab and
-- focused pane, or nil plus an error. The base spawn is atomic; split failures
-- degrade to the panes that did restore, matching full-session restoration.
function M.restore_tab(mux_win, tab_state)
  if not mux_win or type(tab_state) ~= 'table' or #(tab_state.panes or {}) == 0 then
    return nil, 'invalid tab snapshot'
  end
  local sanitized = session.sanitize(
    { windows = { { tabs = { tab_state } } } },
    { preserve_resume_args = true }
  )
  if session.is_empty(sanitized) then return nil, 'invalid tab snapshot' end
  tab_state = sanitized.windows[1].tabs[1]
  local plan = session.split_plan(tab_state.panes)
  local base_state = tab_state.panes[plan.base or 1]
  local ok, tab, pane = pcall(function()
    local spawned_tab, spawned_pane = mux_win:spawn_tab(spawn_args_for(base_state))
    return spawned_tab, spawned_pane
  end)
  if not ok or not tab or not pane then return nil, ok and 'tab spawn failed' or tab end
  local active_pane = finish_restored_tab(tab, pane, tab_state, plan)
  tab:activate()
  return tab, active_pane
end

local function read()
  local fh = io.open(session_file, 'r')
  if not fh then return nil end
  local encoded = fh:read('*a')
  fh:close()
  if not encoded or encoded == '' then return nil end
  local ok, state = pcall(wezterm.json_parse, encoded)
  if not ok or type(state) ~= 'table' then return nil end
  return session.sanitize(state)
end

-- Rebuild the saved session. Returns true if anything was restored, so the
-- caller can tell "nothing to restore" from "restored".
function M.restore()
  local state = read()
  if not state or session.is_empty(state) then return false end

  for _, win in ipairs(state.windows) do
    local mux_win
    for i, tab_state in ipairs(win.tabs) do
      local plan = session.split_plan(tab_state.panes)
      -- The tab is spawned with the cwd of the pane the plan splits FROM, which
      -- is the top-left one — not necessarily the first in capture order.
      local base_state = tab_state.panes[plan.base or 1]
      local args = spawn_args_for(base_state)
      local tab, pane
      if i == 1 then
        -- Restoring the window's size here (in cells) is cheaper and more
        -- reliable than resizing the GUI window afterwards; under a tiling WM
        -- like Hyprland it's ignored, which is correct — the WM owns geometry.
        args.width = win.cols
        args.height = win.rows
        tab, pane, mux_win = wezterm.mux.spawn_window(args)
      else
        tab, pane = mux_win:spawn_tab(args)
      end
      finish_restored_tab(tab, pane, tab_state, plan)
      if tab_state.active then tab:activate() end
    end
  end
  -- Seed the digest so the first tick after startup doesn't rewrite an identical
  -- file; real drift (the restored geometry rounding differently) still saves.
  last_digest = session.digest(state)
  return true
end

-- ---------- wiring ----------

-- opts.dir: directory to hold session.json (defaults to ~/.local/share/wezterm).
-- opts.local_domain: replacement domain for legacy snapshots named "local".
-- opts.session_restore: whole-session persistence, on by default. Setting it to
--   false registers neither handler, so a launch is a plain default window (one
--   tab, cwd resolved by wezterm's own rules) and nothing is written to disk.
--   capture_tab/restore_tab are unaffected — the recently-closed-tab stack keeps
--   working, since it snapshots in memory on close rather than on a timer.
function M.setup(opts)
  opts = opts or {}
  if opts.dir then
    session_dir = opts.dir
    session_file = session_dir .. '/session.json'
  end
  if opts.save_interval then SAVE_INTERVAL = opts.save_interval end
  restored_local_domain = opts.local_domain
  if opts.session_restore == false then return end

  -- gui-startup fires once, before the default window is spawned. Creating panes
  -- here suppresses that default window; creating none lets it happen as usual —
  -- which is exactly the fallback we want when there's nothing to restore.
  --
  -- The whole restore is wrapped: a failure here would otherwise mean a terminal
  -- that won't open. On error we spawn nothing, so wezterm falls back to a plain
  -- default window and the failure is a log line rather than a broken launch.
  wezterm.on('gui-startup', function(cmd)
    -- `wezterm start -- some-program` asked for something specific; honour it by
    -- creating nothing and letting wezterm spawn that program itself.
    if cmd then return end
    local ok, err = pcall(M.restore)
    if not ok then
      wezterm.log_error('session restore failed: ' .. tostring(err))
    end
  end)

  -- Saving rides the update-status tick rather than its own timer. resurrect
  -- uses a self-rescheduling wezterm.time.call_after chain, but that starts at
  -- config-load time, so every ctrl+shift+, reload would start another chain
  -- alongside the old one. Event handlers are re-registered by a reload instead
  -- of accumulating. wezterm supports multiple handlers per event, so this is
  -- additive to the tab-bar handler in wezterm.lua and doesn't touch the right
  -- status. The throttle keeps the actual capture to once per SAVE_INTERVAL
  -- rather than once per 200ms frame.
  wezterm.on('update-status', function()
    local now = os.time()
    if now - last_save < SAVE_INTERVAL then return end
    last_save = now
    local ok, err = pcall(M.save)
    if not ok then wezterm.log_error('session save failed: ' .. tostring(err)) end
  end)
end

return M
