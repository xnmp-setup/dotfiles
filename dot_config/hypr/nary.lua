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
-- Any node may carry a `weight` (default 1): its share of the parent's extent
-- along the parent's orientation, relative to its siblings. Weight is what
-- resizing moves, and it rides on the node itself rather than in a parallel
-- array on the parent, so every insert/remove keeps it correct for free.
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
-- UNDO IS ITS OWN KEY, NOT THE OPPOSITE ARROW
--
-- Stepping is its own inverse, but claiming a band and bootstrapping are not:
-- both rewrite the surrounding structure, so the opposite press computes
-- against a slot list the old layout is not in. Each move therefore records
-- what it came from, and `undo` walks that trail back. Any other edit to the
-- tree — a window opening or closing, toggleorient — abandons it.
--
-- Retracing used to be bound to the opposite arrow, and that was wrong. An
-- arrow would then mean two different things — "move it that way" and "put it
-- back" — which disagree after exactly the moves that need a trail, with
-- nothing on screen to say which one you were about to get. Worse, the arrow
-- reading has no ground truth to appeal to: measured over the ladder with no
-- trail at all, about one press in five does not move the tile the way the key
-- points, and one in ten moves it the opposite way. That is not a defect to be
-- fixed here — grouping and ungrouping trade a tile's SHARE for its POSITION,
-- and against a workspace edge there is no position left to trade, so the tile
-- can only grow the wrong way. A ladder over a tree is structural, not
-- spatial. Since no rule over directions can be honest about which meaning was
-- intended, the keybinding says which one outright.
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
-- PLACEMENT INTENTS
--
-- Where a departing window is put down is something the layout cannot infer:
-- Hyprland's own hint (the focal point passed to movedTarget) is dropped by the
-- Lua layout API. So the keybinding says it in advance. An intent names the
-- windows about to leave a tile and where they go as they arrive; it is
-- recorded during a command and spent during recalculate, and has to outlive
-- one of those, since Hyprland runs a recalculate as soon as the command
-- returns — before the keybinding has dispatched anything.
--
-- `enter` is the same idea for a window arriving from ANOTHER SPACE: a window
-- pushed off the edge of one monitor should come in at the edge it crossed,
-- as a division of the whole workspace, rather than beside whatever happens to
-- be focused over there. The intent is recorded against the space it is aimed
-- at, before the window is sent.
--
-- `untab` names one window and a side. `explode` names a tile and a column
-- count, unfolding its tabs into a grid that fills the tile's own slot, in tab
-- order, around the tab that was visible — which is how the whole workspace can
-- be unfolded into panes and folded back again. The grid is the point:
-- Hyprland can only build a group out of what lies in a DIRECTION, so folding
-- back means sending each pane at whatever the previous merges left behind.
--
-- Registered as "nary"; activate with general.layout = "lua:nary".
-- Commands (via hl.dsp.layout("<cmd>")):
--   move l|r|u|d    step the focused window one insertion slot along an axis
--   undo            walk back the last move on this workspace
--   resize <dx> <dy> grow/shrink the focused TILE by that many pixels per axis
--   untab l|r|u|d   when the focused tab next leaves its tile, put it that side
--   enter l|r|u|d <space>  a window is crossing into <space> travelling that
--                   way; land it as a division at the edge it comes in by
--   explode         unfold every tabbed tile in place as its tabs are freed
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
-- pending holds a workspace's placement intents: where windows that are about
-- to leave a tile should be put down when they arrive. See PLACEMENT INTENTS.
local state = { trees = {}, pending = {}, history = {} }

-- history is the undo trail, one stack per workspace: the layout as it stood
-- before each move, newest last. Deep enough to walk back a whole session's
-- fiddling, capped so a workspace left alone for a week cannot grow one
-- without bound.
local MAX_HISTORY = 64

local function new_root()
    return { kind = "container", orient = "h", children = {} }
end

-- ctx carries no space identity, so derive it from the windows being laid out.
-- Hyprland skips the Lua callback entirely when a space has no targets, so
-- there is always at least one window to ask.
local function space_of(ws_id) return "ws:" .. tostring(ws_id) end

