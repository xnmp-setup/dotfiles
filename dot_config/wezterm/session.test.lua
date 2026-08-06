-- Tests for session.lua. Run: lua session.test.lua
-- (from this directory, or `lua dot_config/wezterm/session.test.lua`).
-- No wezterm needed — the module is pure and only sees plain tables.

package.path = (arg[0]:match('(.*/)') or './') .. '?.lua;' .. package.path
local session = require('session')

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    io.write(string.format('FAIL %s\n  got:  [%s]\n  want: [%s]\n', name, tostring(got), tostring(want)))
  end
end
local function ok(name, cond, detail)
  eq(name, cond and true or false, true)
  if not cond and detail then io.write('  ' .. detail .. '\n') end
end

-- ---------- Layout simulator ----------
-- Replays a plan the way wezterm would: start with the base pane filling the
-- tab, then apply each split. Adjacent panes are separated by a one-cell
-- divider, and `size` is the fraction of the pane handed to the NEW pane.
-- Asserting the replayed rectangles match the captured ones tests the contract
-- (the layout comes back) rather than the shape of the plan.
local function bbox(panes)
  local l, t, r, b = math.huge, math.huge, -math.huge, -math.huge
  for _, p in ipairs(panes) do
    l = math.min(l, p.left); t = math.min(t, p.top)
    r = math.max(r, p.left + p.width); b = math.max(b, p.top + p.height)
  end
  return l, t, r, b
end

local function simulate(panes, plan)
  local l, t, r, b = bbox(panes)
  local rect = {}
  rect[plan.base] = { left = l, top = t, width = r - l, height = b - t }
  for _, op in ipairs(plan.ops) do
    local f = rect[op.from]
    if not f then return nil, 'op splits pane ' .. op.from .. ' which does not exist yet' end
    if rect[op.new] then return nil, 'pane ' .. op.new .. ' created twice' end
    if op.direction == 'Right' then
      local usable = f.width - 1
      local nw = math.floor(usable * op.size + 0.5)
      local fw = usable - nw
      rect[op.new] = { left = f.left + fw + 1, top = f.top, width = nw, height = f.height }
      f.width = fw
    else
      local usable = f.height - 1
      local nh = math.floor(usable * op.size + 0.5)
      local fh = usable - nh
      rect[op.new] = { left = f.left, top = f.top + fh + 1, width = f.width, height = nh }
      f.height = fh
    end
  end
  return rect
end

-- Every captured pane is reproduced within `tol` cells on every edge.
local function layout_matches(panes, tol)
  local plan = session.split_plan(panes)
  local rect, err = simulate(panes, plan)
  if not rect then return false, err end
  for i, p in ipairs(panes) do
    local g = rect[i]
    if not g then return false, 'pane ' .. i .. ' never created' end
    for _, f in ipairs({ 'left', 'top', 'width', 'height' }) do
      if math.abs(g[f] - p[f]) > (tol or 1) then
        return false, string.format('pane %d %s: got %d want %d', i, f, g[f], p[f])
      end
    end
  end
  return true
end

local function pane(left, top, width, height, extra)
  local p = { left = left, top = top, width = width, height = height,
              cwd = '/tmp', domain = 'local' }
  for k, v in pairs(extra or {}) do p[k] = v end
  return p
end

-- ---------- split_plan ----------

