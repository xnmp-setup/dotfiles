-- Offline contracts for the native drag adapter. Run: lua window_drag_test.lua
package.path = (arg[0]:match("^(.*)/") or ".") .. "/?.lua;" .. package.path
local drags = require("window_drag")
local checks = 0
local function check(label, got, want)
    checks = checks + 1
    assert(got == want, label .. ": got " .. tostring(got) .. ", want " .. tostring(want))
end
local function setup(floating, miss)
    local target = { stable_id = 7, mapped = true, floating = floating or false,
        layout = { name = "lua:nary" } }
    local other = { stable_id = 9, mapped = true, floating = false, layout = { name = "lua:nary" } }
    local active, pos = other, { x = 100, y = 100 }
    local callbacks, bindings, messages = {}, {}, {}
    local hl = {
        get_windows = function() return { target, other } end,
        get_active_window = function() return active end,
        get_cursor_pos = function() return pos end,
        dsp = { window = { drag = function() return function()
            if miss then return { ok = true, pass_event = true } end
            active = target
            target.floating = true
            return { ok = true, pass_event = false }
        end end }, layout = function(msg) return msg end },
        dispatch = function(msg)
            if type(msg) == "function" then return msg() end
            messages[#messages + 1] = msg
        end,
        bind = function(key, fn, opts) bindings[#bindings + 1] = { key = key, fn = fn, opts = opts } end,
        on = function(name, fn) callbacks[name] = fn end,
    }
    local control = drags.new(hl, "SUPER")
    local function pickup()
        control.begin()
        -- Native dispatch picks and focuses the target, including a decorated
        -- hit for which the adapter has no content rectangle to consult.
        bindings[2].fn()
    end
    return {
        target = target, control = control, callbacks = callbacks, bindings = bindings,
        messages = messages, pickup = pickup,
        move = function(x, y) pos = { x = x, y = y } end,
        retile = function() target.floating = false end,
    }
end
local c = setup()
c.pickup(); c.move(800, 300); c.retile(); c.control.finish()
check("release names the native hit target, regardless of earlier focus", c.messages[1], "drop 7 800 300")
c.control.finish(); check("a second release cannot drop twice", #c.messages, 1)
check("pickup observer precedes native dispatch", type(c.bindings[1].fn), "function")
check("native drag stays bound", type(c.bindings[2].fn), "function")
check("release survives modifier changes", c.bindings[3].opts.ignore_mods, true)

c = setup(); c.pickup(); c.move(800, 300); c.callbacks["input.keyboard.key"]()
c.move(900, 400); c.retile(); c.control.finish()
check("keyboard interruption uses the position at native drag end", c.messages[1], "drop 7 800 300")

c = setup(true); c.pickup(); c.move(800, 300); c.control.finish()
check("originally floating windows keep native free positioning", #c.messages, 0)
c = setup(); c.pickup(); c.move(800, 300); c.target.mapped = false; c.control.finish()
check("a closed window cannot be rearranged", #c.messages, 0)
c = setup(); c.pickup(); c.move(800, 300); c.callbacks["window.close"](c.target); c.retile(); c.control.finish()
check("close cancels a pending release", #c.messages, 0)
c = setup(); c.pickup(); c.move(102, 101); c.retile(); c.control.finish()
check("a click or tiny motion does not rearrange", #c.messages, 0)
c = setup(); c.pickup(); c.move(105, 100); c.retile(); c.control.finish()
check("the native threshold boundary does not rearrange", #c.messages, 0)
c = setup(); c.control.finish()
check("ordinary releases do not rearrange", #c.messages, 0)
c = setup(); c.pickup(); c.move(800, 300); c.retile(); c.target.layout = { name = "dwindle" }; c.control.finish()
check("changing layouts cancels the nary drop", #c.messages, 0)
c = setup(); c.pickup(); c.move(800, 300); c.retile()
c.target.group = { members = { c.target, { stable_id = 99 } } }; c.control.finish()
check("a native tab-strip join is not rearranged afterward", #c.messages, 0)
c = setup(false, true); c.pickup(); c.move(800, 300); c.control.finish()
check("dragging wallpaper does not rearrange the old focused window", #c.messages, 0)
print(checks .. " checks, 0 failures")