local function space_key(ctx)
    for _, target in ipairs(ctx.targets) do
        local w  = target.window
        local ws = w and w.workspace
        if ws and ws.id then return space_of(ws.id) end
    end
    return space_of("unknown")
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
        return { kind = "leaf", id = node.id, ids = ids, weight = node.weight }
    end
    local children = {}
    for i, child in ipairs(node.children) do children[i] = copy(child) end
    return { kind = "container", orient = node.orient, children = children, weight = node.weight }
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
        if #kept == 1 then
            -- The survivor takes over the collapsed container's slot, so it must
            -- take its share of the parent too, or resizing a nested container
            -- would be undone the moment it lost a child.
            kept[1].weight = node.weight
            return kept[1]
        end
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
-- the side it was sent towards" rule as bootstrap_axis. Returns the container
-- the two now share, so a caller building a structure can carry on inside it.
--
-- `confine` splits the anchor's slot even when the surrounding container would
-- have taken the leaf as a peer: it is how a tile unfolds into a grid of its
-- own rather than spreading across the row it sits in.
local function insert_beside(root, anchor, ax, delta, leaf, confine)
    local parent, idx = parent_of(root, anchor)
    if not parent then return nil end

    if parent.orient == ax and not confine then
        table.insert(parent.children, idx + (delta > 0 and 1 or 0), leaf)
        return parent
    end

    local container = {
        kind     = "container",
        orient   = ax,
        children = (delta > 0) and { anchor, leaf } or { leaf, anchor },
    }
    parent.children[idx] = container
    return container
end

