-- Offline behavior tests for focus-sensitive desktop features.
-- Run: lua desktop_test.lua

package.path = (arg[0]:match("^(.*)/") or ".") .. "/?.lua;" .. package.path

local app_switcher   = require("app_switcher")
local display_mirrors = require("display_mirror")
local exposes        = require("expose")
local group_actions  = require("group_actions")
local host_capabilities = require("host_capabilities")
local nightlights     = require("nightlight")
local scratchpads    = require("scratchpad")
local spotlights     = require("spotlight")
local startup_pairing = require("startup_pairing")
local terminal_groups = require("terminal_grouping")
local window_actions = require("window_actions")
local window_model   = require("window_model")
local window_navigation = require("window_navigation")
local window_resize  = require("window_resize")

local checks, failures = 0, 0

local function check(label, value)
    checks = checks + 1
    if value then return end
    failures = failures + 1
    io.write("FAIL  " .. label .. "\n")
end

local function equal(label, got, want)
    check(("%s (got %s, want %s)"):format(label, tostring(got), tostring(want)), got == want)
end

local function window(id, class, workspace, history)
    return {
        address = "address:" .. id,
        stable_id = id,
        mapped = true,
        class = class,
        workspace = workspace,
        focus_history_id = history,
        at = { x = 0, y = 0 },
        size = { x = 100, y = 100 },
    }
end

-- Takes the members as a list, so the large-group case below does not have to
-- unpack ten thousand of them onto the stack (LuaJIT refuses well before that).
local function group_of(members)
    local value = {
        current = members[1],
        current_index = 1,
        members = members,
        size = #members,
    }
    for _, member in ipairs(members) do member.group = value end
    return value
end

local function group(...)
    return group_of({ ... })
end

