-- nary.lua — an N-ary tiling tree for Hyprland's Lua Layout API (0.55+).
--
-- Why this exists: dwindle is strictly binary (BSP), so it cannot represent
-- "three windows as equal peers of one parent". This layout owns its own tree,
-- where a container may have ANY number of children, so it can.
--
-- Model:
--   node = { kind = "container", orient = "h"|"v", children = { <node>... } }
--        | { kind = "leaf", id = <window stable_id as string> }
-- The root is always a container. Leaves reference windows by stable_id, which
-- is how structure persists across recalculate() calls.
--
-- Nesting a container inside a same-orientation parent is NOT redundant here:
-- it changes the weights. h(h(1 2) 3) gives 1 and 2 a quarter each and 3 a
-- half, whereas h(1 2 3) gives equal thirds. That distinction is what makes
-- the movement model below work.
--
-- MOVEMENT — the "insertion slot" model
--
-- A directional move is not swap/promote/merge as three separate commands. Lift
-- the focused window out of the tree, enumerate every position it could be put
-- back into (in left-to-right / top-to-bottom order), and step one position
-- along that list. Swapping with a sibling, popping out of a group, and
-- descending into a neighbour all fall out as adjacent slots.
--
-- Starting from h(h(1 2) 3) and pressing "move right" repeatedly:
--     h(h(1 2) 3)  ->  h(h(2 1) 3)  ->  h(2 1 3)  ->  h(2 h(1 3))
--                  ->  h(2 h(3 1))  ->  h(2 3 1)
--
-- Slots are enumerated within the INNERMOST ancestor whose orientation matches
-- the axis of travel; containers perpendicular to that axis are opaque (you
-- wrap around them, you don't walk into them).
--
-- Running off either end of that container escapes one level outward, which is
-- how a window leaves a group rather than being trapped in it:
--   * to the next same-axis ancestor, becoming a peer beside the group it left;
--   * or, if nothing outside runs along this axis, into a branch of its own —
--     a full band across the tree, with everything else sharing the rest.
--     h(1 v(2 3)), with 2 moving up, becomes v(2 h(1 3)).
--
-- If no ancestor runs along the axis at all — e.g. pressing "down" while
-- everything is in one horizontal row — the move bootstraps one by pairing the
-- focused window with an adjacent sibling.
--
-- TABS — a leaf is a TILE, not a window
--
-- A tabbed group is several windows sharing one tile, and Hyprland hands it to
-- the layout as a single target whose .window is only the visible tab. Keying
-- leaves by that window would make the tile's identity change every time you
-- cycle tabs (CGroup::setCurrent calls recalc), so a leaf carries the whole set
-- of window ids on its tile and is matched on overlap.
--
-- Splitting and merging a tile leave that match genuinely ambiguous: when a tab
-- pops out, one leaf faces two targets; when a window is tabbed into another,
-- one target faces two leaves. Both are resolved by the same rule — THE FOCUSED
-- WINDOW IS THE ONE THAT MOVED, so it yields the tile to the other side. A tile
-- stays with the windows that stayed put, and the window that moved is placed
-- as if it were new.
--
-- Where it is placed is something the layout cannot infer: Hyprland's own hint
-- (the focal point passed to movedTarget) is dropped by the Lua layout API. So
-- the keybinding says it in advance with `untab <dir>`, which is remembered
-- against that tile until the window actually leaves it.
--
-- Registered as "nary"; activate with general.layout = "lua:nary".
-- Commands (via hl.dsp.layout("<cmd>")):
--   move l|r|u|d    step the focused window one insertion slot along an axis
--   untab l|r|u|d   when the focused tab next leaves its tile, put it that side
--   toggleorient    flip the focused window's parent container between h and v
--
-- Gaps are deliberately not applied here: Hyprland's WindowTarget insets each
-- placed box by general:gaps_in (and Space has already removed gaps_out from
-- ctx.area), so this layout places windows edge-to-edge in the work area.

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

-- Hyprland instantiates one algorithm per space but they all share this single
-- Lua module, so the tree must be partitioned per workspace — otherwise
-- recalculating workspace 2 would reconcile away every window of workspace 1.
-- pending holds at most one untab intent per workspace: where the window that
-- is about to leave a tile should be put down. See cmd_untab.
local state = { trees = {}, pending = {} }

local function new_root()
    return { kind = "container", orient = "h", children = {} }
end

-- ctx carries no space identity, so derive it from the windows being laid out.
-- Hyprland skips the Lua callback entirely when a space has no targets, so
-- there is always at least one window to ask.
local function space_key(ctx)
    for _, target in ipairs(ctx.targets) do
        local w  = target.window
        local ws = w and w.workspace
        if ws and ws.id then return "ws:" .. tostring(ws.id) end
    end
    return "ws:unknown"
end

local function tree_for(key)
    local root = state.trees[key]
    if not root then
        root = new_root()
        state.trees[key] = root
    end
    return root
end

--------------------------------------------------------------------------------
-- Tree primitives (pure — no ctx, no Hyprland)
--------------------------------------------------------------------------------

local function is_leaf(node)      return node.kind == "leaf" end
local function is_container(node) return node.kind == "container" end

-- leaf.id is the tile's key: one live window id, used for canon and to address
-- the tile. leaf.ids is every window currently on it — one entry unless the
-- tile is a tabbed group. A leaf written by hand (tests, literals) may omit
-- ids, which then means "just the key".
local function leaf_ids(leaf)
    return leaf.ids or { leaf.id }
end

-- Tiles are addressed by ANY window on them, so callers can pass the focused
-- window's id without caring whether it is a tab.
local function leaf_holds(leaf, id)
    if leaf.id == id then return true end
    for _, held in ipairs(leaf_ids(leaf)) do
        if held == id then return true end
    end
    return false
end

local function copy(node)
    if is_leaf(node) then
        local ids
        if node.ids then
            ids = {}
            for i, id in ipairs(node.ids) do ids[i] = id end
        end
        return { kind = "leaf", id = node.id, ids = ids }
    end
    local children = {}
    for i, child in ipairs(node.children) do children[i] = copy(child) end
    return { kind = "container", orient = node.orient, children = children }
end

-- Structural fingerprint. Two trees with the same canon render identically and
-- are the same layout; this is how slots are deduplicated and how the focused
-- window's current slot is located.
local function canon(node)
    if is_leaf(node) then return node.id end
    local parts = {}
    for i, child in ipairs(node.children) do parts[i] = canon(child) end
    return node.orient .. "(" .. table.concat(parts, " ") .. ")"
end

local function collect_leaves(node, acc)
    if is_leaf(node) then
        acc[#acc + 1] = node
        return acc
    end
    for _, child in ipairs(node.children) do collect_leaves(child, acc) end
    return acc
end

local function find_leaf(node, id)
    if not is_container(node) then return nil end
    for i, child in ipairs(node.children) do
        if is_leaf(child) then
            if leaf_holds(child, id) then return child, node, i end
        else
            local l, p, idx = find_leaf(child, id)
            if l then return l, p, idx end
        end
    end
end

-- Locate a leaf by identity rather than by id, for callers holding the node.
local function parent_of(node, leaf)
    for i, child in ipairs(node.children) do
        if child == leaf then return node, i end
        if is_container(child) then
            local parent, idx = parent_of(child, leaf)
            if parent then return parent, idx end
        end
    end
end

-- The chain of containers from root down to the focused leaf's parent, plus the
-- child index taken at each step. nodes[i].children[idxs[i]] is the next hop,
-- and idxs[#idxs] is the leaf's own index in its parent.
local function chain_to(node, id)
    for i, child in ipairs(node.children) do
        if is_leaf(child) then
            if leaf_holds(child, id) then return { node }, { i } end
        else
            local nodes, idxs = chain_to(child, id)
            if nodes then
                table.insert(nodes, 1, node)
                table.insert(idxs, 1, i)
                return nodes, idxs
            end
        end
    end
end

local function remove_leaf(node, id)
    for i, child in ipairs(node.children) do
        if is_leaf(child) then
            if leaf_holds(child, id) then
                table.remove(node.children, i)
                return true
            end
        elseif remove_leaf(child, id) then
            return true
        end
    end
    return false
end

-- Drop empty containers and collapse single-child ones (a container holding one
-- node adds no subdivision, so it must not survive — otherwise identical
-- layouts get different canon strings and slot matching breaks).
local function prune(node, root)
    if is_leaf(node) then return node end
    local kept = {}
    for _, child in ipairs(node.children) do
        if is_container(child) then
            local c = prune(child, root)
            if c then kept[#kept + 1] = c end
        else
            kept[#kept + 1] = child
        end
    end
    node.children = kept
    if node ~= root then
        if #kept == 0 then return nil end
        if #kept == 1 then return kept[1] end
    end
    return node
end

-- Prune, then unwrap a root that has become a lone container (the root must
-- stay a container, but it should not be a pointless wrapper around one).
local function normalize(root)
    prune(root, root)
    while #root.children == 1 and is_container(root.children[1]) do
        root = root.children[1]
    end
    return root
end

--------------------------------------------------------------------------------
-- Reconcile a tree with the windows Hyprland currently gives us
--------------------------------------------------------------------------------

-- Every window on a target: a group is one tile showing several, of which
-- target.window is merely the visible tab. The visible one comes first, so it
-- is the natural key for a tile that needs a new one.
local function target_ids(target)
    local w = target.window
    if not w then return { "idx:" .. tostring(target.index) } end

    local primary = tostring(w.stable_id)
    local ids     = { primary }

    local group   = w.group
    local members = group and group.members
    if members then
        if members.stable_id then members = { members } end -- a lone member is not wrapped
        for _, m in ipairs(members) do
            local id = m and m.stable_id and tostring(m.stable_id)
            if id and id ~= primary then ids[#ids + 1] = id end
        end
    end
    return ids
end

local function active_id(ctx)
    for _, target in ipairs(ctx.targets) do
        local w = target.window
        if w and w.active then return tostring(w.stable_id) end
    end
    return nil
end

local function has_id(ids, wanted)
    for _, id in ipairs(ids) do
        if id == wanted then return true end
    end
    return false
end

-- Insert a brand-new leaf as a sibling right after the focused leaf, or append
-- to root when there is no focus to anchor against.
local function insert_new(root, leaf, focused)
    if focused then
        local _, parent, idx = find_leaf(root, focused)
        if parent then
            table.insert(parent.children, idx + 1, leaf)
            return
        end
    end
    table.insert(root.children, leaf)
end

-- Put a leaf immediately beside another along an axis, splitting the anchor's
-- own slot when the surrounding container runs the wrong way. Same "lands on
-- the side it was sent towards" rule as bootstrap_axis.
local function insert_beside(root, anchor, ax, delta, leaf)
    local parent, idx = parent_of(root, anchor)
    if not parent then return false end

    if parent.orient == ax then
        table.insert(parent.children, idx + (delta > 0 and 1 or 0), leaf)
    else
        parent.children[idx] = {
            kind     = "container",
            orient   = ax,
            children = (delta > 0) and { anchor, leaf } or { leaf, anchor },
        }
    end
    return true
end

-- Bring this space's tree in line with ctx.targets: tiles that went away are
-- dropped, tiles that arrived are placed, and every surviving leaf adopts the
-- window set its target now has. Returns the tree plus a leaf -> target map.
--
-- `settling` marks the recalculate pass (as opposed to the reconcile that
-- precedes a command), which is the only place an untab intent may be spent.
local function reconcile(ctx, settling)
    local key     = space_key(ctx)
    local root    = tree_for(key)
    local focused = active_id(ctx)

    local holder = {}
    for _, leaf in ipairs(collect_leaves(root, {})) do
        for _, id in ipairs(leaf_ids(leaf)) do holder[id] = leaf end
    end

    -- The target holding the focused window is matched last, so on a split it
    -- is the other side that keeps the tile. See the TABS note up top.
    local entries, deferred = {}, {}
    for _, target in ipairs(ctx.targets) do
        local entry = { target = target, ids = target_ids(target) }
        if focused and has_id(entry.ids, focused) then
            deferred[#deferred + 1] = entry
        else
            entries[#entries + 1] = entry
        end
    end
    for _, entry in ipairs(deferred) do entries[#entries + 1] = entry end

    local claimed, place, arrived = {}, {}, {}

    for _, entry in ipairs(entries) do
        -- Candidates in id order, so the choice never depends on table order.
        local candidates, seen = {}, {}
        for _, id in ipairs(entry.ids) do
            local leaf = holder[id]
            if leaf and not claimed[leaf] and not seen[leaf] then
                seen[leaf] = true
                candidates[#candidates + 1] = leaf
            end
        end

        -- Merging into a tile: the focused window's old leaf is the one it
        -- vacated, so prefer any other candidate.
        local pick
        for _, leaf in ipairs(candidates) do
            if not (focused and leaf_holds(leaf, focused)) then
                pick = leaf
                break
            end
        end
        pick = pick or candidates[1]

        if pick then
            claimed[pick] = true
            place[pick]   = entry.target
            if not has_id(entry.ids, pick.id) then pick.id = entry.ids[1] end
            pick.ids = entry.ids
        else
            arrived[#arrived + 1] = entry
        end
    end

    local function drop_unclaimed(node)
        if is_leaf(node) then return claimed[node] end
        local kept = {}
        for _, child in ipairs(node.children) do
            if drop_unclaimed(child) then kept[#kept + 1] = child end
        end
        node.children = kept
        return true
    end
    drop_unclaimed(root)
    root = normalize(root)

    -- An untab intent lives while its window is still on the anchor tile; the
    -- pass where that stops being true is the one it was recorded for, and it
    -- is spent (or discarded) there rather than carried any further.
    local pending = state.pending[key]
    local live    = pending and claimed[pending.anchor] and leaf_holds(pending.anchor, pending.id)
    if settling and pending and not live then state.pending[key] = nil end

    local anchor_focus = focused
    for _, entry in ipairs(arrived) do
        local leaf   = { kind = "leaf", id = entry.ids[1], ids = entry.ids }
        local placed = false

        if settling and pending and claimed[pending.anchor] and has_id(entry.ids, pending.id) then
            placed = insert_beside(root, pending.anchor, pending.ax, pending.delta, leaf)
            if placed then state.pending[key] = nil end
        end

        if not placed then insert_new(root, leaf, anchor_focus) end

        place[leaf]  = entry.target
        anchor_focus = anchor_focus or entry.ids[1]
    end

    root = normalize(root)
    state.trees[key] = root
    return root, place, key
end

--------------------------------------------------------------------------------
-- Placement: split an area into N slices using only ctx:split
--------------------------------------------------------------------------------

local function slice(ctx, area, orient, n)
    local first = (orient == "v") and "top" or "left"
    local rest  = (orient == "v") and "bottom" or "right"
    local rects, remaining = {}, area
    for i = 1, n do
        if i == n then
            rects[i] = remaining
        else
            local frac = 1 / (n - i + 1)
            rects[i]  = ctx:split(remaining, first, frac)
            remaining = ctx:split(remaining, rest, 1 - frac)
        end
    end
    return rects
end

local function layout_node(ctx, node, area, place)
    if is_leaf(node) then
        local target = place[node]
        if target then target:place(area) end
        return
    end
    local n = #node.children
    if n == 0 then return end
    local rects = slice(ctx, area, node.orient, n)
    for i, child in ipairs(node.children) do
        layout_node(ctx, child, rects[i], place)
    end
end

--------------------------------------------------------------------------------
-- Insertion slots
--------------------------------------------------------------------------------

-- A slot says where to put the lifted window back:
--   { path = {child indices from root to a container}, index = i }
--     -> insert as that container's i-th child (a "gap" between existing peers)
--   { path = ..., index = i, wrap = "before"|"after" }
--     -> replace that container's i-th child with a new container holding both
--        the lifted window and the displaced child, in the given order.
local function node_at(root, path)
    local node = root
    for _, i in ipairs(path) do node = node.children[i] end
    return node
end

local function extend(path, i)
    local out = {}
    for k, v in ipairs(path) do out[k] = v end
    out[#out + 1] = i
    return out
end

-- Walk `container` in reading order along `ax`. Containers oriented along the
-- same axis are transparent (we walk through them); everything else is an atom
-- the window can only wrap around.
local function enumerate(container, ax, path, out)
    out[#out + 1] = { path = path, index = 1 }
    for i, child in ipairs(container.children) do
        if is_container(child) and child.orient == ax then
            enumerate(child, ax, extend(path, i), out)
        elseif #container.children > 1 then
            -- With a single child, wrapping collapses back to the gap slots, so
            -- it would only produce duplicates.
            out[#out + 1] = { path = path, index = i, wrap = "before" }
            out[#out + 1] = { path = path, index = i, wrap = "after" }
        end
        out[#out + 1] = { path = path, index = i + 1 }
    end
end

local function apply_slot(root, slot, leaf, ax)
    local parent = node_at(root, slot.path)
    if slot.wrap then
        local displaced = parent.children[slot.index]
        local children  = (slot.wrap == "before") and { leaf, displaced } or { displaced, leaf }
        parent.children[slot.index] = { kind = "container", orient = ax, children = children }
    else
        table.insert(parent.children, slot.index, leaf)
    end
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local AXIS  = { l = "h", r = "h", u = "v", d = "v" }
local DELTA = { l = -1,  r = 1,   u = -1,  d = 1 }

-- No ancestor runs along the axis of travel, so there is nowhere to step to.
-- Pair the focused window with an adjacent sibling to create that axis, after
-- which subsequent moves cycle through it normally.
--
-- The window lands on the side it was sent towards: up puts it on top, down
-- underneath. This is NOT the "enter from the near edge" rule the slot ladder
-- uses — that one describes a window travelling past a neighbour it can already
-- reach, whereas here the axis does not exist yet and the keypress is the only
-- thing saying where the window should end up.
local function bootstrap_axis(nodes, idxs, ax, delta)
    local parent = nodes[#nodes]
    local idx    = idxs[#idxs]
    local leaf   = parent.children[idx]

    local neighbour = parent.children[idx + delta] or parent.children[idx - delta]
    if not neighbour then return false end

    table.remove(parent.children, idx)
    local at
    for k, child in ipairs(parent.children) do
        if child == neighbour then at = k break end
    end

    local children = (delta > 0) and { neighbour, leaf } or { leaf, neighbour }
    parent.children[at] = { kind = "container", orient = ax, children = children }
    return true
end

local function cmd_move(root, key, ctx, dir)
    local ax, delta = AXIS[dir], DELTA[dir]
    if not ax then return "nary: move expects l, r, u or d" end

    local id = active_id(ctx)
    if not id then return true end

    local current = canon(root)
    local work    = copy(root)

    local nodes, idxs = chain_to(work, id)
    if not nodes then return true end

    -- What travels is the whole tile, tabs and all, not the focused window.
    local moving = copy(nodes[#nodes].children[idxs[#idxs]])

    -- Innermost ancestor oriented along the axis of travel. Slots are
    -- enumerated within it; running off either end escapes one level outward.
    local si
    for i = #nodes, 1, -1 do
        if nodes[i].orient == ax then
            si = i
            break
        end
    end

    if not si then
        if bootstrap_axis(nodes, idxs, ax, delta) then
            state.trees[key] = normalize(work)
        end
        return true
    end

    local scope, scope_path = nodes[si], {}
    for k = 1, si - 1 do scope_path[k] = idxs[k] end

    local leaf = moving

    -- Where a window is parked at the correct side of a container it wants to
    -- leave: drop it in beside that container, one level out.
    local function escape_into(container, index)
        remove_leaf(work, id)
        table.insert(container.children, index + (delta > 0 and 1 or 0), leaf)
        state.trees[key] = normalize(work)
        return true
    end

    -- The focused window sits inside a container perpendicular to the axis, so
    -- none of scope's slots describe where it currently is. Step out of that
    -- container first, joining scope alongside it.
    if si < #nodes then
        return escape_into(scope, idxs[si])
    end

    remove_leaf(work, id)

    local slots = {}
    enumerate(scope, ax, scope_path, slots)

    -- Materialise each slot, then drop duplicates so stepping always changes
    -- the layout.
    local candidates, seen, at = {}, {}, nil
    for _, slot in ipairs(slots) do
        -- Normalise only after inserting: collapsing containers first would
        -- shift the child indices the slot paths were built from.
        local tree = copy(work)
        apply_slot(tree, slot, copy(leaf), ax)
        tree = normalize(tree)

        local fingerprint = canon(tree)
        if not seen[fingerprint] then
            seen[fingerprint] = true
            candidates[#candidates + 1] = tree
            if fingerprint == current then at = #candidates end
        end
    end

    if at then
        local target = candidates[at + delta]
        if target then
            state.trees[key] = target
            return true
        end
    end

    -- Off the end of scope's slots. Escape to the next same-axis ancestor if
    -- there is one, so the window pops out of its group and becomes a peer.
    for i = si - 1, 1, -1 do
        if nodes[i].orient == ax then
            return escape_into(nodes[i], idxs[i])
        end
    end

    -- Scope is the root: the window already spans the workspace on this axis.
    if si == 1 then return true end

    -- Nothing outside runs along this axis, so give the window a branch of its
    -- own: it claims a full band across the tree and everything else shares the
    -- rest. h(1 v(2 3)) with 2 moving up becomes v(2 h(1 3)).
    state.trees[key] = normalize({
        kind     = "container",
        orient   = ax,
        children = (delta > 0) and { work, leaf } or { leaf, work },
    })
    return true
end

-- Record where the focused tab should be put down when it leaves its tile.
-- Nothing moves here: the caller dispatches the un-tab itself, and the intent
-- is spent by the recalculate that follows (see reconcile).
local function cmd_untab(root, key, ctx, dir)
    local ax, delta = AXIS[dir], DELTA[dir]
    if not ax then return "nary: untab expects l, r, u or d" end

    local id = active_id(ctx)
    if not id then return true end

    local leaf = find_leaf(root, id)
    if not leaf or #leaf_ids(leaf) < 2 then return true end -- not a tab: nothing will leave

    state.pending[key] = { id = id, anchor = leaf, ax = ax, delta = delta }
    return true
end

local function cmd_toggleorient(root, ctx)
    local id = active_id(ctx)
    if not id then return true end
    local _, parent = find_leaf(root, id)
    if parent then parent.orient = (parent.orient == "h") and "v" or "h" end
    return true
end

--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------

local function dispatch(ctx, msg)
    local root, _, key = reconcile(ctx)
    local command, arg = msg:match("^(%S+)%s*(%S*)$")
    if command == "move" then
        return cmd_move(root, key, ctx, arg)
    elseif command == "untab" then
        return cmd_untab(root, key, ctx, arg)
    elseif command == "toggleorient" then
        return cmd_toggleorient(root, ctx)
    end
    return "nary: expected 'move <l|r|u|d>', 'untab <l|r|u|d>' or 'toggleorient'"
end

-- Exposed for the offline test harness; harmless under Hyprland.
local M = {
    state     = state,
    canon     = canon,
    dispatch  = dispatch,
    space_key = space_key,
    tree_for  = tree_for,
    -- What recalculate does, minus the placing: the pass that settles arrivals.
    settle    = function(ctx) return reconcile(ctx, true) end,
}

if hl and hl.layout then
    hl.layout.register("nary", {
        recalculate = function(ctx)
            local root, place = reconcile(ctx, true)
            layout_node(ctx, root, ctx.area, place)
        end,

        layout_msg = dispatch,
    })
end

return M
