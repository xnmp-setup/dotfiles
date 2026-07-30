-- Offline behavior tests for focus-sensitive desktop features.
-- Run: lua desktop_test.lua

package.path = (arg[0]:match("^(.*)/") or ".") .. "/?.lua;" .. package.path

local app_switcher   = require("app_switcher")
local exposes        = require("expose")
local scratchpads    = require("scratchpad")
local spotlights     = require("spotlight")
local terminal_groups = require("terminal_grouping")
local window_actions = require("window_actions")
local window_model   = require("window_model")

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
            return {
                active_workspace = normal_workspace,
                active_special_workspace = special_workspace,
                width = spec.monitor_width or 3440,
                height = spec.monitor_height or 1440,
                scale = spec.monitor_scale or 1,
            }
        end,
        get_active_window = function() return active end,
        get_active_workspace = function() return normal_workspace end,
        get_cursor_pos = function() return spec.cursor end,
        get_monitors = function()
            return {{
                active_workspace = normal_workspace,
                active_special_workspace = special_workspace,
            }}
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
