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
-- Registered as "nary"; activate with general.layout = "lua:nary".
-- Commands (via hl.dsp.layout("<cmd>")):
--   move l|r|u|d    step the focused window one insertion slot along an axis
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
local state = { trees = {} }

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

local function copy(node)
    if is_leaf(node) then return { kind = "leaf", id = node.id } end
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

local function collect_ids(node, acc)
    if is_leaf(node) then
        acc[node.id] = true
        return
    end
    for _, child in ipairs(node.children) do collect_ids(child, acc) end
end

local function find_leaf(node, id)
    if not is_container(node) then return nil end
    for i, child in ipairs(node.children) do
        if is_leaf(child) then
            if child.id == id then return child, node, i end
        else
            local l, p, idx = find_leaf(child, id)
            if l then return l, p, idx end
        end
    end
end

-- The chain of containers from root down to the focused leaf's parent, plus the
-- child index taken at each step. nodes[i].children[idxs[i]] is the next hop,
-- and idxs[#idxs] is the leaf's own index in its parent.
local function chain_to(node, id)
    for i, child in ipairs(node.children) do
        if is_leaf(child) then
            if child.id == id then return { node }, { i } end
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
            if child.id == id then
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

local function target_id(target)
    local w = target.window
    return w and tostring(w.stable_id) or ("idx:" .. tostring(target.index))
end

local function active_id(ctx)
    for _, target in ipairs(ctx.targets) do
        local w = target.window
        if w and w.active then return target_id(target) end
    end
    return nil
end

-- Insert a brand-new leaf as a sibling right after the focused leaf, or append
-- to root when there is no focus to anchor against.
local function insert_new(root, id, focused)
    if focused then
        local _, parent, idx = find_leaf(root, focused)
        if parent then
            table.insert(parent.children, idx + 1, { kind = "leaf", id = id })
            return
        end
    end
    table.insert(root.children, { kind = "leaf", id = id })
end

-- Bring this space's tree in line with ctx.targets: drop windows that left,
-- add ones that arrived, and return the tree plus an id -> target map.
local function reconcile(ctx)
    local key  = space_key(ctx)
    local root = tree_for(key)

    local present, by_id = {}, {}
    for _, target in ipairs(ctx.targets) do
        local id = target_id(target)
        present[id] = true
        by_id[id] = target
    end

    local function drop_absent(node)
        if is_leaf(node) then return present[node.id] end
        local kept = {}
        for _, child in ipairs(node.children) do
            if drop_absent(child) then kept[#kept + 1] = child end
        end
        node.children = kept
        return true
    end
    drop_absent(root)

    local existing = {}
    collect_ids(root, existing)
    local focused = active_id(ctx)
    for _, target in ipairs(ctx.targets) do
        local id = target_id(target)
        if not existing[id] then
            insert_new(root, id, focused)
            existing[id] = true
            focused = focused or id
        end
    end

    root = normalize(root)
    state.trees[key] = root
    return root, by_id, key
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

local function layout_node(ctx, node, area, by_id)
    if is_leaf(node) then
        local target = by_id[node.id]
        if target then target:place(area) end
        return
    end
    local n = #node.children
    if n == 0 then return end
    local rects = slice(ctx, area, node.orient, n)
    for i, child in ipairs(node.children) do
        layout_node(ctx, child, rects[i], by_id)
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

    local leaf = { kind = "leaf", id = id }

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
    elseif command == "toggleorient" then
        return cmd_toggleorient(root, ctx)
    end
    return "nary: expected 'move <l|r|u|d>' or 'toggleorient'"
end

-- Exposed for the offline test harness; harmless under Hyprland.
local M = {
    state     = state,
    canon     = canon,
    dispatch  = dispatch,
    space_key = space_key,
    tree_for  = tree_for,
}

if hl and hl.layout then
    hl.layout.register("nary", {
        recalculate = function(ctx)
            local root, by_id = reconcile(ctx)
            layout_node(ctx, root, ctx.area, by_id)
        end,

        layout_msg = dispatch,
    })
end

return M