-- Where a window arriving from another space is put down: at one end of the
-- root, as a peer of everything already on the workspace. A tree that runs the
-- wrong way is pushed down a level first, so the arrival divides the workspace
-- rather than joining a row it was never part of.
local function place_at_edge(root, intent, leaf)
    if #root.children > 1 and root.orient ~= intent.ax then
        root.children = { { kind = "container", orient = root.orient, children = root.children } }
    end
    root.orient = intent.ax
    table.insert(root.children, (intent.delta > 0) and #root.children + 1 or 1, leaf)
    return true
end

-- Where a window that has left a tile is put down. An intent either names a
-- direction (untab: straight beside the tile) or a grid (explode: row-major
-- around it, the tile keeping cell 0, every row a row of the tile's own slot).
local function place_for(root, intent, leaf)
    if not intent.cols then
        local shared = insert_beside(root, intent.after, intent.ax, intent.delta, leaf)
        if shared then intent.after = leaf end
        return shared
    end

    local k    = intent.placed + 1
    local cols = intent.cols

    if k % cols == 0 then
        -- Opening a row, under the whole block built so far. The first one has
        -- to carve the tile's slot out; later rows are peers within it.
        if not insert_beside(root, intent.row, "v", 1, leaf, k == cols) then return nil end
        intent.row, intent.cell = leaf, leaf
    else
        local row = insert_beside(root, intent.cell, "h", 1, leaf, k == 1)
        if not row then return nil end
        intent.cell, intent.row = leaf, row
    end

    intent.placed = k
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

    local intents = state.pending[key]

    local holder, in_tree = {}, {}
    for _, leaf in ipairs(collect_leaves(root, {})) do
        in_tree[leaf] = true
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

    local function take(entry, leaf)
        claimed[leaf] = true
        place[leaf]   = entry.target
        entry.taken   = true
        if not has_id(entry.ids, leaf.id) then leaf.id = entry.ids[1] end
        leaf.ids = entry.ids
    end

    -- An unfolding tile stays with the tab that was visible on it, whatever
    -- order its windows are reported in, so the rest can be laid out around it.
    if intents then
        for _, intent in ipairs(intents) do
            if intent.keeper and in_tree[intent.origin] and not claimed[intent.origin] then
                for _, entry in ipairs(entries) do
                    if not entry.taken and entry.ids[1] == intent.keeper then
                        take(entry, intent.origin)
                        break
                    end
                end
            end
        end
    end

    for _, entry in ipairs(entries) do
        if not entry.taken then
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
                take(entry, pick)
            else
                arrived[#arrived + 1] = entry
            end
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

    local anchor_focus = focused
    for _, entry in ipairs(arrived) do
        local leaf   = { kind = "leaf", id = entry.ids[1], ids = entry.ids }
        local placed = false

        -- A window an intent was waiting for: put it beside the last one placed
        -- for that tile, so a tile unfolds in order rather than in a heap.
        if settling and intents then
            for _, intent in ipairs(intents) do
                if not intent.edge and claimed[intent.origin] then
                    for _, id in ipairs(entry.ids) do
                        if intent.ids[id] then
                            placed = place_for(root, intent, leaf)
                            if placed then intent.ids[id] = nil end
                            break
                        end
                    end
                end
                if placed then break end
            end

            -- A window from another space, if nothing on this one was expecting
            -- it: it crossed a monitor boundary, so it comes in at that edge.
            if not placed then
                for _, intent in ipairs(intents) do
                    if intent.edge then
                        placed = place_at_edge(root, intent, leaf)
                        intent.spent = true
                        break
                    end
                end
            end
        end

        if not placed then insert_new(root, leaf, anchor_focus) end

        place[leaf]  = entry.target
        anchor_focus = anchor_focus or entry.ids[1]
    end

    -- An intent lives while windows it is waiting for are still on their tile.
    -- The pass where that stops being true is the one it was recorded for: it
    -- is spent there, and whatever is left of it is discarded rather than
    -- carried any further.
    if settling and intents then
        local kept = {}
        for _, intent in ipairs(intents) do
            if intent.edge then
                -- An arrival intent names a window that is not here yet, so no
                -- tile can vouch for it. It is bounded by passes instead: long
                -- enough to outlive the recalculate the message itself causes,
                -- short enough not to catch some later, unrelated window.
                intent.grace = intent.grace - 1
                if not intent.spent and intent.grace > 0 then kept[#kept + 1] = intent end
            elseif claimed[intent.origin] then
                for id in pairs(intent.ids) do
                    if leaf_holds(intent.origin, id) then
                        kept[#kept + 1] = intent
                        break
                    end
                end
            end
        end
        state.pending[key] = (#kept > 0) and kept or nil
    end

    root = normalize(root)
    state.trees[key] = root
    return root, place, key
end

--------------------------------------------------------------------------------
-- Placement: split an area into N slices using only ctx:split
--------------------------------------------------------------------------------

-- Each child's share of its parent. Absent weights mean "an equal share", which
-- is what an untouched tree is made of.
local function weights(children)
    local out, total = {}, 0
    for i, child in ipairs(children) do
        local w = child.weight
        if not w or w ~= w or w <= 0 then w = 1 end -- also rejects NaN
        out[i] = w
        total  = total + w
    end
    return out, total
end

-- Peel children off `area` one at a time, each taking its weight's share of
-- whatever is left. Working on the remainder rather than on the whole keeps this
-- expressible in ctx:split, which only ever cuts a box in two.
local function slice(ctx, area, orient, children)
    local first = (orient == "v") and "top" or "left"
    local rest  = (orient == "v") and "bottom" or "right"
    local ws, remaining_weight = weights(children)

    local rects, remaining = {}, area
    for i = 1, #children do
        if i == #children then
            rects[i] = remaining
        else
            local frac = ws[i] / remaining_weight
            rects[i]  = ctx:split(remaining, first, frac)
            remaining = ctx:split(remaining, rest, 1 - frac)
            remaining_weight = remaining_weight - ws[i]
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
    if #node.children == 0 then return end
    local rects = slice(ctx, area, node.orient, node.children)
    for i, child in ipairs(node.children) do
        layout_node(ctx, child, rects[i], place)
    end
end

-- The pixel extent every node on the chain from root to `leaf` occupies, so a
-- resize expressed in pixels can be turned into one expressed in weight. Same
-- arithmetic slice() does, minus the gaps Hyprland insets afterwards — near
-- enough, since the answer only scales a step the user is watching anyway.
local function extents_along(root, area, chain, idxs)
    local out = {}
    local w, h = area.w or 0, area.h or 0

    for depth, node in ipairs(chain) do
        local ws, total = weights(node.children)
        local frac = (total > 0) and (ws[idxs[depth]] / total) or 1

        -- The container's own extent along its orientation is what the child is
        -- taking a share of.
        out[depth] = (node.orient == "h") and w or h

        if node.orient == "h" then w = w * frac else h = h * frac end
    end
    return out
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

local function history_for(key)
    local hist = state.history[key]
    if not hist then
        hist = {}
        state.history[key] = hist
    end
    return hist
end

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
    local hist    = history_for(key)

    -- Anything else that touched the tree since our last move — a window
    -- opening or closing, toggleorient — means the trail no longer describes
    -- this layout, so it cannot be walked back.
    if #hist > 0 and hist[#hist].result ~= current then
        hist = {}
        state.history[key] = hist
    end

    -- Record what we came from, so `undo` can retrace it. A move that changes
    -- nothing is not worth remembering: pressing into the far edge repeatedly
    -- would otherwise bury the move that is actually worth walking back.
    local function commit(after)
        local fingerprint = canon(after)
        if fingerprint ~= current then
            hist[#hist + 1] = { tree = copy(root), result = fingerprint }
            if #hist > MAX_HISTORY then table.remove(hist, 1) end
        end
        state.trees[key] = after
        return true
    end

    local work = copy(root)

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
            return commit(normalize(work))
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
        return commit(normalize(work))
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
            return commit(target)
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
    return commit(normalize({
        kind     = "container",
        orient   = ax,
        children = (delta > 0) and { work, leaf } or { leaf, work },
    }))
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

    state.pending[key] = { {
        origin = leaf, after = leaf, ax = ax, delta = delta, ids = { [id] = true },
    } }
    return true
end

-- A window is about to be sent into <space> travelling in <dir>: park it at the
-- edge it comes in by — the far side from where it is heading — as a division
-- of that whole workspace. Nothing moves here; the caller sends the window.
--
-- The space is named rather than derived, because the command necessarily runs
-- while the window is still on the space it is leaving.
local function cmd_enter(args)
    local dir, space = args:match("^(%S+)%s+(%S+)$")
    local ax, delta  = AXIS[dir or ""], DELTA[dir or ""]
    if not (ax and space) then return "nary: enter expects '<l|r|u|d> <space>'" end

    local intents = state.pending[space] or {}
    for i = #intents, 1, -1 do -- one arrival at a time; a repeat replaces it
        if intents[i].edge then table.remove(intents, i) end
    end

    intents[#intents + 1] = { edge = true, ax = ax, delta = -delta, grace = 2 }
    state.pending[space] = intents
    return true
end

-- The tile holding <window> is about to be dissolved into its windows: unfold
-- them into a <columns>-wide grid filling that tile's slot, in tab order, with
-- the tab that was visible keeping cell 0. Caller picks the column count, since
-- it depends on the tile's proportions and it also decides the direction each
-- pane is sent back in when the grid is folded up again.
local function cmd_explode(root, key, args)
    local id, cols = args:match("^(%S+)%s+(%d+)$")
    if not id then return "nary: explode expects '<window id> <columns>'" end

    cols = math.max(1, math.tointeger(tonumber(cols)) or 1)

    local leaf = find_leaf(root, id)
    if not leaf then return true end

    local ids = leaf_ids(leaf)
    if #ids < 2 then return true end -- not a tab strip: nothing will leave

    local waiting = {}
    for i = 2, #ids do waiting[ids[i]] = true end

    local intents = state.pending[key] or {}
    for i = #intents, 1, -1 do -- one intent per tile; a repeat replaces it
        if intents[i].origin == leaf then table.remove(intents, i) end
    end

    intents[#intents + 1] = {
        origin = leaf, row = leaf, cell = leaf, placed = 0,
        cols   = cols,
        ids    = waiting,
        keeper = ids[1],
    }
    state.pending[key] = intents
    return true
end

-- Grow or shrink the focused TILE by (dx, dy) pixels. A tile is one leaf, and a
-- tabbed group is one tile, so this resizes the whole strip rather than the tab
-- that happens to be showing.
--
-- Each axis is spent on the innermost ancestor running along it: widening takes
-- width from the tile's horizontal neighbours and leaves the rows above and
-- below untouched. An axis with no such ancestor has nothing to take from — the
-- tile already spans the workspace that way — and is skipped.
--
-- Siblings give up (or take back) space in proportion to what they already
-- have, so repeatedly growing one tile never singles a neighbour out.
local MIN_SHARE = 0.05

local function cmd_resize(root, ctx, args)
    local sx, sy = args:match("^(-?%d+)%s+(-?%d+)$")
    if not sx then return "nary: resize expects '<dx> <dy>' in pixels" end

    local id = active_id(ctx)
    if not id then return true end

    local nodes, idxs = chain_to(root, id)
    if not nodes then return true end

    local extent = extents_along(root, ctx.area, nodes, idxs)

    for _, axis in ipairs({ { ax = "h", delta = tonumber(sx) }, { ax = "v", delta = tonumber(sy) } }) do
        if axis.delta ~= 0 then
            local si
            for i = #nodes, 1, -1 do
                if nodes[i].orient == axis.ax then si = i break end
            end

            local px = si and extent[si]
            if si and px and px > 0 then
                local parent   = nodes[si]
                local idx      = idxs[si]
                local ws, total = weights(parent.children)
                local rest      = total - ws[idx]

                -- Only one child: it already fills the container, and there is
                -- no sibling to take the pixels from.
                if rest > 0 then
                    local cap  = 1 - MIN_SHARE * (#parent.children - 1)
                    local want = ws[idx] / total + axis.delta / px
                    want = math.max(MIN_SHARE, math.min(cap, want))

                    -- Weights are relative, so pin the siblings' total and solve
                    -- for the weight that gives this child the share it wants.
                    parent.children[idx].weight = want * rest / (1 - want)
                end
            end
        end
    end
    return true
end

-- Walk the trail back one move. Pressing it repeatedly keeps walking: each
-- entry restores the layout the one above it was made from, so the stack stays
-- consistent with the tree as it unwinds.
--
-- Which window is focused is deliberately not consulted. The trail belongs to
-- the workspace, and a key that means "put that back" should undo the last
-- thing that happened here, not the last thing that happened to whatever the
-- mouse is currently over.
local function cmd_undo(root, key)
    local hist = history_for(key)
    local last = hist[#hist]

    -- The trail describes one specific layout; if anything else has edited the
    -- tree since, restoring it would resurrect windows that have moved on.
    if not last or last.result ~= canon(root) then
        state.history[key] = {}
        return true
    end

    state.trees[key] = last.tree
    hist[#hist] = nil
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
    local command, args = msg:match("^%s*(%S+)%s*(.-)%s*$")
    if command == "move" then
        return cmd_move(root, key, ctx, args)
    elseif command == "undo" then
        return cmd_undo(root, key)
    elseif command == "resize" then
        return cmd_resize(root, ctx, args)
    elseif command == "untab" then
        return cmd_untab(root, key, ctx, args)
    elseif command == "enter" then
        return cmd_enter(args)
    elseif command == "explode" then
        return cmd_explode(root, key, args)
    elseif command == "toggleorient" then
        return cmd_toggleorient(root, ctx)
    end
    return "nary: expected 'move <l|r|u|d>', 'undo', 'resize <dx> <dy>', " ..
           "'untab <l|r|u|d>', 'enter <l|r|u|d> <space>', " ..
           "'explode <window> <columns>' or 'toggleorient'"
end

-- Drop every trail: what has been moved so far is now settled and cannot be
-- walked back. Every space, not just the focused one — a move can hand a window
-- to another monitor, so a boundary drawn on one space has to end them all.
--
-- CURRENTLY UNUSED, deliberately. This was the seam for scoping undo to the
-- keypress gesture that made it, called when the modifiers holding a move down
-- were released. Undo now has a key of its own, which is not held down and so
-- has no gesture to be scoped to, and the config no longer registers the
-- release binds that called this (see UNDO in hyprland.lua). Kept because the
-- boundary is a real one and cheap to re-draw: something that ends a run of
-- moves — a submap exit, an idle timeout — wants exactly this.
local function end_move()
    state.history = {}
end

local function recalculate(ctx)
    local root, place = reconcile(ctx, true)
    layout_node(ctx, root, ctx.area, place)
end

-- Exposed for the offline test harness, plus the two the config itself uses:
-- `space` to name a workspace's tree (an `enter` intent is aimed at a space the
-- keybinding is not on), and `shape` to tell a command that rearranged the
-- workspace from one that ran out of room and should cross to the next monitor.
local M = {
    state       = state,
    canon       = canon,
    dispatch    = dispatch,
    space       = space_of,
    -- Ends every undo trail. Wired to nothing today; see its definition.
    end_move    = end_move,
    shape       = function(key)
        local root = state.trees[key]
        return root and canon(root) or ""
    end,
    -- The full pass, so tests can assert on the geometry windows are given
    -- rather than on the shape of the tree behind it.
    recalculate = recalculate,
    -- What recalculate does, minus the placing: the pass that settles arrivals.
    settle      = function(ctx) return reconcile(ctx, true) end,
}

if hl and hl.layout then
    hl.layout.register("nary", {
        recalculate = recalculate,
        layout_msg  = dispatch,
    })
end

return M
