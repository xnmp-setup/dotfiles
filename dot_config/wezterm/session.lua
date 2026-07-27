-- Pure, unit-tested session-restore logic for the wezterm config.
--
-- No wezterm dependency: this module only ever sees plain Lua tables, so it
-- loads under plain `lua` for testing (see session.test.lua). wezterm.lua owns
-- the impure half — walking the mux to build a state table, writing/reading the
-- JSON file, and executing the plan this module produces.
--
-- Modelled on MLFlexer/resurrect.wezterm, the de-facto standard for this in the
-- wezterm ecosystem (archived 2026-05, so its idioms are current but its code is
-- no longer maintained — hence borrowed rather than depended on). Adopted from
-- it: the one-cell divider between adjacent panes, relative split sizing, the
-- is_spawnable() domain guard, the Windows drive-letter cwd fixup, and the
-- self-rescheduling periodic save. Where this diverges is the layout algorithm —
-- see split_plan().
--
-- The state shape (what gets serialised to session.json):
--
--   { version = 1, windows = { {
--       cols = <int>, rows = <int>,
--       tabs = { {
--         active = <bool>,
--         panes = { { cwd, domain, left, top, width, height,
--                     active = <bool> }, ... },
--       }, ... },
--     }, ... } }
--
-- Zoom is deliberately NOT persisted. Measured against a live mux server: while
-- a pane is zoomed it reports the whole tab's size (80x24 for a 2x2 grid) while
-- its siblings keep their real coords, so the rectangles overlap and describe no
-- valid layout. Saving that would replace a good layout with garbage, so the
-- caller uses has_zoomed() to skip the save entirely until zoom is released —
-- the last good layout survives, and the (transient) zoom state is simply not
-- restored.
--
-- "Which tab/pane was focused" is stored as a BOOLEAN FLAG on the item, never as
-- an index. sanitize() drops panes (background-domain ones), which renumbers
-- everything — an index would silently come to point at the wrong pane, a flag
-- can't.

local M = {}

M.VERSION = 1

-- Background tabs (see the unix-domain block in wezterm.lua) already survive a
-- GUI restart on their own: their panes live in a wezterm-mux-server that
-- outlives us. Restoring them here would spawn a SECOND shell alongside the
-- still-running one, so they're excluded from the session entirely.
M.BG_DOMAIN_PATTERN = '^bg%-%d+$'

function M.is_restorable_domain(name)
  if type(name) ~= 'string' or name == '' then return false end
  return name:match(M.BG_DOMAIN_PATTERN) == nil
end