-- 1. A lone pane is the base and needs no splits at all.
do
  local plan = session.split_plan({ pane(0, 0, 80, 24) })
  eq('single/base', plan.base, 1)
  eq('single/no-ops', #plan.ops, 0)
end

-- 2. Two side by side: one vertical split, each taking about half.
do
  local panes = { pane(0, 0, 40, 24), pane(41, 0, 40, 24) }
  local plan = session.split_plan(panes)
  eq('two-cols/ops', #plan.ops, 1)
  eq('two-cols/direction', plan.ops[1].direction, 'Right')
  ok('two-cols/half', math.abs(plan.ops[1].size - 0.5) < 0.02)
  ok('two-cols/layout', layout_matches(panes))
end

-- 3. Two stacked: same, but horizontal.
do
  local panes = { pane(0, 0, 80, 12), pane(0, 13, 80, 12) }
  local plan = session.split_plan(panes)
  eq('two-rows/ops', #plan.ops, 1)
  eq('two-rows/direction', plan.ops[1].direction, 'Bottom')
  ok('two-rows/layout', layout_matches(panes))
end

-- 4. THE GRID REGRESSION. resurrect's adjacency tree consumes the bottom-right
--    pane twice (5 nodes for 4 panes) and always splits bottom-before-right, so
--    a 2x2 grid restores as three uneven rows plus a spurious pane. Assert both
--    the pane count and the actual geometry.
do
  local panes = {
    pane(0, 0, 40, 10), pane(41, 0, 40, 10),
    pane(0, 11, 40, 10), pane(41, 11, 40, 10),
  }
  local plan = session.split_plan(panes)
  eq('grid/ops', #plan.ops, 3)  -- n panes => n-1 splits, never more
  local good, err = layout_matches(panes)
  ok('grid/layout', good, err)
end

-- 5. A bottom pane spanning the FULL width under two columns. This is the case
--    that needs the horizontal cut to come first — cut the other way and the
--    bottom pane ends up under only one column.
do
  local panes = { pane(0, 0, 40, 10), pane(41, 0, 40, 10), pane(0, 11, 81, 10) }
  local plan = session.split_plan(panes)
  eq('full-width-bottom/first-cut', plan.ops[1].direction, 'Bottom')
  local good, err = layout_matches(panes)
  ok('full-width-bottom/layout', good, err)
end

-- 6. Full-height left column beside a stacked right column — the mirror of 5,
--    and here the vertical cut must come first.
do
  local panes = { pane(0, 0, 40, 21), pane(41, 0, 40, 10), pane(41, 11, 40, 10) }
  local plan = session.split_plan(panes)
  eq('left-col/first-cut', plan.ops[1].direction, 'Right')
  local good, err = layout_matches(panes)
  ok('left-col/layout', good, err)
end

-- 7. Every pane is created exactly once — no duplicates, none missing. This is
--    the invariant resurrect's tree violates, asserted directly.
do
  local layouts = {
    { pane(0, 0, 40, 10), pane(41, 0, 40, 10), pane(0, 11, 40, 10), pane(41, 11, 40, 10) },
    { pane(0, 0, 26, 24), pane(27, 0, 26, 24), pane(54, 0, 26, 24) },
    { pane(0, 0, 80, 8), pane(0, 9, 39, 14), pane(40, 9, 40, 14) },
  }
  for li, panes in ipairs(layouts) do
    local plan = session.split_plan(panes)
    local seen = {}
    seen[plan.base] = 1
    for _, op in ipairs(plan.ops) do
      seen[op.new] = (seen[op.new] or 0) + 1
    end
    local all_once = true
    for i = 1, #panes do
      if seen[i] ~= 1 then all_once = false end
    end
    ok('exactly-once/layout' .. li, all_once)
    ok('exactly-once/geometry' .. li, (layout_matches(panes)))
  end
end

-- 8. Deterministic: the same input yields an identical plan every time, so a
--    restore is reproducible (and the digest-based save skip stays meaningful).
do
  local panes = { pane(0, 0, 40, 10), pane(41, 0, 40, 10), pane(0, 11, 81, 10) }
  local a, b = session.split_plan(panes), session.split_plan(panes)
  local function encode(plan)
    local s = { 'base=' .. tostring(plan.base) }
    for _, o in ipairs(plan.ops) do
      s[#s + 1] = string.format('%d>%d %s %.4f', o.from, o.new, o.direction, o.size)
    end
    return table.concat(s, ';')
  end
  eq('deterministic', encode(a), encode(b))
end

-- 9. A pinwheel has no clean separating line anywhere. The plan must still cover
--    every pane (degraded shape is fine, a crash or a lost pane is not).
do
  local panes = {
    pane(0, 0, 40, 10), pane(41, 0, 39, 16),
    pane(0, 11, 26, 13), pane(27, 17, 53, 7),
  }
  local okk, plan = pcall(session.split_plan, panes)
  ok('pinwheel/no-crash', okk)
  if okk then
    local seen = { [plan.base] = true }
    for _, op in ipairs(plan.ops) do seen[op.new] = true end
    local covered = true
    for i = 1, #panes do if not seen[i] then covered = false end end
    ok('pinwheel/all-panes-present', covered)
  end
end

-- 10. Zero panes is not a crash (a tab can be captured mid-teardown).
do
  local plan = session.split_plan({})
  eq('empty/base', plan.base, nil)
  eq('empty/ops', #plan.ops, 0)
end

-- ---------- normalize_cwd ----------

eq('cwd/url-object', session.normalize_cwd({ file_path = '/home/chong/src' }), '/home/chong/src')
eq('cwd/legacy-string', session.normalize_cwd('file://arch/home/chong/src'), '/home/chong/src')
eq('cwd/percent-decoded',
   session.normalize_cwd({ path = '/home/chong/my%20dir' }), '/home/chong/my dir')
-- file_path is nil when the OSC-7 host isn't local; fall back to .path.
eq('cwd/empty-file_path-falls-back',
   session.normalize_cwd({ file_path = '', path = '/srv/app' }), '/srv/app')
eq('cwd/trailing-slash', session.normalize_cwd({ file_path = '/home/chong/' }), '/home/chong')
eq('cwd/root-survives', session.normalize_cwd({ file_path = '/' }), '/')
eq('cwd/nil', session.normalize_cwd(nil), nil)
eq('cwd/unusable', session.normalize_cwd({ file_path = '', path = '' }), nil)
-- Windows: wezterm reports "/C:/Users/..."; the leading slash must go or the
-- path is rejected as a spawn cwd.
eq('cwd/windows-drive',
   session.normalize_cwd({ file_path = '/C:/Users/chong' }), 'C:/Users/chong')

-- ---------- domain filtering ----------

eq('domain/local', session.is_restorable_domain('local'), true)
eq('domain/wsl', session.is_restorable_domain('WSL:Ubuntu-24.04'), true)
eq('domain/bg', session.is_restorable_domain('bg-1'), false)
eq('domain/bg-multi-digit', session.is_restorable_domain('bg-12'), false)
eq('domain/empty', session.is_restorable_domain(''), false)
eq('domain/nil', session.is_restorable_domain(nil), false)

-- ---------- sanitize ----------

-- 11. Background panes are dropped; a tab that was ONLY background disappears,
--     and a window left with no tabs disappears with it.
do
  local state = { windows = {
    { tabs = {
      { active = true, panes = { pane(0, 0, 80, 24, { domain = 'bg-1', active = true }) } },
      { panes = { pane(0, 0, 80, 24, { domain = 'local', active = true }) } },
    } },
    { tabs = {
      { active = true, panes = { pane(0, 0, 80, 24, { domain = 'bg-2', active = true }) } },
    } },
  } }
  local out = session.sanitize(state)
  eq('sanitize/windows', #out.windows, 1)
  eq('sanitize/tabs', #out.windows[1].tabs, 1)
  eq('sanitize/kept-domain', out.windows[1].tabs[1].panes[1].domain, 'local')
  -- The surviving tab was not the flagged-active one; it must still become active.
  eq('sanitize/active-reassigned', out.windows[1].tabs[1].active, true)
end

-- 12. When the focused PANE is dropped, focus falls back to a survivor rather
--     than leaving the tab with no active pane.
do
  local state = { windows = { { tabs = { { active = true, panes = {
    pane(0, 0, 40, 24, { domain = 'local', active = false }),
    pane(41, 0, 40, 24, { domain = 'bg-3', active = true }),
  } } } } } }
  local out = session.sanitize(state)
  eq('sanitize/pane-count', #out.windows[1].tabs[1].panes, 1)
  eq('sanitize/pane-active-reassigned', out.windows[1].tabs[1].panes[1].active, true)
end

-- 13. Panes with no usable cwd are dropped — restoring them would land in the
--     wrong directory.
do
  -- Built literally rather than via pane(): `cwd = nil` inside a table literal
  -- stores nothing, so the helper's default would survive and hide the case.
  local state = { windows = { { tabs = { { active = true, panes = {
    { left = 0, top = 0, width = 40, height = 24, domain = 'local', active = true },
    pane(41, 0, 40, 24, { domain = 'local', cwd = '/tmp' }),
  } } } } } }
  local out = session.sanitize(state)
  eq('sanitize/no-cwd-dropped', #out.windows[1].tabs[1].panes, 1)
  eq('sanitize/no-cwd-survivor', out.windows[1].tabs[1].panes[1].cwd, '/tmp')
end

-- 14. Malformed / empty input must not throw.
do
  eq('sanitize/nil', session.is_empty(session.sanitize(nil)), true)
  eq('sanitize/empty-table', session.is_empty(session.sanitize({})), true)
  eq('sanitize/no-tabs', session.is_empty(session.sanitize({ windows = { {} } })), true)
  eq('sanitize/empty-panes',
     session.is_empty(session.sanitize({ windows = { { tabs = { { panes = {} } } } } })), true)
end

-- 15. Window size is carried through so a restored window comes back its old size.
do
  local state = { windows = { { cols = 120, rows = 40, tabs = { { active = true,
    panes = { pane(0, 0, 120, 40, { domain = 'local', active = true }) } } } } } }
  local out = session.sanitize(state)
  eq('sanitize/cols', out.windows[1].cols, 120)
  eq('sanitize/rows', out.windows[1].rows, 40)
end

-- 16. Optional resume argv is copied only when it is a bounded string array;
-- malformed or huge executable input degrades to a fresh shell.
do
  local function sanitized_args(args)
    local state = { windows = { { tabs = { {
      active = true,
      title = 'agent tab',
      panes = { pane(0, 0, 80, 24, { domain = 'local', active = true, args = args }) },
    } } } } }
    return session.sanitize(state, { preserve_resume_args = true }).windows[1].tabs[1]
  end
  local valid = { 'codex', 'resume', '12345678-1234-4abc-9def-1234567890ab' }
  local tab = sanitized_args(valid)
  eq('sanitize/title retained', tab.title, 'agent tab')
  eq('sanitize/args retained', table.concat(tab.panes[1].args, ' '), table.concat(valid, ' '))
  eq('sanitize/args copied', tab.panes[1].args == valid, false)
  eq('sanitize/malformed args dropped', sanitized_args({ 'codex', false }).panes[1].args, nil)
  eq('sanitize/huge arg dropped', sanitized_args({ string.rep('x', 4097) }).panes[1].args, nil)
  eq('sanitize/arbitrary command dropped', sanitized_args({ 'bash', '-lc', 'rm -rf x' }).panes[1].args, nil)
  local too_many = {}
  for i = 1, 17 do too_many[i] = tostring(i) end
  eq('sanitize/too many args dropped', sanitized_args(too_many).panes[1].args, nil)
  local disk_state = { windows = { { tabs = { { active = true, panes = {
    pane(0, 0, 80, 24, { domain = 'local', active = true, args = valid }),
  } } } } } }
  eq('sanitize/disk default drops resume args',
    session.sanitize(disk_state).windows[1].tabs[1].panes[1].args, nil)
end

-- ---------- zoom guard ----------

-- 17. Zoomed geometry is self-overlapping, so the save must be skipped rather
--     than allowed to overwrite a good layout. Geometry below is the real thing,
--     read off a live mux server: a 2x2 grid with pane 1 zoomed reports that
--     pane at the full 80x24 tab size while its siblings keep their own coords.
do
  local zoomed_grid = { windows = { { tabs = { { active = true, zoomed = true, panes = {
    pane(0, 0, 80, 24, { domain = 'local', active = true }),  -- zoomed: whole tab
    pane(40, 0, 40, 11, { domain = 'local' }),
    pane(0, 12, 39, 12, { domain = 'local' }),
    pane(40, 12, 40, 12, { domain = 'local' }),
  } } } } } }
  eq('zoom/detected', session.has_zoomed(zoomed_grid), true)

  local normal = { windows = { { tabs = { { active = true, panes = {
    pane(0, 0, 39, 11, { domain = 'local', active = true }),
    pane(40, 0, 40, 11, { domain = 'local' }),
  } } } } } }
  eq('zoom/absent', session.has_zoomed(normal), false)
  eq('zoom/nil-state', session.has_zoomed(nil), false)
  eq('zoom/empty-state', session.has_zoomed({}), false)

  -- The flag is a capture-time signal only; it must never reach the saved state.
  eq('zoom/not-persisted', session.sanitize(zoomed_grid).windows[1].tabs[1].zoomed, nil)
end

-- 18. The real unzoomed 2x2 geometry from that same live server round-trips
--     exactly — this is the divider-offset case (pane ends at 39, next starts
--     at 40) that the tolerance exists for.
do
  local panes = {
    pane(0, 0, 39, 11), pane(40, 0, 40, 11),
    pane(0, 12, 39, 12), pane(40, 12, 40, 12),
  }
  local plan = session.split_plan(panes)
  eq('measured-grid/ops', #plan.ops, 3)
  local good, err = layout_matches(panes)
  ok('measured-grid/layout', good, err)
end

-- ---------- digest ----------

do
  local function state_with(cwd, left)
    return session.sanitize({ windows = { { tabs = { { active = true, panes = {
      pane(left or 0, 0, 40, 24, { domain = 'local', cwd = cwd, active = true }),
    } } } } } })
  end
  eq('digest/stable', session.digest(state_with('/a')), session.digest(state_with('/a')))
  ok('digest/cwd-change', session.digest(state_with('/a')) ~= session.digest(state_with('/b')))
  ok('digest/geometry-change',
     session.digest(state_with('/a', 0)) ~= session.digest(state_with('/a', 5)))
  eq('digest/empty', session.digest(session.sanitize({})), '')
end

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
