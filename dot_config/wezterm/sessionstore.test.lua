-- Tests for sessionstore.lua's capture. Run: lua sessionstore.test.lua
-- (from this directory, or `lua dot_config/wezterm/sessionstore.test.lua`).
--
-- sessionstore is the impure half, so it's exercised against a fake mux injected
-- through package.preload — plain tables with the handful of methods capture
-- calls. That fake counts the per-pane queries, which is the point: capture is
-- allowed to skip a query only when its answer could not have changed the file,
-- so every test below pairs a call count with a proof that the bytes are the
-- same as the naive walk would have produced.

package.path = (arg[0]:match('(.*/)') or './') .. '?.lua;' .. package.path

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    io.write(string.format('FAIL %s\n  got:  [%s]\n  want: [%s]\n', name, tostring(got), tostring(want)))
  end
end

-- ---------- deterministic JSON ----------
-- Stands in for wezterm.json_encode. Keys are sorted so two encodings of equal
-- states are byte-equal — without that, "the file didn't change" would be a
-- statement about table iteration order rather than about the session.
local encode
local function is_array(t)
  return #t > 0 or next(t) == nil
end
encode = function(v)
  local kind = type(v)
  if kind == 'nil' then return 'null' end
  if kind == 'number' or kind == 'boolean' then return tostring(v) end
  if kind == 'string' then return string.format('%q', v) end
  if is_array(v) then
    local parts = {}
    for _, item in ipairs(v) do parts[#parts + 1] = encode(item) end
    return '[' .. table.concat(parts, ',') .. ']'
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = string.format('%q:%s', k, encode(v[k])) end
  return '{' .. table.concat(parts, ',') .. '}'
end

-- ---------- fake mux ----------

local counts = { cwd = 0, domain = 0 }

-- spec: { { cols, rows, tabs = { { active, panes = { { domain, cwd, left, top,
--         width, height, active, zoomed } } } } } }
local function fake_windows(spec)
  local windows = {}
  for _, win in ipairs(spec) do
    local tabs = {}
    for _, tab in ipairs(win.tabs) do
      local infos = {}
      for _, p in ipairs(tab.panes) do
        infos[#infos + 1] = {
          left = p.left, top = p.top, width = p.width, height = p.height,
          is_active = p.active and true or false,
          is_zoomed = p.zoomed and true or false,
          pane = {
            get_domain_name = function() counts.domain = counts.domain + 1; return p.domain end,
            get_current_working_dir = function() counts.cwd = counts.cwd + 1; return p.cwd end,
          },
        }
      end
      tabs[#tabs + 1] = {
        is_active = tab.active and true or false,
        tab = {
          panes_with_info = function() return infos end,
          get_size = function() return { cols = win.cols, rows = win.rows } end,
          get_title = function() return tab.title or '' end,
        },
      }
    end
    windows[#windows + 1] = { tabs_with_info = function() return tabs end }
  end
  return windows
end

local mux_windows = {}

package.preload['wezterm'] = function()
  return {
    home_dir = '.',
    target_triple = 'x86_64-unknown-linux-gnu',
    json_encode = encode,
    json_parse = function() error('not used') end,
    log_error = function() end,
    background_child_process = function() end,
    on = function() end,
    mux = {
      all_windows = function() return mux_windows end,
      get_domain = function()
        return { is_spawnable = function() return true end }
      end,
    },
  }
end

local session = require('session')
local sessionstore = require('sessionstore')

-- A directory of our own: save() writes session.json and nothing else, and the
-- test needs a real successful write for the digest short-circuit to engage.
math.randomseed(os.time())
local dir = ((os.getenv('TMPDIR') or '/tmp'):gsub('/+$', ''))
  .. '/sessionstore-test-' .. os.time() .. '-' .. math.random(1, 1e6)
os.execute('mkdir -p ' .. dir)
local session_file = dir .. '/session.json'
sessionstore.setup { dir = dir }

local function saved_bytes()
  local fh = io.open(session_file, 'r')
  if not fh then return nil end
  local body = fh:read('*a')
  fh:close()
  return body
end

-- ---------- the oracle ----------
-- The pre-optimisation walk, verbatim: query every pane unconditionally, tag the
-- tab with the zoom flag, and let session.has_zoomed/sanitize sort it out
-- afterwards. Every assertion about the new capture is an assertion that it
-- lands on the same file this would have.
local function capture_v0()
  local windows = {}
  for _, mux_win in ipairs(mux_windows) do
    local tabs, size = {}, nil
    for _, tab_info in ipairs(mux_win:tabs_with_info()) do
      local panes, zoomed = {}, false
      for _, pane_info in ipairs(tab_info.tab:panes_with_info()) do
        if pane_info.is_zoomed then zoomed = true end
        local p = pane_info.pane
        panes[#panes + 1] = {
          cwd = session.normalize_cwd(p:get_current_working_dir()),
          domain = p:get_domain_name(),
          left = pane_info.left, top = pane_info.top,
          width = pane_info.width, height = pane_info.height,
          active = pane_info.is_active,
        }
      end
      size = size or tab_info.tab:get_size()
      tabs[#tabs + 1] = { panes = panes, active = tab_info.is_active, zoomed = zoomed }
    end
    windows[#windows + 1] = { tabs = tabs, cols = size and size.cols, rows = size and size.rows }
  end
  return { windows = windows }
end

-- What the oracle would have persisted, or nil if it would have skipped the save.
local function expected_bytes()
  local raw = capture_v0()
  if session.has_zoomed(raw) then return nil end
  local state = session.sanitize(raw)
  if session.is_empty(state) then return nil end
  return encode(state), session.digest(state)
end

local function use(spec)
  mux_windows = fake_windows(spec)
  counts.cwd, counts.domain = 0, 0
end

-- ---------- fixture ----------
-- Two windows. The first mixes a foreground split with a background pane (the
-- bg-N unix domains the config uses for its background tabs) and holds a tab
-- that is entirely background; the second is plain. Between them they cover
-- every branch sanitize can take on a real capture.
local function mixed_spec()
  return {
    { cols = 120, rows = 40, tabs = {
      { active = true, panes = {
        { domain = 'local', cwd = '/home/chong', left = 0, top = 0, width = 59, height = 40, active = true },
        { domain = 'bg-1', cwd = '/srv/build', left = 60, top = 0, width = 60, height = 19 },
        { domain = 'local', cwd = '/etc', left = 60, top = 20, width = 60, height = 20 },
      } },
      { panes = {
        { domain = 'bg-2', cwd = '/var/log', left = 0, top = 0, width = 120, height = 40, active = true },
      } },
    } },
    { cols = 80, rows = 24, tabs = {
      { active = true, panes = {
        { domain = 'local', cwd = '/tmp', left = 0, top = 0, width = 80, height = 24, active = true },
      } },
    } },
  }
end

-- 1. The background panes cost a domain query each and no cwd query at all, and
--    the file is exactly what the unconditional walk would have written.
do
  use(mixed_spec())
  local want, want_digest = expected_bytes()
  counts.cwd, counts.domain = 0, 0

  sessionstore.save()
  eq('mixed/domain-queried-per-pane', counts.domain, 5)
  eq('mixed/cwd-skipped-for-bg', counts.cwd, 3)
  eq('mixed/bytes-identical', saved_bytes(), want)

  -- Same mux state, so the digest must short-circuit the second save; if capture
  -- had drifted from the oracle the digest would differ and it would rewrite.
  local state = session.sanitize(capture_v0())
  eq('mixed/digest-matches-oracle', session.digest(state), want_digest)
  counts.cwd = 0
  sessionstore.save()
  eq('mixed/resave-still-queries', counts.cwd, 3)
  eq('mixed/resave-bytes-unchanged', saved_bytes(), want)
end

-- 2. A zoomed pane anywhere abandons the capture before a single cwd is asked
--    for — including in the window walked before it — and the previous good save
--    stays on disk untouched.
do
  local good = saved_bytes()
  local spec = mixed_spec()
  spec[2].tabs[1].panes[1].zoomed = true
  use(spec)
  eq('zoom/oracle-also-skips', expected_bytes(), nil)
  counts.cwd, counts.domain = 0, 0

  sessionstore.save()
  eq('zoom/no-cwd-queries', counts.cwd, 0)
  eq('zoom/no-domain-queries', counts.domain, 0)
  eq('zoom/last-good-save-survives', saved_bytes(), good)
end

-- 3. An all-background mux sanitizes to nothing, so the save is declined and the
--    last good file survives — the same outcome as before, now without a single
--    cwd round trip.
do
  local good = saved_bytes()
  use({ { cols = 80, rows = 24, tabs = { { active = true, panes = {
    { domain = 'bg-1', cwd = '/srv', left = 0, top = 0, width = 80, height = 24, active = true },
  } } } } })
  eq('all-bg/oracle-skips', expected_bytes(), nil)
  counts.cwd = 0

  sessionstore.save()
  eq('all-bg/no-cwd-queries', counts.cwd, 0)
  eq('all-bg/last-good-save-survives', saved_bytes(), good)
end

-- 4. A pane whose cwd is unusable is still dropped by sanitize, so asking for it
--    was not wasted — the query has to happen to know.
do
  use({ { cols = 80, rows = 24, tabs = { { active = true, panes = {
    { domain = 'local', cwd = nil, left = 0, top = 0, width = 39, height = 24, active = true },
    { domain = 'local', cwd = '/opt', left = 40, top = 0, width = 40, height = 24 },
  } } } } })
  local want = expected_bytes()
  counts.cwd = 0

  sessionstore.save()
  eq('no-cwd/queried-anyway', counts.cwd, 2)
  eq('no-cwd/bytes-identical', saved_bytes(), want)
end

-- 5. Single-tab capture reuses the same filtering and preserves only a
-- caller-provided, sanitize-validated resume command.
do
  local resume = { 'claude', '--resume', '12345678-1234-4abc-9def-1234567890ab' }
  use({ { cols = 80, rows = 24, tabs = { { active = true, title = 'agent', panes = {
    { domain = 'local', cwd = '/repo', left = 0, top = 0, width = 39, height = 24, active = true },
    { domain = 'bg-1', cwd = '/ignored', left = 40, top = 0, width = 40, height = 24 },
  } } } } })
  local live_tab = mux_windows[1]:tabs_with_info()[1].tab
  local captured = sessionstore.capture_tab(live_tab, function() return resume end)
  eq('single/title', captured.title, 'agent')
  eq('single/background pane dropped', #captured.panes, 1)
  eq('single/resume args retained', table.concat(captured.panes[1].args, ' '), table.concat(resume, ' '))
  eq('single/cwd skipped for background', counts.cwd, 1)

  use({ { cols = 80, rows = 24, tabs = { { active = true, panes = {
    { domain = 'local', cwd = '/repo', left = 0, top = 0, width = 80, height = 24,
      active = true, zoomed = true },
  } } } } })
  live_tab = mux_windows[1]:tabs_with_info()[1].tab
  local skipped, reason = sessionstore.capture_tab(live_tab)
  eq('single/zoom skipped', skipped, nil)
  eq('single/zoom reason', reason, 'zoomed pane')
  eq('single/zoom avoids domain query', counts.domain, 0)
  eq('single/zoom avoids cwd query', counts.cwd, 0)
end

-- 6. Single-tab restore applies resume argv only to the decorated pane, rebuilds
-- the split, restores focus/title, and returns the new active pane to callers.
do
  local spawned_args, split_args, activated_tab, title = nil, nil, false, nil
  local base_pane = {
    id = 'base',
    split = function(_, args)
      split_args = args
      return { id = 'split', activate = function(self) self.activated = true end }
    end,
    activate = function(self) self.activated = true end,
  }
  local new_tab = {
    activate = function() activated_tab = true end,
    set_title = function(_, value) title = value end,
  }
  local target_window = {
    spawn_tab = function(_, args)
      spawned_args = args
      return new_tab, base_pane
    end,
  }
  local snapshot = session.sanitize({ windows = { { tabs = { {
    active = true,
    title = 'restored agent',
    panes = {
      { cwd = '/repo', domain = 'local', left = 0, top = 0, width = 39, height = 24,
        args = { 'codex', 'resume', '12345678-1234-4abc-9def-1234567890ab' } },
      { cwd = '/repo/docs', domain = 'local', left = 40, top = 0, width = 40, height = 24,
        active = true },
    },
  } } } } }, { preserve_resume_args = true }).windows[1].tabs[1]

  local restored_tab, active_pane = sessionstore.restore_tab(target_window, snapshot)
  eq('restore-single/tab returned', restored_tab, new_tab)
  eq('restore-single/base cwd', spawned_args.cwd, '/repo')
  eq('restore-single/base resume command', table.concat(spawned_args.args, ' '),
    'codex resume 12345678-1234-4abc-9def-1234567890ab')
  eq('restore-single/split cwd', split_args.cwd, '/repo/docs')
  eq('restore-single/plain split is shell', split_args.args, nil)
  eq('restore-single/active pane returned', active_pane.id, 'split')
  eq('restore-single/title', title, 'restored agent')
  eq('restore-single/tab activated', activated_tab, true)
end

os.remove(session_file)
os.execute('rmdir ' .. dir)

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
