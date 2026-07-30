-- Offline behavior tests for focus-sensitive desktop features.
-- Run: lua desktop_test.lua

package.path = (arg[0]:match("^(.*)/") or ".") .. "/?.lua;" .. package.path

local app_switcher   = require("app_switcher")
local exposes        = require("expose")
local group_actions  = require("group_actions")
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

local function group(...)
    local members = { ... }
    local value = {
        current = members[1],
        current_index = 1,
        members = members,
        size = #members,
    }
    for _, member in ipairs(members) do member.group = value end
    return value
end

local function fake_runtime(spec)
    spec = spec or {}
    local active = spec.active
    local windows = spec.windows or {}
    local normal_workspace = spec.workspace or { id = 1, name = "1" }
    local special_workspace
    local callbacks, timers, dispatches, executions, configs = {}, {}, {}, {}, {}
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
            exec_cmd = command("exec"),
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

do
    local ws = { id = 1 }
    local members = {}
    for index = 1, 10000 do
        members[index] = window(tostring(index), "test", ws)
    end
    local tabs = group(table.unpack(members))
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
    equal("focused app shortcut advances within its own group",
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
    })

    scratchpad.toggle("ghostty-drop")
    equal("showing a scratchpad focuses it", control.active(), pad)
    check("showing a scratchpad opens its special workspace",
        control.special_shown())

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

io.write(("%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