-- Normalise a pane's cwd to a plain filesystem path.
--
-- wezterm hands this over in one of two shapes depending on version/OSC-7 host:
-- a Url object (fields .file_path / .path, the latter percent-encoded, and
-- .file_path is nil when the OSC-7 host isn't the local host), or the legacy
-- "file://host/path" string. Mirrors the normalisation format-tab-title does.
--
-- The Windows branch is resurrect's fix: there file_path comes back as
-- "/C:/Users/..." — a leading slash before the drive letter, which wezterm won't
-- accept back as a spawn cwd. Applied by pattern, not by platform check, so it's
-- a no-op on paths that don't look like that.
--
-- Returns nil when there's nothing usable, so the caller can skip the pane
-- rather than restore it into the wrong directory.
function M.normalize_cwd(cwd)
  if cwd == nil then return nil end
  local path
  if type(cwd) == 'string' then
    path = (cwd:gsub('^file://[^/]*', ''))
  else
    path = cwd.file_path
    if not path or path == '' then
      path = ((cwd.path or ''):gsub('%%(%x%x)', function(h)
        return string.char(tonumber(h, 16))
      end))
    end
  end
  if not path or path == '' then return nil end
  path = (path:gsub('^/([a-zA-Z]):', '%1:'))   -- "/C:/x" -> "C:/x"
  -- Strip trailing separators, but never reduce "/" to "".
  path = (path:gsub('(.)[/\\]+$', '%1'))
  return path
end

-- Drop what can't or shouldn't be restored, and collapse anything left empty.
-- A tab whose every pane was a background pane disappears; a window left with no
-- tabs disappears with it. Pure: returns a new table, never mutates the input.
function M.sanitize(state)
  local out = { version = M.VERSION, windows = {} }
  for _, win in ipairs((state or {}).windows or {}) do
    local tabs = {}
    for _, tab in ipairs(win.tabs or {}) do
      local panes = {}
      for _, p in ipairs(tab.panes or {}) do
        if M.is_restorable_domain(p.domain) and p.cwd and p.cwd ~= '' then
          panes[#panes + 1] = {
            cwd = p.cwd, domain = p.domain,
            left = p.left or 0, top = p.top or 0,
            width = p.width or 1, height = p.height or 1,
            active = p.active and true or false,
          }
        end
      end
      if #panes > 0 then
        -- If the focused pane was one of the dropped ones, focus falls back to
        -- the first survivor so a restored tab always has a sensible active pane.
        local has_active = false
        for _, p in ipairs(panes) do
          if p.active then has_active = true; break end
        end
        if not has_active then panes[1].active = true end
        tabs[#tabs + 1] = { panes = panes, active = tab.active and true or false }
      end
    end
    if #tabs > 0 then
      local has_active = false
      for _, t in ipairs(tabs) do
        if t.active then has_active = true; break end
      end
      if not has_active then tabs[1].active = true end
      out.windows[#out.windows + 1] = { tabs = tabs, cols = win.cols, rows = win.rows }
    end
  end
  return out
end

function M.is_empty(state)
  return #((state or {}).windows or {}) == 0
end

-- True if any tab was captured with a zoomed pane. Runs on the RAW capture
-- (before sanitize, which drops the flag), and tells the caller to skip this
-- save: zoomed geometry is self-overlapping and would destroy the stored
-- layout. See the note at the top of this file.
function M.has_zoomed(state)
  for _, win in ipairs((state or {}).windows or {}) do
    for _, tab in ipairs(win.tabs or {}) do
      if tab.zoomed then return true end
    end
  end
  return false
end

-- Stable fingerprint of a state, used to skip writing an unchanged session.
-- Geometry is included so that resizing a split eventually persists its new
-- ratio; the caller throttles saves, so churn while dragging is bounded.
function M.digest(state)
  local parts = {}
  for _, win in ipairs((state or {}).windows or {}) do
    for _, tab in ipairs(win.tabs or {}) do
      for _, p in ipairs(tab.panes or {}) do
        parts[#parts + 1] = table.concat({
          p.domain or '', p.cwd or '',
          p.left or 0, p.top or 0, p.width or 0, p.height or 0,
          p.active and 1 or 0,
        }, '\1')
      end
      parts[#parts + 1] = 'T' .. (tab.active and 1 or 0)
    end
    parts[#parts + 1] = 'W'
  end
  return table.concat(parts, '\2')
end

-- ---------- Split-layout reconstruction ----------
--
-- wezterm can only rebuild a pane layout by repeatedly splitting an existing
-- pane, so a captured set of rectangles has to be turned back into an ordered
-- sequence of splits.
--
-- WHY NOT RESURRECT'S ALGORITHM: it builds a tree by adjacency — each node gets
-- a `right` child (the pane touching its right edge) and a `bottom` child (the
-- one touching its bottom edge), recursing into each. Two problems, both
-- reproducible on a plain 2x2 grid:
--
--   1. The right-candidate and bottom-candidate lists overlap (a pane that is
--      both right of and below the node lands in both), and each subtree pops
--      from its own copy — so the bottom-right pane is consumed TWICE and the
--      tree holds 5 nodes for 4 panes. Restoring it spawns a spurious pane.
--   2. Splits are emitted bottom-then-right at every node regardless of the
--      actual geometry. That's right when the bottom pane spans the full width,
--      and wrong when it doesn't — a 2x2 grid comes back as three uneven rows.
--
-- Both follow from deciding the cut per-pane instead of per-group. So this does
-- a proper binary space partition instead: find a straight line that cleanly
-- separates the whole group into two, emit that one split, recurse into each
-- side. The orientation is then a consequence of the geometry rather than a
-- fixed rule, which is what makes full-width bottoms and grids both come out
-- right.
--
-- The key invariant is that a group's ANCHOR is always its top-left pane, and
-- the anchor spans the group's whole rectangle at the moment we split it. So a
-- group's own split must be emitted BEFORE either side is subdivided — hence the
-- op is appended ahead of the two recursive calls.

-- Adjacent panes are separated by a one-cell divider, so a pane's right edge
-- lands a cell short of its neighbour's left edge (resurrect encodes the same
-- constant as the literal +1 in its adjacency test). Edges match with this slack.
local DEFAULT_TOLERANCE = 1

local function bbox(panes, idxs)
  local l, t, r, b = math.huge, math.huge, -math.huge, -math.huge
  for _, i in ipairs(idxs) do
    local p = panes[i]
    if p.left < l then l = p.left end
    if p.top < t then t = p.top end
    if p.left + p.width > r then r = p.left + p.width end
    if p.top + p.height > b then b = p.top + p.height end
  end
  return l, t, r, b
end

-- The pane occupying a group's top-left corner. This is the pane that "is" the
-- group's rectangle before any of its internal splits happen.
local function anchor_of(panes, idxs)
  local best = idxs[1]
  for _, i in ipairs(idxs) do
    local p, q = panes[i], panes[best]
    if p.top < q.top or (p.top == q.top and p.left < q.left) then best = i end
  end
  return best
end

-- Sorted, de-duplicated candidate cut positions along one axis. Sorted (rather
-- than iterated from a set) so the emitted plan is deterministic — tests depend
-- on it, and a stable plan means a stable restore.
local function cut_candidates(panes, idxs, lo, key)
  local seen, out = {}, {}
  for _, i in ipairs(idxs) do
    local v = panes[i][key]
    if v > lo and not seen[v] then
      seen[v] = true
      out[#out + 1] = v
    end
  end
  table.sort(out)
  return out
end

-- Try to split idxs into two groups either side of a straight line.
-- `key`/`extent` select the axis: ('left','width') for a vertical cut,
-- ('top','height') for a horizontal one.
local function try_axis(panes, idxs, lo, hi, key, extent, tol)
  for _, pos in ipairs(cut_candidates(panes, idxs, lo, key)) do
    local a, b, ok = {}, {}, true
    for _, i in ipairs(idxs) do
      local p = panes[i]
      if p[key] + p[extent] <= pos + tol then
        a[#a + 1] = i
      elseif p[key] >= pos - tol then
        b[#b + 1] = i
      else
        ok = false  -- straddles the line: not a clean cut
        break
      end
    end
    if ok and #a > 0 and #b > 0 then
      return { a = a, b = b, size = (hi - pos) / (hi - lo) }
    end
  end
  return nil
end

-- Build the ordered split plan for one tab's panes.
--
--   panes -> { base = <index>, ops = { { from, new, direction, size }, ... } }
--
-- `base` is the pane the tab is spawned with; each op splits the already-created
-- pane `from`, and the pane thereby created corresponds to captured pane `new`.
-- `size` is the fraction of `from` handed to the new pane, matching the
-- MuxPane:split contract (same relative sizing resurrect uses).
function M.split_plan(panes, tolerance)
  local tol = tolerance or DEFAULT_TOLERANCE
  local ops = {}
  if #panes == 0 then return { base = nil, ops = ops } end

  local function emit(idxs)
    if #idxs == 1 then return idxs[1] end
    local l, t, r, b = bbox(panes, idxs)
    local cut = try_axis(panes, idxs, l, r, 'left', 'width', tol)
    local direction = 'Right'
    if not cut then
      cut = try_axis(panes, idxs, t, b, 'top', 'height', tol)
      direction = 'Bottom'
    end
    if not cut then
      -- No clean line exists (a pinwheel layout, or geometry we didn't expect).
      -- Rather than fail the whole restore, degrade to a chain of equal splits:
      -- the panes all come back with their directories, just not the exact shape.
      local anchor = anchor_of(panes, idxs)
      local rest = {}
      for _, i in ipairs(idxs) do
        if i ~= anchor then rest[#rest + 1] = i end
      end
      local from = anchor
      for k, i in ipairs(rest) do
        ops[#ops + 1] = {
          from = from, new = i, direction = 'Right',
          size = 1 / (#rest - k + 2),
        }
        from = i
      end
      return anchor
    end
    local anchor_a = anchor_of(panes, cut.a)
    local anchor_b = anchor_of(panes, cut.b)
    ops[#ops + 1] = { from = anchor_a, new = anchor_b, direction = direction, size = cut.size }
    emit(cut.a)
    emit(cut.b)
    return anchor_a
  end

  local idxs = {}
  for i = 1, #panes do idxs[i] = i end
  return { base = emit(idxs), ops = ops }
end

return M
