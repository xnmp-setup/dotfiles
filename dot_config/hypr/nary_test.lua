-- Offline behaviour tests for nary.lua. No Hyprland required — the layout only
-- reads ctx.targets, so a stub context is enough to drive every command.
-- Run: lua nary_test.lua
--
-- These assert on the resulting layout (its canonical form), never on how the
-- tree happens to be built internally.

package.path = (arg[0]:match("^(.*)/") or ".") .. "/?.lua;" .. package.path

local nary = require("nary")

--------------------------------------------------------------------------------
-- Harness
--------------------------------------------------------------------------------

local function L(id) return { kind = "leaf", id = id } end

local function C(orient, ...)
    return { kind = "container", orient = orient, children = { ... } }
end

-- Every id in the tree becomes a target on workspace `ws`; `focus` is active.
local function ctx_for(root, focus, ws)
    local ids = {}
    local function walk(node)
        if node.kind == "leaf" then
            ids[#ids + 1] = node.id
            return
        end
        for _, child in ipairs(node.children) do walk(child) end
    end
    walk(root)

    local targets = {}
    for i, id in ipairs(ids) do
        targets[i] = {
            index  = i,
            window = { stable_id = id, active = (id == focus), workspace = { id = ws or 1 } },
        }
    end
    return { targets = targets }
end

-- Tabs: a context built from an explicit list of TILES rather than from the
-- tree. A tile is an id (a plain window) or a list of ids (a tabbed group,
-- first entry visible — which is all Hyprland shows the layout).
local function ctx_of(tiles, focus, ws)
    local targets = {}
    for i, tile in ipairs(tiles) do
        local ids     = (type(tile) == "table") and tile or { tile }
        local members = {}
        for j, id in ipairs(ids) do members[j] = { stable_id = id } end

        targets[i] = {
            index  = i,
            window = {
                stable_id = ids[1],
                active    = (ids[1] == focus),
                workspace = { id = ws or 1 },
                group     = (#ids > 1) and { members = members, size = #ids } or nil,
            },
        }
    end
    return { targets = targets }
end

local KEY = "ws:1"

local failures, checks = 0, 0

local function check(label, got, want)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        io.write(string.format("FAIL  %s\n        got  %s\n        want %s\n", label, tostring(got), tostring(want)))
    end
end

-- Apply `msg` repeatedly with `focus` held, checking the layout after each step.
local function steps(label, root, focus, msg, want)
    nary.state.trees[KEY] = root
    for i = 1, #want do
        nary.dispatch(ctx_for(nary.state.trees[KEY], focus), msg)
        check(string.format("%s [step %d]", label, i), nary.canon(nary.state.trees[KEY]), want[i])
    end
end

--------------------------------------------------------------------------------
-- The specified behaviour: h(h(1 2) 3), move window 1 right repeatedly
--------------------------------------------------------------------------------

steps("move right: swap in group, pop out, cross the row, join and cross the next",
    C("h", C("h", L("1"), L("2")), L("3")), "1", "move r", {
        "h(h(2 1) 3)",
        "h(2 1 3)",
        "h(2 h(1 3))",
        "h(2 h(3 1))",
        "h(2 3 1)",
    })

-- Moving left from the far end must retrace the same slots in reverse.
steps("move left is the exact inverse",
    C("h", L("2"), L("3"), L("1")), "1", "move l", {
        "h(2 h(3 1))",
        "h(2 h(1 3))",
        "h(2 1 3)",
        "h(h(2 1) 3)",
        "h(h(1 2) 3)",
        "h(1 2 3)",
    })

--------------------------------------------------------------------------------
-- Edges of the slot list
--------------------------------------------------------------------------------

steps("leftmost window cannot move further left",
    C("h", L("1"), L("2")), "1", "move l", { "h(1 2)" })

steps("rightmost window cannot move further right",
    C("h", L("1"), L("2")), "2", "move r", { "h(1 2)" })

steps("a lone window has nowhere to go",
    C("h", L("1")), "1", "move r", { "h(1)" })

steps("two windows swap, then stop",
    C("h", L("1"), L("2")), "1", "move r", { "h(2 1)", "h(2 1)" })

--------------------------------------------------------------------------------
-- N-ary is the point: peers stay peers, and every weighting is reachable
--------------------------------------------------------------------------------

steps("middle window of an equal-thirds row steps through its neighbour",
    C("h", L("1"), L("2"), L("3")), "2", "move r", {
        "h(1 h(2 3))",
        "h(1 h(3 2))",
        "h(1 3 2)",
    })

steps("four peers keep every intermediate slot",
    C("h", L("1"), L("2"), L("3"), L("4")), "1", "move r", {
        "h(h(1 2) 3 4)",
        "h(h(2 1) 3 4)",
        "h(2 1 3 4)",
        "h(2 h(1 3) 4)",
        "h(2 h(3 1) 4)",
        "h(2 3 1 4)",
    })

--------------------------------------------------------------------------------
-- Perpendicular containers are opaque to horizontal travel
--------------------------------------------------------------------------------

steps("a vertical stack is wrapped around, never walked into",
    C("h", L("1"), C("v", L("2"), L("3")), L("4")), "1", "move r", {
        "h(h(1 v(2 3)) 4)",
        "h(h(v(2 3) 1) 4)",
        "h(v(2 3) 1 4)",
    })

--------------------------------------------------------------------------------
-- Escaping a group rather than being trapped in it
--------------------------------------------------------------------------------

-- h(1 v(2 3)): 1 is a full-height column, 2 above 3 on the right. Nothing
-- outside the stack runs vertically, so 2 takes a band of its own across the
-- top and 1 and 3 share the row beneath.
steps("top of a stack moving up claims its own band",
    C("h", L("1"), C("v", L("2"), L("3"))), "2", "move u", {
        "v(2 h(1 3))",
    })

steps("bottom of a stack moving down claims its own band",
    C("h", L("1"), C("v", L("2"), L("3"))), "3", "move d", {
        "v(h(1 2) 3)",
    })

steps("a window already spanning the workspace has nowhere further to go",
    C("v", L("2"), C("h", L("1"), L("3"))), "2", "move u", {
        "v(2 h(1 3))",
    })

-- The escape is one level at a time: 3 leaves the horizontal pair it shares
-- with 4 and joins the vertical stack around it, rather than jumping to a band.
steps("escaping a nested pair joins the enclosing stack",
    C("h", L("1"), C("v", L("2"), C("h", L("3"), L("4")))), "3", "move u", {
        "h(1 v(2 3 4))",
    })

steps("escaping a nested pair downward lands below it",
    C("h", L("1"), C("v", L("2"), C("h", L("3"), L("4")))), "3", "move d", {
        "h(1 v(2 4 3))",
    })

--------------------------------------------------------------------------------
-- Vertical travel bootstraps an axis when none exists
--------------------------------------------------------------------------------

-- Creating an axis puts the window on the side it was sent towards: pressing up
-- must never leave it underneath. The second press then escapes to a band.
steps("move down in a flat row pairs with a sibling, landing underneath",
    C("h", L("1"), L("2"), L("3")), "1", "move d", {
        "h(v(2 1) 3)",
        "v(h(2 3) 1)",
    })

steps("move up in a flat row pairs with a sibling, landing on top",
    C("h", L("1"), L("2"), L("3")), "2", "move u", {
        "h(v(2 1) 3)",
        "v(2 h(1 3))",
    })

-- The neighbour may be a whole group; the window still lands above it.
steps("moving up beside a group puts the window on top of it",
    C("h", L("1"), C("h", L("2"), L("3"))), "1", "move u", {
        "v(1 h(2 3))",
    })

steps("moving down beside a group puts the window below it",
    C("h", L("1"), C("h", L("2"), L("3"))), "1", "move d", {
        "v(h(2 3) 1)",
    })

steps("inside a stack, down steps through it",
    C("h", C("v", L("1"), L("2"), L("3")), L("4")), "1", "move d", {
        "h(v(v(1 2) 3) 4)",
        "h(v(v(2 1) 3) 4)",
        "h(v(2 1 3) 4)",
    })

--------------------------------------------------------------------------------
-- Reconciliation with the windows Hyprland reports
--------------------------------------------------------------------------------

do
    -- A window that closed is dropped, and its now-single-child group collapses.
    nary.state.trees[KEY] = C("h", C("h", L("1"), L("2")), L("3"))
    nary.dispatch(ctx_for(C("h", L("2"), L("3")), "2"), "toggleorient")
    check("a closed window leaves the tree and its group collapses",
        nary.canon(nary.state.trees[KEY]), "v(2 3)")

    -- A window that appeared lands next to the focused one.
    nary.state.trees[KEY] = C("h", L("1"), L("2"))
    nary.dispatch(ctx_for(C("h", L("1"), L("2"), L("9")), "1"), "move r")
    check("a new window is adopted beside the focus",
        nary.canon(nary.state.trees[KEY]), "h(h(1 9) 2)")
end

do
    -- Hyprland runs one algorithm per space against this one Lua module, so
    -- laying out or moving on one workspace must not disturb another.
    nary.state.trees["ws:1"] = C("h", L("1"), L("2"))
    nary.state.trees["ws:2"] = C("h", L("7"), L("8"))

    nary.dispatch(ctx_for(C("h", L("7"), L("8")), "7", 2), "move r")

    check("moving on workspace 2 changes workspace 2",
        nary.canon(nary.state.trees["ws:2"]), "h(8 7)")
    check("moving on workspace 2 leaves workspace 1 untouched",
        nary.canon(nary.state.trees["ws:1"]), "h(1 2)")
end

--------------------------------------------------------------------------------
-- Tabs: a tile may hold several windows, and must not move when they change
--------------------------------------------------------------------------------

do
    -- Hyprland shows the layout only the visible tab, and recalculates on every
    -- tab switch. Identity that followed the visible window would make the tile
    -- teleport to the end of the row each time.
    nary.state.trees[KEY] = C("h", L("1"), L("2"), L("3"))
    nary.settle(ctx_of({ "1", { "2", "9" }, "3" }, "2"))
    nary.settle(ctx_of({ "1", { "9", "2" }, "3" }, "9"))
    check("cycling tabs leaves the tile where it was",
        nary.canon(nary.state.trees[KEY]), "h(1 2 3)")

    -- Same for losing one: the survivors keep the tile.
    nary.settle(ctx_of({ "1", "9", "3" }, "9"))
    check("closing a tab leaves the tile where it was",
        nary.canon(nary.state.trees[KEY]), "h(1 9 3)")
end

do
    -- Tabbing into a neighbour: two leaves, one target. The focused window is
    -- the one that moved, so the tile stays where the neighbour was.
    nary.state.trees[KEY] = C("h", L("1"), L("2"), L("3"))
    nary.settle(ctx_of({ "1", { "3", "2" } }, "3"))
    check("a window tabbed into its neighbour takes the neighbour's place",
        nary.canon(nary.state.trees[KEY]), "h(1 2)")
end

do
    -- And a whole tile travels as one when moved.
    nary.state.trees[KEY] = C("h", L("1"), L("2"))
    nary.settle(ctx_of({ "1", { "2", "9" } }, "9"))
    nary.dispatch(ctx_of({ "1", { "9", "2" } }, "9"), "move l")
    check("moving a tabbed tile moves the whole tile",
        nary.canon(nary.state.trees[KEY]), "h(2 1)")
    nary.settle(ctx_of({ "1", { "9", "2" } }, "9"))
    check("the tile keeps its identity across the move",
        nary.canon(nary.state.trees[KEY]), "h(2 1)")
end

--------------------------------------------------------------------------------
-- untab: the popped window lands beside the tile it left, on the named side
--------------------------------------------------------------------------------

-- Set up "a tile holding tabs 9 and 2 (9 in front), then 1", pop 9 out towards
-- `dir`, and report the resulting layout. The tile is deliberately NOT last in
-- the row: a window that merely got adopted would land at the end, so each
-- direction below is a claim about placement, not about adoption.
local function untab(dir, extra_settles)
    nary.state.trees[KEY] = C("h", L("2"), L("1"))
    nary.settle(ctx_of({ { "2", "9" }, "1" }, "9"))
    if dir then
        nary.dispatch(ctx_of({ { "9", "2" }, "1" }, "9"), "untab " .. dir)
    end
    for _ = 1, (extra_settles or 0) do
        nary.settle(ctx_of({ { "9", "2" }, "1" }, "9"))
    end
    nary.settle(ctx_of({ "2", "1", "9" }, "9"))
    return nary.canon(nary.state.trees[KEY])
end

check("a tab popped right lands directly right of its tile",  untab("r"), "h(2 9 1)")
check("a tab popped left lands directly left of its tile",    untab("l"), "h(9 2 1)")
check("a tab popped up lands directly above its tile",        untab("u"), "h(v(9 2) 1)")
check("a tab popped down lands directly below its tile",      untab("d"), "h(v(2 9) 1)")

-- Hyprland recalculates as soon as the message returns, before the window has
-- actually left the group; the intent has to outlive that pass.
check("the intent survives the recalculate that follows the message",
    untab("u", 2), "h(v(9 2) 1)")

-- Without a stated direction the window is merely adopted, not placed.
check("an untabbed window with no intent is adopted, not placed",
    untab(nil), "h(2 1 9)")

--------------------------------------------------------------------------------
-- explode: unfolding every tabbed tile in place, and folding it back
--------------------------------------------------------------------------------

-- Unfold the tile holding `tabs` (first one visible) out of `root` into a grid
-- `cols` wide, reporting the freed windows in `order`, and return the layout.
local function unfold(root, tabs, cols, order, focus)
    local folded = { "1", tabs }
    nary.state.trees[KEY] = root
    nary.settle(ctx_of(folded, focus))
    nary.dispatch(ctx_of(folded, focus), "explode " .. tabs[1] .. " " .. cols)
    nary.settle(ctx_of(folded, focus)) -- the message's own recalculate
    nary.settle(ctx_of(order, focus))  -- the group dissolved
    return nary.canon(nary.state.trees[KEY])
end

local THREE = { "2", "8", "9" }
local FOUR  = { "2", "8", "9", "7" }

check("tabs unfold where their tile was, in tab order",
    unfold(C("h", L("1"), L("2")), THREE, 3, { "1", "2", "8", "9" }, "1"),
    "h(1 h(2 8 9))")

check("a tile in a column unfolds inside its own slot, not across the column",
    unfold(C("v", L("1"), L("2")), THREE, 3, { "1", "2", "8", "9" }, "1"),
    "v(1 h(2 8 9))")

-- Which window keeps the tile must not depend on the order Hyprland happens to
-- report the freed windows in: it is the tab that was visible.
check("the unfolded tile stays with the tab that was visible",
    unfold(C("h", L("1"), L("2")), THREE, 3, { "8", "9", "2", "1" }, "1"),
    "h(1 h(2 8 9))")

-- The shape of the grid is the caller's to choose; the layout just fills it
-- row-major, and every row is a row of the tile's slot rather than of the tree
-- around it — so unfolding never steals space from the neighbours.
check("four tabs, two columns, land in a 2x2",
    unfold(C("h", L("1"), L("2")), FOUR, 2, { "1", "2", "8", "9", "7" }, "1"),
    "h(1 v(h(2 8) h(9 7)))")

check("four tabs in one column stack vertically",
    unfold(C("h", L("1"), L("2")), FOUR, 1, { "1", "2", "8", "9", "7" }, "1"),
    "h(1 v(2 8 9 7))")

check("four tabs in four columns stay a single row",
    unfold(C("h", L("1"), L("2")), FOUR, 4, { "1", "2", "8", "9", "7" }, "1"),
    "h(1 h(2 8 9 7))")

check("a ragged last row spans what is left of the width",
    unfold(C("h", L("1"), L("2")), THREE, 2, { "1", "2", "8", "9" }, "1"),
    "h(1 v(h(2 8) 9))")

do
    -- Folding back: each pane is merged into the tile, which stays put — this
    -- is the reconcile side of what the expose keybinding dispatches.
    nary.state.trees[KEY] = C("h", L("1"), L("2"), L("8"), L("9"))
    nary.settle(ctx_of({ "1", { "8", "2" }, "9" }, "8"))
    check("a pane folded back into its tile leaves the tile in place",
        nary.canon(nary.state.trees[KEY]), "h(1 2 9)")
end

--------------------------------------------------------------------------------
-- toggleorient and bad input
--------------------------------------------------------------------------------

steps("toggleorient flips the focused window's parent",
    C("h", L("1"), L("2")), "1", "toggleorient", { "v(1 2)", "h(1 2)" })

do
    nary.state.trees[KEY] = C("h", L("1"), L("2"))
    local ctx = ctx_for(nary.state.trees[KEY], "1")
    check("unknown command is rejected with a message",
        type(nary.dispatch(ctx, "wiggle")), "string")
    check("move with a bad direction is rejected",
        type(nary.dispatch(ctx, "move x")), "string")
    check("a rejected command leaves the layout alone",
        nary.canon(nary.state.trees[KEY]), "h(1 2)")
end

--------------------------------------------------------------------------------
-- Resize
--
-- Asserted on the boxes windows are actually given, not on the tree: weights are
-- an implementation detail, the geometry is the contract.
--------------------------------------------------------------------------------

-- A stand-in for Hyprland's own context: cuts boxes the way ctx:split does and
-- records where each window is put down.
local function geometry(tiles, focus, area)
    local ctx = ctx_of(tiles, focus)
    ctx.area = area or { x = 0, y = 0, w = 1000, h = 400 }

    function ctx:split(box, side, ratio)
        if side == "left"  then return { x = box.x, y = box.y, w = box.w * ratio, h = box.h } end
        if side == "right" then return { x = box.x + box.w * (1 - ratio), y = box.y, w = box.w * ratio, h = box.h } end
        if side == "top"   then return { x = box.x, y = box.y, w = box.w, h = box.h * ratio } end
        return { x = box.x, y = box.y + box.h * (1 - ratio), w = box.w, h = box.h * ratio }
    end

    local boxes = {}
    for _, target in ipairs(ctx.targets) do
        target.place = function(self, box) boxes[self.window.stable_id] = box end
    end
    return ctx, boxes
end

-- Round, so the checks read as pixels rather than as floating-point noise.
local function widths(boxes, ...)
    local out = {}
    for i, id in ipairs({ ... }) do out[i] = math.floor((boxes[id] and boxes[id].w or 0) + 0.5) end
    return table.concat(out, " ")
end

local function heights(boxes, ...)
    local out = {}
    for i, id in ipairs({ ... }) do out[i] = math.floor((boxes[id] and boxes[id].h or 0) + 0.5) end
    return table.concat(out, " ")
end

do
    nary.state.trees[KEY] = nil
    local ctx, boxes = geometry({ "1", "2", "3" }, "1")
    nary.recalculate(ctx)
    check("an untouched row splits evenly", widths(boxes, "1", "2", "3"), "333 333 333")

    nary.dispatch(ctx, "resize 90 0")
    nary.recalculate(ctx)
    check("resize widens the focused tile by the pixels asked for",
        widths(boxes, "1"), "423")
    check("its neighbours give up the width in proportion",
        widths(boxes, "2", "3"), "288 288")
end

do
    nary.state.trees[KEY] = nil
    local ctx, boxes = geometry({ "1", "2" }, "1")
    nary.recalculate(ctx)
    nary.dispatch(ctx, "resize -150 0")
    nary.recalculate(ctx)
    check("a negative delta shrinks it", widths(boxes, "1", "2"), "350 650")
end

do
    -- v(1 h(2 3)): resizing 2 horizontally must not disturb the row above it.
    nary.state.trees[KEY] = C("v", L("1"), C("h", L("2"), L("3")))
    local ctx, boxes = geometry({ "1", "2", "3" }, "2")
    nary.recalculate(ctx)
    nary.dispatch(ctx, "resize 100 0")
    nary.recalculate(ctx)
    check("resizing across an axis only touches the container running that way",
        widths(boxes, "2", "3"), "600 400")
    check("the perpendicular neighbour keeps its full width", widths(boxes, "1"), "1000")
    check("and every row keeps its height", heights(boxes, "1", "2", "3"), "200 200 200")
end

do
    nary.state.trees[KEY] = C("v", L("1"), C("h", L("2"), L("3")))
    local ctx, boxes = geometry({ "1", "2", "3" }, "2")
    nary.recalculate(ctx)
    nary.dispatch(ctx, "resize 0 60")
    nary.recalculate(ctx)
    check("the vertical delta is spent on the nearest vertical ancestor",
        heights(boxes, "1", "2"), "140 260")
end

do
    -- A tabbed group is one tile, so the strip resizes as a unit.
    nary.state.trees[KEY] = nil
    local ctx, boxes = geometry({ "1", { "2", "9" } }, "2")
    nary.recalculate(ctx)
    nary.dispatch(ctx, "resize 100 0")
    nary.recalculate(ctx)
    check("resizing a tab resizes its whole strip", widths(boxes, "1", "2"), "400 600")
end

do
    -- Nothing runs horizontally beside a lone tile, so there is no space to take.
    nary.state.trees[KEY] = nil
    local ctx, boxes = geometry({ "1" }, "1")
    nary.recalculate(ctx)
    nary.dispatch(ctx, "resize 200 200")
    nary.recalculate(ctx)
    check("a tile that already spans the workspace cannot grow",
        widths(boxes, "1") .. "/" .. heights(boxes, "1"), "1000/400")
end

do
    nary.state.trees[KEY] = nil
    local ctx, boxes = geometry({ "1", "2" }, "1")
    nary.recalculate(ctx)
    for _ = 1, 40 do nary.dispatch(ctx, "resize 200 0") end
    nary.recalculate(ctx)
    check("growing without limit still leaves the neighbour on screen",
        widths(boxes, "1", "2"), "950 50")

    for _ = 1, 80 do nary.dispatch(ctx, "resize -200 0") end
    nary.recalculate(ctx)
    check("and shrinking without limit leaves the tile itself on screen",
        widths(boxes, "1", "2"), "50 950")
end

do
    nary.state.trees[KEY] = nil
    local ctx = geometry({ "1", "2" }, "1")
    check("resize with a malformed argument is rejected",
        type(nary.dispatch(ctx, "resize wide")), "string")
    check("resize with a missing axis is rejected",
        type(nary.dispatch(ctx, "resize 50")), "string")
end

do
    -- Weight has to survive the tree being rearranged around it.
    nary.state.trees[KEY] = nil
    local ctx, boxes = geometry({ "1", "2", "3" }, "1")
    nary.recalculate(ctx)
    nary.dispatch(ctx, "resize 90 0")
    nary.dispatch(ctx, "move r")
    nary.recalculate(ctx)
    check("a resized tile keeps its share after being moved",
        widths(boxes, "1"), "423")
end

--------------------------------------------------------------------------------

io.write(string.format("%d checks, %d failures\n", checks, failures))
os.exit(failures == 0 and 0 or 1)