local function fake_runtime(spec)
    spec = spec or {}
    local active = spec.active
    local windows = spec.windows or {}
    local normal_workspace = spec.workspace or { id = 1, name = "1" }
    local special_workspace
    local callbacks, timers, dispatches, executions, configs, monitors = {}, {}, {}, {}, {}, {}
    local bindings = {}
    local active_monitor = spec.active_monitor or {
        id = 0,
        x = 0,
        y = 0,
        active_workspace = normal_workspace,
        width = spec.monitor_width or 3440,
        height = spec.monitor_height or 1440,
        scale = spec.monitor_scale or 1,
    }

    local function command(kind)
        return function(args) return { kind = kind, args = args } end
    end

    local hl = {
        dsp = {
            -- The only dispatcher taking a second argument: the window rules applied
            -- to whatever the command opens.
            exec_cmd = function(cmd, rules)
                return { kind = "exec", args = cmd, rules = rules }
            end,
            focus = command("focus"),
            group = {
                active = command("group_active"),
                toggle = command("group_toggle"),
            },
            layout = command("layout"),
            window = {
                center = command("center"),
                float = command("float"),
                move = command("move"),
                resize = command("resize"),
            },
            workspace = { toggle_special = command("toggle_special") },
        },
        exec_cmd = function(cmd, options)
            executions[#executions + 1] = { cmd = cmd, options = options }
        end,
        config = function(value) configs[#configs + 1] = value end,
        get_active_monitor = function()
            active_monitor.active_special_workspace = special_workspace
            return active_monitor
        end,
        get_active_window = function() return active end,
        get_active_workspace = function() return normal_workspace end,
        get_cursor_pos = function() return spec.cursor end,
        get_monitors = function()
            active_monitor.active_special_workspace = special_workspace
            return spec.monitors or { active_monitor }
        end,
        get_windows = function() return windows end,
        monitor = function(value) monitors[#monitors + 1] = value end,
        on = function(event, callback)
            callbacks[event] = callbacks[event] or {}
            callbacks[event][#callbacks[event] + 1] = callback
        end,
        timer = function(callback, options)
            timers[#timers + 1] = { callback = callback, timeout = options.timeout }
        end,
        bind = function(key, callback) bindings[key] = callback end,
        unbind = function(key) bindings[key] = nil end,
    }

    function hl.dispatch(value)
        dispatches[#dispatches + 1] = value
        local args = value.args or {}

        if value.kind == "focus" then
            active = args.window
        elseif value.kind == "group_active" then
            local target_group = args.window and args.window.group
            if target_group then
                target_group.current_index = args.index
                target_group.current = target_group.members[args.index]
                active = target_group.current
            end
        elseif value.kind == "float" and args.window then
            args.window.floating = args.action == "on"
        elseif value.kind == "toggle_special" then
            if special_workspace then
                special_workspace = nil
                if spec.fallback_on_hide then
                    active = spec.fallback_on_hide
                    local fallback_group = active.group
                    if fallback_group then
                        fallback_group.current = active
                        fallback_group.current_index = window_model.group_index(active)
                    end
                end
            else
                special_workspace = spec.special_workspace
                    or { id = -94, name = "special:" .. tostring(args) }
            end
        elseif value.kind == "move" and args.window and args.workspace then
            if tostring(args.workspace):match("^special:") then
                args.window.workspace = spec.special_workspace
                    or { id = -94, name = args.workspace }
            else
                args.window.workspace = {
                    id = tonumber(args.workspace),
                    name = tostring(args.workspace),
                }
            end
            if args.follow then active = args.window end
        end
    end

    local control = {
        active = function() return active end,
        binding = function(key) return bindings[key] end,
        configs = configs,
        dispatches = dispatches,
        emit = function(event, argument)
            for _, callback in ipairs(callbacks[event] or {}) do callback(argument) end
        end,
        executions = executions,
        monitors = monitors,
        remove_window = function(target)
            for index = #windows, 1, -1 do
                if windows[index] == target then table.remove(windows, index) end
            end
        end,
        run_timer = function(timeout)
            for index, timer in ipairs(timers) do
                if timer and timer.timeout == timeout then
                    timers[index] = false
                    timer.callback()
                    return true
                end
            end
            return false
        end,
        set_active = function(value) active = value end,
        special_shown = function() return special_workspace ~= nil end,
    }

    return hl, control
end

--------------------------------------------------------------------------------
-- Host capabilities
--------------------------------------------------------------------------------

do
    check("a BAT power supply identifies a laptop",
        host_capabilities.has_battery(function(path)
            if path:match("/BAT3/type$") then return "Battery" end
        end))
    check("a CMB power supply identifies a laptop",
        host_capabilities.has_battery(function(path)
            if path:match("/CMB1/type$") then return "Battery" end
        end))
    check("mains power is not a battery",
        not host_capabilities.has_battery(function() return "Mains" end))
    check("missing power supplies identify a desktop",
        not host_capabilities.has_battery(function() return nil end))
end

--------------------------------------------------------------------------------
-- Night light
--------------------------------------------------------------------------------

do
    local laptop = nightlights.command(true)
    check("laptops use the pre-clone shader", laptop:match("hyprshade auto") ~= nil)
    check("laptop shader exports its Hyprland instance",
        laptop:match("HYPRLAND_INSTANCE_SIGNATURE") ~= nil)
    check("laptop shader does not start wlsunset", laptop:match("wlsunset") == nil)

    local desktop = nightlights.command(false)
    check("desktops retain solar-time wlsunset", desktop:match("^wlsunset") ~= nil)
    check("desktops do not start hyprshade", desktop:match("hyprshade") == nil)
end

--------------------------------------------------------------------------------
-- Display mirroring
--------------------------------------------------------------------------------

do
    equal("no display pair exists without monitors", display_mirrors.plan(nil), nil)
    equal("a panel alone stays a normal output",
        display_mirrors.plan({ { name = "eDP-1" } }), nil)
    equal("an external alone stays a normal output",
        display_mirrors.plan({ { name = "DP-2" } }), nil)
    equal("malformed output names are ignored",
        display_mirrors.plan({ { name = "eDP-1" }, { name = "DP-2; reboot" } }), nil)

    local plan = display_mirrors.plan({
        { name = "DP-2" },
        { name = "eDP-1" },
        { name = "HDMI-A-1" },
    })
    equal("the built-in panel is the mirror target", plan.target, "eDP-1")
    equal("external selection is deterministic", plan.source, "DP-2")

    local many = { { name = "eDP-1" } }
    for index = 10000, 1, -1 do
        many[#many + 1] = { name = ("DP-%05d"):format(index) }
    end
    equal("large output lists retain deterministic selection",
        display_mirrors.plan(many).source, "DP-00001")
end

do
    local hl, control = fake_runtime({ monitors = { { name = "DP-1" } } })
    display_mirrors.new(hl)
    control.emit("hyprland.start")
    equal("desktop-only systems have no mirroring side effects", #control.monitors, 0)
end

do
    local hl, control = fake_runtime({ monitors = {
        { name = "eDP-1" },
        { name = "DP-2" },
    } })
    display_mirrors.new(hl, { enabled = false })
    control.emit("hyprland.start")
    equal("battery capability gates laptop mirroring", #control.monitors, 0)
end

do
    local outputs = { { name = "eDP-1" } }
    local hl, control = fake_runtime({ monitors = outputs })
    display_mirrors.new(hl)

    equal("registration has no eager side effects", #control.executions, 0)
    control.emit("hyprland.start")
    equal("panel-alone startup configures one output", #control.monitors, 1)
    equal("panel-alone startup targets the panel", control.monitors[1].output, "eDP-1")
    equal("panel-alone startup has no mirror", control.monitors[1].mirror, nil)

    outputs[2] = { name = "HDMI-A-3" }
    control.emit("monitor.added", outputs[2])
    equal("hotplug configures source and follower", #control.monitors, 3)
    equal("external owns the source canvas", control.monitors[2].output, "HDMI-A-3")
    equal("built-in panel is the follower", control.monitors[3].output, "eDP-1")
    equal("built-in panel mirrors the external", control.monitors[3].mirror, "HDMI-A-3")

    outputs[2] = nil
    control.emit("monitor.removed", { name = "HDMI-A-3" })
    equal("unplug restores one standalone panel spec", #control.monitors, 4)
    equal("unplug restores the built-in panel", control.monitors[4].output, "eDP-1")
    equal("unplug removes the mirror source", control.monitors[4].mirror, nil)
end

--------------------------------------------------------------------------------
-- Pure window model
--------------------------------------------------------------------------------

do
    local ws = { id = 1 }
    local chrome = window("chrome", "google-chrome", ws)
    local obsidian = window("obsidian", "obsidian", ws)
    local tabs = group(chrome, obsidian)

    equal("stable ID defines identity", window_model.id(chrome), "chrome")
    check("same window compares stable IDs",
        window_model.same(chrome, { stable_id = "chrome" }))
    equal("group index follows member order", window_model.group_index(obsidian), 2)

    local exact = window_model.exact_focus_plan(obsidian)
    equal("exact focus plans the hidden member index", exact.group.index, 2)
    equal("exact focus targets the current group anchor", exact.group.window, chrome)

    local next_plan = window_model.next_group_plan(chrome)
    equal("next group plan advances one member", next_plan.index, 2)
    tabs.current, tabs.current_index = obsidian, 2
    equal("next group plan wraps", window_model.next_group_plan(obsidian).index, 1)

    chrome.mapped = false
    equal("unmapped windows have no focus plan",
        window_model.exact_focus_plan(chrome), nil)
    equal("nil windows have no focus plan",
        window_model.exact_focus_plan(nil), nil)
    check("nil windows never compare equal", not window_model.same(nil, nil))
    equal("ungrouped windows have no next-group plan",
        window_model.next_group_plan(window("plain", "plain", ws)), nil)
end

-- Going back is not the same as going forward: with three tabs the one after
-- the focused window in strip order is rarely the one it replaced on screen.
do
    local ws = { id = 1 }
    local terminal = window("terminal", "org.wezfurlong.wezterm", ws, 1)
    local chrome = window("chrome", "google-chrome", ws, 0)
    local obsidian = window("obsidian", "obsidian", ws, 2)
    local tabs = group(terminal, chrome, obsidian)
    tabs.current, tabs.current_index = chrome, 2
    local windows = { terminal, chrome, obsidian }

    equal("previous group plan returns to the last focused member",
        window_model.previous_group_plan(chrome, windows).index, 1)
    equal("next group plan would instead advance past it",
        window_model.next_group_plan(chrome).index, 3)
    equal("previous group plan anchors on the shown tab",
        window_model.previous_group_plan(chrome, windows).window, chrome)

    -- Focus moving on flips which tab each key goes back to.
    terminal.focus_history_id, chrome.focus_history_id = 0, 1
    tabs.current, tabs.current_index = terminal, 1
    equal("previous group plan follows the updated focus history",
        window_model.previous_group_plan(terminal, windows).index, 2)

    equal("ungrouped windows have no previous-group plan",
        window_model.previous_group_plan(window("plain", "plain", ws, 0), windows), nil)

    -- Members carry their own history when no window list is supplied.
    local left = window("left", "app", ws, 3)
    local right = window("right", "app", ws, 0)
    group(left, right)
    equal("group members supply their own focus history",
        window_model.previous_group_plan(right).index, 1)

    -- A group nobody has focused yet has nothing to go back to; the caller
    -- falls back to advancing a tab.
    local fresh_a = window("fresh-a", "app", ws)
    local fresh_b = window("fresh-b", "app", ws)
    group(fresh_a, fresh_b)
    equal("members without focus history have no previous-group plan",
        window_model.previous_group_plan(fresh_a, { fresh_a, fresh_b }), nil)
end

do
    local ws = { id = 1 }
    local members = {}
    for index = 1, 10000 do
        members[index] = window(tostring(index), "test", ws)
    end
    local tabs = group_of(members)
    tabs.current, tabs.current_index = members[#members], #members
    equal("large groups wrap without scanning past their bounds",
        window_model.next_group_plan(members[#members]).index, 1)
end

--------------------------------------------------------------------------------
-- Window action adapter
--------------------------------------------------------------------------------

do
    local ws = { id = 1 }
    local chrome = window("chrome", "google-chrome", ws)
    local obsidian = window("obsidian", "obsidian", ws)
    group(chrome, obsidian)
    local hl, control = fake_runtime({
        active = chrome,
        windows = { chrome, obsidian },
        workspace = ws,
    })
    local actions = window_actions.new(hl)

    check("exact grouped focus succeeds", actions.focus_exact(obsidian))
    equal("exact grouped focus selects the requested tab", control.active(), obsidian)
    equal("exact grouped focus dispatches group then focus",
        control.dispatches[1].kind .. "," .. control.dispatches[2].kind,
        "group_active,focus")
end

--------------------------------------------------------------------------------
-- Startup pairing
--------------------------------------------------------------------------------

do
    local ws = { id = 1 }
    local browser = window("browser", "google-chrome", ws)
    local notes = window("notes", "obsidian", ws)
    browser.at = { x = 0, y = 0 }
    notes.at = { x = 100, y = 0 }
    local hl, control = fake_runtime({
        windows = { browser, notes },
        workspace = ws,
    })
    local pairing = startup_pairing.new(hl, {
        browser_class = "google-chrome",
        notes_class = "obsidian",
        workspace = 1,
    })

    control.emit("window.open", browser)
    equal("startup pairing is inert until started", #control.executions, 0)

    pairing.start()
    control.emit("window.open", { class = "unrelated" })
    equal("startup pairing ignores unrelated windows", #control.executions, 0)
    control.emit("window.open", browser)
    equal("browser startup launches notes", control.executions[1].cmd, "obsidian")
    equal("startup notes launch targets the configured workspace",
        control.executions[1].options.workspace, "1")

    control.emit("window.open", notes)
    check("startup pairing stays in flight until the merge fires",
        pairing.is_waiting())
    check("startup merge waits for layout placement", control.run_timer(120))
    equal("startup pairing moves notes toward browser",
        control.dispatches[1].args.into_or_create_group, "left")
    equal("startup pairing moves the notes window",
        control.dispatches[1].args.window, notes)
    check("startup pairing completes after one pair", not pairing.is_waiting())
end

equal("window direction rejects incomplete geometry",
    window_model.direction_towards({}, {}), nil)
do
    local from = { at = { x = 100, y = 100 }, size = { x = 20, y = 20 } }
    equal("window direction uses horizontal centres",
        window_model.direction_towards(from, {
            at = { x = 0, y = 105 },
            size = { x = 20, y = 20 },
        }), "left")
    equal("window direction uses vertical centres",
        window_model.direction_towards(from, {
            at = { x = 105, y = 200 },
            size = { x = 20, y = 20 },
        }), "down")
end

--------------------------------------------------------------------------------
-- Group lifecycle
--------------------------------------------------------------------------------

do
    local ws = { id = 1 }
    local lone = window("lone", "app", ws)
    local paired_a = window("paired-a", "app", ws)
    local paired_b = window("paired-b", "app", ws)
    group(lone)
    group(paired_a, paired_b)

    local candidates = group_actions.lone_group_windows({
        lone,
        paired_a,
        paired_b,
        window("plain", "app", ws),
    })
    equal("group cleanup selects only one-member groups", #candidates, 1)
    equal("group cleanup returns the lone grouped window", candidates[1], lone)

    local hl, control = fake_runtime({
        active = paired_a,
        windows = { lone, paired_a, paired_b },
        workspace = ws,
    })
    local actions = group_actions.new(hl)

    control.emit("window.close")
    control.emit("window.active")
    check("group cleanup events coalesce into one timer", control.run_timer(60))
    equal("deferred group cleanup dissolves the lone group",
        control.dispatches[1].args.window, lone)
    check("coalesced cleanup leaves no second timer",
        not control.run_timer(60))

    local before = #control.dispatches
    check("untab succeeds for a multi-member group", actions.untab("right"))
    equal("untab gives nary the requested side",
        control.dispatches[before + 1].args, "untab r")
    equal("untab asks Hyprland to leave the group",
        control.dispatches[before + 2].args.out_of_group, "right")
    check("invalid untab directions are rejected", not actions.untab("diagonal"))

    check("ungroup dissolves the active group", actions.ungroup())
    equal("ungroup dispatches the native group toggle",
        control.dispatches[#control.dispatches].kind, "group_toggle")
end

do
    -- A tabbed window sent to another workspace must travel on its own: the
    -- native dispatcher would drag every sibling tab along with it.
    local ws = { id = 1 }
    local tabbed_a = window("tabbed-a", "app", ws)
    local tabbed_b = window("tabbed-b", "app", ws)
    group(tabbed_a, tabbed_b)

    local hl, control = fake_runtime({
        active = tabbed_a,
        windows = { tabbed_a, tabbed_b },
        workspace = ws,
    })
    local actions = group_actions.new(hl)

    check("moving a tabbed window reports that it left its group",
        actions.move_to_workspace(3))
    equal("a tabbed window leaves its group before travelling",
        control.dispatches[1].args.out_of_group, true)
    equal("only the focused tab is sent to the target workspace",
        control.dispatches[2].args.workspace, 3)
    equal("the departing tab is not carried along by its siblings",
        control.dispatches[2].args.window, nil)
end

do
    local ws = { id = 1 }
    local solo = window("solo", "app", ws)
    local hl, control = fake_runtime({ active = solo, windows = { solo }, workspace = ws })
    local actions = group_actions.new(hl)

    check("moving an ungrouped window reports no group departure",
        not actions.move_to_workspace(2))
    equal("an ungrouped window is moved with a single dispatch", #control.dispatches, 1)
    equal("an ungrouped window is never asked to leave a group",
        control.dispatches[1].args.workspace, 2)
end

do
    -- A group whittled down to one member is a tab strip with a single tab, so
    -- the last window out has to leave the group intact rather than escape it.
    local ws = { id = 1 }
    local last = window("last", "app", ws)
    group(last)

    local hl, control = fake_runtime({ active = last, windows = { last }, workspace = ws })
    local actions = group_actions.new(hl)

    check("the sole member of a group needs no detaching",
        not actions.move_to_workspace(4))
    equal("a lone group member moves with a single dispatch", #control.dispatches, 1)
    equal("a lone group member still reaches the target workspace",
        control.dispatches[1].args.workspace, 4)
end

do
    local hl, control = fake_runtime({ active = nil, windows = {} })
    local actions = group_actions.new(hl)

    check("an empty workspace reports no group departure",
        not actions.move_to_workspace(2))
    equal("moving with no focused window dispatches only the move",
        #control.dispatches, 1)
end

--------------------------------------------------------------------------------
-- Window navigation
--------------------------------------------------------------------------------

do
    local ws1, ws2, ws3 = { id = 1 }, { id = 2 }, { id = 3 }
    local centre = {
        id = 1, x = 0, y = 1000, width = 2000, height = 1000, scale = 1,
        active_workspace = ws1,
    }
    local right = {
        id = 2, x = 2000, y = 1000, width = 2000, height = 1000, scale = 1,
        active_workspace = ws2,
    }
    local above = {
        id = 3, x = 500, y = 0, width = 2000, height = 1000, scale = 1,
        active_workspace = ws3,
    }
    equal("monitor navigation selects the monitor along the requested axis",
        window_navigation.monitor_in({ centre, above, right }, centre, "right"),
        right)
    equal("monitor navigation uses the nearest directional candidate",
        window_navigation.monitor_in({ centre, above }, centre, "right"), above)

    local active = window("active", "app", ws1)
    local hl, control = fake_runtime({
        active = active,
        active_monitor = centre,
        monitors = { centre, above, right },
        windows = { active },
        workspace = ws1,
    })
    local nary_fake = {
        space = function(id) return "space:" .. id end,
        shape = function() return "unchanged" end,
    }
    local navigation = window_navigation.new(hl, nary_fake, {
        untab = function() return false end,
    })

    navigation.step_or_cross("right")
    equal("tile movement first steps within the current layout",
        control.dispatches[1].args, "move r")
    equal("unchanged edge movement enters the adjacent workspace",
        control.dispatches[2].args, "enter r space:2")
    equal("edge movement transfers the window to that workspace",
        control.dispatches[3].args.workspace, "2")

    local blocked = window_navigation.new(hl, nary_fake, {
        untab = function() return true end,
    })
    local dispatch_count = #control.dispatches
    blocked.untab_or_step("left")()
    equal("successful untab suppresses tile movement",
        #control.dispatches, dispatch_count)
end

do
    local ws = { id = 1 }
    local a = window("a", "app", ws)
    local b = window("b", "app", ws)
    group(b, a)
    equal("tile identity is independent of member order",
        window_navigation.tile_id(a), "a,b")
    equal("ungrouped windows have an empty tile identity",
        window_navigation.tile_id(window("plain", "app", ws)), "")
end

--------------------------------------------------------------------------------
-- Window resizing
--------------------------------------------------------------------------------

do
    local ws = { id = 1 }
    local tiled = window("tiled", "app", ws)
    tiled.floating = false
    local hl, control = fake_runtime({ active = tiled, windows = { tiled } })
    local actions = window_resize.new(hl)

    actions.resize_tile(50, -50)()
    equal("tiled resize goes through the layout",
        control.dispatches[1].args, "resize 50 -50")

    tiled.floating = true
    actions.resize_tile(30, 20)()
    equal("floating resize goes through the window dispatcher",
        control.dispatches[2].kind, "resize")
    check("floating resize is relative",
        control.dispatches[2].args.relative)

    local grow = actions.accelerated(1)
    grow()
    grow()
    equal("held resize begins at the base step",
        control.dispatches[3].args, "resize 40 40")
    equal("held resize accelerates subsequent steps",
        control.dispatches[4].args, "resize 70 70")
    control.run_timer(400)
    control.run_timer(400)
    grow()
    equal("held resize resets after the idle interval",
        control.dispatches[5].args, "resize 40 40")
end

--------------------------------------------------------------------------------
-- Exposé group state machine
--------------------------------------------------------------------------------

equal("wide four-tab tiles use two expose columns",
    exposes.grid_columns(1700, 1440, 4), 2)
equal("narrow four-tab tiles use one expose column",
    exposes.grid_columns(700, 1440, 4), 1)
equal("ultrawide four-tab tiles use four expose columns",
    exposes.grid_columns(3440, 1440, 4), 4)
equal("malformed expose geometry falls back to one column",
    exposes.grid_columns(nil, 0, 10000), 1)

do
    local ws = { id = 1 }
    local chrome = window("chrome", "google-chrome", ws, 0)
    local obsidian = window("obsidian", "obsidian", ws, 1)
    chrome.size = { x = 1700, y = 1440 }
    obsidian.size = chrome.size
    group(chrome, obsidian)
    local dissolved = 0
    local hl, control = fake_runtime({
        active = chrome,
        windows = { obsidian, chrome },
        workspace = ws,
    })
    local expose = exposes.new(hl, {
        dissolve_lone_groups = function() dissolved = dissolved + 1 end,
    })

    check("expose unfolds a tabbed group", expose.toggle())
    check("expose reports active while unfolded", expose.is_active())
    equal("expose asks the layout for the planned grid",
        control.dispatches[1].args, "explode chrome 2")
    equal("expose dissolves the group after planning",
        control.dispatches[2].kind, "group_toggle")
    check("expose captures plain left-click while unfolded",
        control.binding("mouse:272") ~= nil)

    check("expose accepts an explicit selected target",
        expose.select_target(obsidian))
    equal("expose restores the selected grouped tab", control.active(), obsidian)
    equal("expose raises the selected tab index",
        control.dispatches[#control.dispatches - 1].args.index, 2)
    equal("expose focuses the selected tab last",
        control.dispatches[#control.dispatches].kind, "focus")
    equal("expose sweeps one-member groups after folding", dissolved, 1)
    check("expose releases its click binding after folding",
        control.binding("mouse:272") == nil)
    check("expose reports inactive after folding", not expose.is_active())
end

--------------------------------------------------------------------------------
-- Application switching
--------------------------------------------------------------------------------

do
    local ws1, ws2 = { id = 1 }, { id = 2 }
    local chrome = window("chrome", "google-chrome", ws1, 2)
    local obsidian = window("obsidian", "obsidian", ws1, 1)
    group(chrome, obsidian)
    local other_chrome = window("other", "google-chrome", ws2, 0)
    local hl, control = fake_runtime({
        active = chrome,
        windows = { other_chrome, obsidian, chrome },
        workspace = ws1,
    })
    local actions = window_actions.new(hl)
    local switcher = app_switcher.new(hl, actions)
    local toggle = switcher.toggle({
        name = "chrome",
        classes = { ["google-chrome"] = true },
        launch = "chrome",
        new_window = "chrome --new-window",
    })

    toggle()
    equal("focused app shortcut goes back within its own group",
        control.active(), obsidian)
    equal("focused app shortcut does not launch", #control.executions, 0)

    control.set_active(obsidian)
    toggle()
    equal("unfocused app shortcut selects workspace target", control.active(), chrome)

    control.set_active(obsidian)
    chrome.workspace = ws2
    toggle()
    equal("running app elsewhere launches a new window",
        control.executions[1].cmd, "chrome --new-window")
    equal("new app window is assigned to the visible workspace",
        control.executions[1].options.workspace, "1")

    local launched = window("launched", "google-chrome", ws2, 0)
    control.emit("window.open", launched)
    check("managed launch marker is visible to terminal grouping",
        switcher.consume_managed_launch(launched))
    check("malformed launched windows have no managed marker",
        not switcher.consume_managed_launch({}))
    control.run_timer(60)
    equal("launched window is moved to the requested workspace",
        launched.workspace.id, 1)
    equal("launched window receives focus", control.active(), launched)
end

-- The reported sequence: from the terminal, obsidian's key and back, then
-- chrome's key and back. Each "and back" has to land on the terminal.
do
    local ws = { id = 1 }
    local terminal = window("terminal", "org.wezfurlong.wezterm", ws, 0)
    local chrome = window("chrome", "google-chrome", ws, 1)
    local obsidian = window("obsidian", "obsidian", ws, 2)
    local tabs = group(terminal, chrome, obsidian)
    local windows = { terminal, chrome, obsidian }
    local hl, control = fake_runtime({
        active = terminal,
        windows = windows,
        workspace = ws,
    })
    -- The fake runtime tracks which tab is shown, not focus recency, so keep
    -- Hyprland's ordering in step with the focus the switcher asks for.
    local function focus(window)
        control.set_active(window)
        local rank = 1
        for _, candidate in ipairs(windows) do
            if window_model.same(candidate, window) then
                candidate.focus_history_id = 0
            else
                candidate.focus_history_id = rank
                rank = rank + 1
            end
        end
    end

    local switcher = app_switcher.new(hl, window_actions.new(hl))
    local to_obsidian = switcher.toggle({
        name = "obsidian",
        classes = { obsidian = true },
        launch = "obsidian",
    })
    local to_chrome = switcher.toggle({
        name = "chrome",
        classes = { ["google-chrome"] = true },
        launch = "chrome",
    })

    to_obsidian()
    equal("notes key focuses notes", control.active(), obsidian)
    focus(obsidian)

    to_obsidian()
    equal("notes key again returns to the terminal", control.active(), terminal)
    focus(terminal)

    to_chrome()
    equal("browser key focuses the browser", control.active(), chrome)
    focus(chrome)

    to_chrome()
    equal("browser key again returns to the terminal, not the notes tab",
        control.active(), terminal)
    equal("toggling back never launches anything", #control.executions, 0)
    equal("the group's shown tab tracks the toggles", tabs.current, terminal)
end

do
    local target, running = app_switcher.select(nil, { app = true }, 1)
    equal("empty window lists have no app target", target, nil)
    check("empty window lists report the app stopped", not running)

    local unmapped = {
        class = "app",
        mapped = false,
        workspace = { id = 1 },
    }
    target, running = app_switcher.select({ unmapped }, { app = true }, 1)
    equal("unmapped apps are not selectable", target, nil)
    check("unmapped apps do not count as running", not running)
end

do
    local ws = { id = 1 }
    local chrome = window("chrome", "google-chrome", ws, 0)
    local hl, control = fake_runtime({
        active = chrome,
        windows = { chrome },
        workspace = ws,
    })
    local toggle = app_switcher.new(
        hl,
        window_actions.new(hl)
    ).toggle({
        name = "chrome",
        classes = { ["google-chrome"] = true },
        launch = "chrome",
    })

    toggle()
    equal("focused ungrouped apps remain focused", control.active(), chrome)
    equal("focused ungrouped apps do not dispatch", #control.dispatches, 0)
    equal("focused ungrouped apps do not launch", #control.executions, 0)
end

do
    local ws = { id = 1 }
    local chrome = window("chrome", "google-chrome", ws, 0)
    local terminal = window("terminal", "terminal", ws, 1)
    local selected
    local hl, control = fake_runtime({
        active = terminal,
        windows = { chrome, terminal },
        workspace = ws,
    })
    local switcher = app_switcher.new(hl, window_actions.new(hl), {
        select_target = function(target)
            selected = target
            return true
        end,
    })

    switcher.toggle({
        name = "chrome",
        classes = { ["google-chrome"] = true },
        launch = "chrome",
    })()
    equal("expose owns app selection when active", selected, chrome)
    equal("app switcher does not race expose focus", control.active(), terminal)
end

--------------------------------------------------------------------------------
-- Spotlight state machine
--------------------------------------------------------------------------------

do
    local size = spotlights.centred_size({
        width = 3440,
        height = 1440,
        scale = 2,
    })
    equal("spotlight width accounts for monitor scale", size[1], 860)
    equal("spotlight height accounts for monitor scale", size[2], 576)
    equal("spotlight rejects incomplete monitor geometry",
        spotlights.centred_size({ width = 100 }), nil)
end

do
    local ws = { id = 1, name = "1" }
    local terminal = window("terminal", "terminal", ws, 0)
    terminal.floating = false
    local hl, control = fake_runtime({
        active = terminal,
        windows = { terminal },
        workspace = ws,
    })
    local spotlight = spotlights.new(hl, window_actions.new(hl))

    check("spotlight shows the active tiled window", spotlight.toggle())
    check("spotlight records active state", spotlight.is_active())
    equal("spotlight snapshots tiled layout before floating",
        control.dispatches[1].args, "hold")
    check("spotlight floats a tiled window", terminal.floating)
    check("spotlight opens its special workspace", control.special_shown())
    equal("spotlight moves the window to its special workspace",
        terminal.workspace.name, "special:spotlight")

    check("spotlight toggles the held window home", spotlight.toggle())
    check("spotlight clears active state", not spotlight.is_active())
    check("spotlight retiles a window it floated", not terminal.floating)
    equal("spotlight restores the original workspace", terminal.workspace.id, 1)
    equal("spotlight restores focus to the held window", control.active(), terminal)

    local saw_restore = false
    for _, dispatch in ipairs(control.dispatches) do
        if dispatch.kind == "layout" and dispatch.args == "restore" then
            saw_restore = true
        end
    end
    check("spotlight restores the nary layout snapshot", saw_restore)
end

do
    local ws = { id = 1, name = "1" }
    local image = window("image", "imv", ws, 0)
    image.floating = true
    image.at = { x = 20, y = 30 }
    image.size = { x = 640, y = 480 }
    local hl, control = fake_runtime({
        active = image,
        windows = { image },
        workspace = ws,
    })
    local spotlight = spotlights.new(hl, window_actions.new(hl))

    control.emit("window.open", image)
    check("configured image class spotlights on open", spotlight.is_active())
    spotlight.hide()
    check("pre-floated windows remain floating after spotlight", image.floating)

    local restored_size, restored_position
    for _, dispatch in ipairs(control.dispatches) do
        if dispatch.kind == "resize"
            and dispatch.args.x == 640 and dispatch.args.y == 480
        then
            restored_size = true
        elseif dispatch.kind == "move"
            and dispatch.args.x == 20 and dispatch.args.y == 30
        then
            restored_position = true
        end
    end
    check("spotlight restores floating window size", restored_size)
    check("spotlight restores floating window position", restored_position)
end

--------------------------------------------------------------------------------
-- Terminal-launched GUI grouping
--------------------------------------------------------------------------------

do
    local ws = { id = 1 }
    local terminal = window("terminal", "com.mitchellh.ghostty", ws, 0)
    terminal.pid = 10
    local app = window("app", "custom-app", ws, 1)
    app.pid = 30
    local parents = { [30] = 20, [20] = 10, [10] = 1 }
    local hl, control = fake_runtime({
        active = terminal,
        windows = { terminal, app },
        workspace = ws,
    })

    terminal_groups.new(hl, {
        direction_towards = function() return "left" end,
        parent_pid = function(pid) return parents[pid] end,
    })
    control.emit("window.open", app)
    check("terminal child grouping is deferred", control.run_timer(80))
    equal("terminal child moves into its source group",
        control.dispatches[#control.dispatches].args.into_or_create_group,
        "left")
    equal("terminal child grouping targets the opened window",
        control.dispatches[#control.dispatches].args.window, app)
end

do
    local ws = { id = 1 }
    local terminal = window("terminal", "org.wezfurlong.wezterm", ws, 0)
    terminal.pid = 10
    local chrome = window("chrome", "google-chrome", ws, 1)
    chrome.pid = 99
    local managed = true
    local hl, control = fake_runtime({
        active = terminal,
        windows = { terminal, chrome },
        workspace = ws,
    })

    terminal_groups.new(hl, {
        consume_managed_launch = function()
            local value = managed
            managed = false
            return value
        end,
        direction_towards = function() return "right" end,
        parent_pid = function() return nil end,
    })
    control.emit("window.open", chrome)
    check("known single-instance apps use recent-terminal fallback",
        control.run_timer(80))
    equal("managed app launches are not grouped with terminals",
        #control.dispatches, 0)
end

do
    local ws = { id = 1 }
    local terminal = window("terminal", "org.wezfurlong.wezterm", ws, 0)
    local unrelated = window("unrelated", "unrelated-app", ws, 1)
    local hl, control = fake_runtime({
        active = terminal,
        windows = { terminal, unrelated },
        workspace = ws,
    })

    terminal_groups.new(hl, {
        direction_towards = function() return "right" end,
        parent_pid = function() return nil end,
    })
    control.emit("window.open", unrelated)
    check("unrelated windows do not use terminal focus fallback",
        not control.run_timer(80))
    equal("unrelated windows are never grouped", #control.dispatches, 0)
end

do
    local ws = { id = 1 }
    local terminal = window("dropdown", "com.mitchellh.ghostty", ws, 0)
    terminal.pid = 10
    local app = window("app", "custom-app", ws, 1)
    app.pid = 30
    local parents = { [30] = 10, [10] = 1 }
    local hl, control = fake_runtime({
        active = terminal,
        windows = { terminal, app },
        workspace = ws,
    })

    terminal_groups.new(hl, {
        exclude_source = function(source) return source == terminal end,
        direction_towards = function() return "left" end,
        parent_pid = function(pid) return parents[pid] end,
    })
    control.emit("window.open", app)
    check("excluded terminal sources do not schedule grouping",
        not control.run_timer(80))
    equal("excluded terminal sources never group their child",
        #control.dispatches, 0)
end

do
    local ws = { id = 1 }
    local terminal = window("terminal", "org.wezfurlong.wezterm", ws, 0)
    terminal.pid = 10
    local chrome = window("chrome", "google-chrome", ws, 1)
    chrome.pid = 99
    local hl, control = fake_runtime({
        active = terminal,
        windows = { terminal, chrome },
        workspace = ws,
    })

    terminal_groups.new(hl, {
        suppress = function() return true end,
        direction_towards = function() return "right" end,
        parent_pid = function() return nil end,
    })
    control.emit("window.open", chrome)
    check("suppressed windows do not schedule grouping",
        not control.run_timer(80))
    equal("suppressed windows are never grouped", #control.dispatches, 0)
end

--------------------------------------------------------------------------------
-- Scratchpad/group interaction
--------------------------------------------------------------------------------

do
    local ws = { id = 1, name = "1" }
    local special = { id = -94, name = "special:ghostty-drop" }
    local chrome = window("chrome", "google-chrome", ws)
    local obsidian = window("obsidian", "obsidian", ws)
    local tabs = group(chrome, obsidian)
    local pad = window("pad", "com.mitchellh.ghostty", special)

    local hl, control = fake_runtime({
        active = chrome,
        fallback_on_hide = obsidian,
        special_workspace = special,
        windows = { obsidian, chrome, pad },
        workspace = ws,
    })
    local scratchpad = scratchpads.new(hl, window_actions.new(hl))
    scratchpad.define("ghostty-drop", {
        class = "com.mitchellh.ghostty",
        cmd = "ghostty",
        w = 1600,
        h = 1000,
        isolate = true,
    })

    check("declared special-workspace windows are scratchpads",
        scratchpad.is_scratchpad(pad))
    check("ordinary windows are not scratchpads",
        not scratchpad.is_scratchpad(chrome))

    scratchpad.toggle("ghostty-drop")
    equal("showing a scratchpad focuses it", control.active(), pad)
    check("showing a scratchpad opens its special workspace",
        control.special_shown())

    local child = window("pad-child", "custom-app", special)
    control.emit("window.open", child)
    equal("isolated scratchpads redirect foreign windows to their host",
        child.workspace.id, ws.id)
    check("redirected scratchpad children follow onto the host workspace",
        control.active() == child)
    equal("redirected scratchpad children are not grouped",
        control.dispatches[#control.dispatches].args.into_or_create_group, nil)

    scratchpad.toggle("ghostty-drop")
    equal("dismissal restores the exact prior window", control.active(), chrome)
    equal("dismissal restores the exact prior group tab", tabs.current, chrome)
    check("dismissal closes the special workspace",
        not control.special_shown())

    scratchpad.toggle("ghostty-drop")
    control.emit("window.active")
    control.set_active(obsidian)
    control.emit("window.active")
    equal("clicking another tab while open preserves that selection",
        control.active(), obsidian)
    equal("autohide keeps the user-selected group tab", tabs.current, obsidian)
end

do
    local ws = { id = 1, name = "1" }
    local special = { id = -94, name = "special:ghostty-drop" }
    local chrome = window("chrome", "google-chrome", ws)
    local obsidian = window("obsidian", "obsidian", ws)
    local tabs = group(chrome, obsidian)
    local pad = window("pad", "com.mitchellh.ghostty", special)
    local hl, control = fake_runtime({
        active = chrome,
        fallback_on_hide = obsidian,
        special_workspace = special,
        windows = { obsidian, chrome, pad },
        workspace = ws,
    })
    local scratchpad = scratchpads.new(hl, window_actions.new(hl))
    scratchpad.define("ghostty-drop", {
        class = "com.mitchellh.ghostty",
        cmd = "ghostty",
        w = 1600,
        h = 1000,
    })

    scratchpad.toggle("ghostty-drop")
    control.remove_window(chrome)
    tabs.current, tabs.current_index = obsidian, 1
    scratchpad.toggle("ghostty-drop")
    equal("closed scratchpad return targets use a visible fallback",
        control.active(), obsidian)
end

-- Scratchpad geometry. The sizes below are shares of a monitor rather than pixel
-- counts, so the same declaration has to land on screens of different sizes — the
-- failure these replaced was a pad positioned entirely off a smaller display.
local function last_dispatch(control, kind)
    for index = #control.dispatches, 1, -1 do
        if control.dispatches[index].kind == kind then
            return control.dispatches[index].args
        end
    end
end

local function monitor(spec)
    return {
        id = spec.id,
        name = spec.name,
        x = spec.x or 0,
        y = spec.y or 0,
        width = spec.width,
        height = spec.height,
        scale = spec.scale or 1,
        focused = spec.focused,
        active_workspace = spec.workspace,
    }
end

do
    local ws = { id = 1, name = "1" }
    local special = { id = -94, name = "special:ghostty-drop" }
    local chrome = window("chrome", "google-chrome", ws)
    local pad = window("pad", "com.mitchellh.ghostty", special)

    local ultrawide = monitor({
        id = 0, name = "DP-1", width = 3440, height = 1440,
        focused = true, workspace = ws,
    })
    local panel = monitor({
        id = 1, name = "eDP-1", y = 1440, width = 1920, height = 1200,
        workspace = ws,
    })

    local hl, control = fake_runtime({
        active = chrome,
        active_monitor = ultrawide,
        monitors = { ultrawide, panel },
        windows = { chrome, pad },
        workspace = ws,
    })
    local scratchpad = scratchpads.new(hl, window_actions.new(hl))
    scratchpad.define("ghostty-drop", {
        class = "com.mitchellh.ghostty",
        cmd = "ghostty",
        w = 0.8, h = 0.7,
        anchor = "top", gap = 12,
        monitor = "builtin",
    })

    scratchpad.toggle("ghostty-drop")
    local size = last_dispatch(control, "resize")
    local at = last_dispatch(control, "move")

    equal("fractional width resolves against the built-in panel", size.x, 1536)
    equal("fractional height resolves against the built-in panel", size.y, 840)
    equal("a top-anchored pad is centred horizontally", at.x, 192)
    equal("a top-anchored pad hangs from the top edge by its gap", at.y, 1452)
    check("a pinned pad is placed on the panel, not the focused monitor",
        at.y >= panel.y and at.y + size.y <= panel.y + panel.height)
end

do
    -- Scaling: Hyprland reports monitors in physical pixels but places windows in
    -- logical ones, so a HiDPI panel must not halve the share the pad occupies.
    local ws = { id = 1, name = "1" }
    local special = { id = -94, name = "special:ghostty-drop" }
    local pad = window("pad", "com.mitchellh.ghostty", special)
    local hidpi = monitor({
        id = 0, name = "eDP-1", width = 3840, height = 2400, scale = 2,
        focused = true, workspace = ws,
    })

    local hl, control = fake_runtime({
        active_monitor = hidpi,
        monitors = { hidpi },
        windows = { pad },
        workspace = ws,
    })
    local scratchpad = scratchpads.new(hl, window_actions.new(hl))
    scratchpad.define("ghostty-drop", {
        class = "com.mitchellh.ghostty",
        cmd = "ghostty",
        w = 0.8, h = 0.7,
        anchor = "top",
        monitor = "builtin",
    })

    scratchpad.toggle("ghostty-drop")
    local size = last_dispatch(control, "resize")
    equal("fractional sizes are logical, not physical, pixels", size.x, 1536)
    equal("a pad with no gap sits flush against the top edge",
        last_dispatch(control, "move").y, 0)
end

do
    -- Fluid sizing should stop growing once a terminal reaches a readable width.
    -- On a desktop with no built-in panel the first output is the target monitor.
    local ws = { id = 1, name = "1" }
    local special = { id = -94, name = "special:ghostty-drop" }
    local pad = window("pad", "com.mitchellh.ghostty", special)
    local ultrawide = monitor({
        id = 0, name = "DP-1", width = 3440, height = 1440,
        focused = true, workspace = ws,
    })

    local hl, control = fake_runtime({
        active_monitor = ultrawide,
        monitors = { ultrawide },
        windows = { pad },
        workspace = ws,
    })
    local scratchpad = scratchpads.new(hl, window_actions.new(hl))
    scratchpad.define("ghostty-drop", {
        class = "com.mitchellh.ghostty",
        cmd = "ghostty",
        w = 0.8, h = 0.7, max_w = 1600,
        anchor = "top", gap = 12,
        monitor = "builtin",
    })

    scratchpad.toggle("ghostty-drop")
    local size = last_dispatch(control, "resize")
    local at = last_dispatch(control, "move")
    equal("fractional widths are capped on an ultrawide", size.x, 1600)
    equal("a capped scratchpad remains horizontally centred", at.x, 920)
    equal("the width cap does not alter fractional height", size.y, 1008)
end

do
    -- Absolute sizes and the default anchor still behave as they always did.
    local ws = { id = 1, name = "1" }
    local special = { id = -94, name = "special:chrome-drop" }
    local pad = window("pad", "google-chrome", special)
    local screen = monitor({
        id = 0, name = "DP-1", width = 3440, height = 1440,
        focused = true, workspace = ws,
    })

    local hl, control = fake_runtime({
        active_monitor = screen,
        monitors = { screen },
        windows = { pad },
        workspace = ws,
    })
    local scratchpad = scratchpads.new(hl, window_actions.new(hl))
    scratchpad.define("chrome-drop", {
        class = "google-chrome",
        cmd = "google-chrome-stable",
        w = 1800, h = 1100,
    })

    scratchpad.toggle("chrome-drop")
    local size = last_dispatch(control, "resize")
    local at = last_dispatch(control, "move")
    equal("sizes above one are taken as pixels", size.x, 1800)
    equal("an unanchored pad is centred horizontally", at.x, 820)
    equal("an unanchored pad is centred vertically", at.y, 170)
end

do
    -- The first press launches the app, and an exec rule cannot express a share of
    -- a monitor, so the fraction has to be resolved before the window exists.
    local ws = { id = 1, name = "1" }
    local panel = monitor({
        id = 0, name = "eDP-1", width = 1920, height = 1200,
        focused = true, workspace = ws,
    })

    local hl, control = fake_runtime({
        active_monitor = panel,
        monitors = { panel },
        windows = {},
        workspace = ws,
    })
    local scratchpad = scratchpads.new(hl, window_actions.new(hl))
    scratchpad.define("ghostty-drop", {
        class = "com.mitchellh.ghostty",
        cmd = "ghostty",
        w = 0.8, h = 0.7,
        anchor = "top",
        monitor = "builtin",
    })

    scratchpad.toggle("ghostty-drop")
    local launch = control.dispatches[#control.dispatches]
    equal("the first press launches the app", launch.args, "ghostty")
    equal("the launch rule sizes in resolved pixels", launch.rules.size[1], 1536)
    equal("the launch rule height is resolved too", launch.rules.size[2], 840)
end

io.write(("%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
