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

io.write(string.format("%d checks, %d failures\n", checks, failures))
os.exit(failures == 0 and 0 or 1)
