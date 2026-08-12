-- app_switcher.lua — per-workspace application toggles.
--
-- Selection is pure; launching, delayed window adoption, and focus dispatching
-- stay in the runtime shell created by `new`.

local window_model = require("window_model")

local M = {}

-- Wayland app IDs and X11 WM_CLASS values for the same application can differ
-- only in case (Chrome is `google-chrome` natively and `Google-chrome` through
-- XWayland). Treat application identities case-insensitively so switching does
-- not depend on which backend an application used for a particular launch.
function M.matches(classes, class)
    if type(class) ~= "string" then return false end
    if classes and classes[class] then return true end

    local folded = class:lower()
    for candidate, enabled in pairs(classes or {}) do
        if enabled and type(candidate) == "string" and candidate:lower() == folded then
            return true
        end
    end
    return false
end

function M.select(windows, classes, workspace_id)
    local target
    local running = false

    for _, window in ipairs(windows or {}) do
        if window.mapped and M.matches(classes, window.class) then
            running = true
            if window.workspace and window.workspace.id == workspace_id
                and (not target
                    or (window.focus_history_id or math.huge)
                        < (target.focus_history_id or math.huge))
            then
                target = window
            end
        end
    end

    return target, running
end

local function app_windows(windows, classes, workspace_id)
    local result = {}
    for _, window in ipairs(windows or {}) do
        if window.mapped
            and M.matches(classes, window.class)
            and window.workspace and window.workspace.id == workspace_id
        then
            result[#result + 1] = window
        end
    end
    return result
end

local function ids_of(windows)
    local ids = {}
    for _, window in ipairs(windows) do
        local id = window_model.id(window)
        if id then ids[#ids + 1] = tostring(id) end
    end
    table.sort(ids)
    return ids
end

local function same_ids(left, right)
    if #left ~= #right then return false end
    for index, id in ipairs(left) do
        if right[index] ~= id then return false end
    end
    return true
end

local function windows_by_id(windows)
    local result = {}
    for _, window in ipairs(windows or {}) do
        local id = window_model.id(window)
        if id then result[tostring(id)] = window end
    end
    return result
end

-- Snapshot focus history once per cycle. Focus changes mutate Hyprland's
-- history, so sorting again on every keypress would bounce between the two
-- most recently focused app windows instead of visiting the full set.
local function cycle_targets(windows, active, return_target)
    local active_id = tostring(window_model.id(active))
    local return_id = return_target and tostring(window_model.id(return_target))
    local targets = {}

    for _, window in ipairs(windows) do
        local id = tostring(window_model.id(window))
        if id ~= active_id and id ~= return_id then targets[#targets + 1] = window end
    end
    table.sort(targets, function(left, right)
        local left_rank = left.focus_history_id or math.huge
        local right_rank = right.focus_history_id or math.huge
        if left_rank ~= right_rank then return left_rank < right_rank end
        return tostring(window_model.id(left)) < tostring(window_model.id(right))
    end)

    -- Preserve the old toggle-back destination as the final step. An app that
    -- is not grouped has no such destination, so close the cycle at its anchor.
    targets[#targets + 1] = return_target or active
    return targets
end

function M.new(hl, window_actions, options)
    options = options or {}

    local pending = {}
    local managed_launches = {}

    local function current_workspace()
        local monitor = hl.get_active_monitor()
        local workspace = monitor and monitor.active_workspace
        if workspace and workspace.id then return workspace end
        return hl.get_active_workspace()
    end

    hl.on("window.open", function(window)
        if not window then return end

        for name, launch in pairs(pending) do
            if M.matches(launch.classes, window.class) then
                pending[name] = nil
                local id = window_model.id(window)
                if id then
                    local launch_id = tostring(id)
                    managed_launches[launch_id] = true
                    hl.timer(function()
                        managed_launches[launch_id] = nil
                    end, { timeout = 500, type = "oneshot" })
                end
                hl.timer(function()
                    if not window.mapped then return end
                    if not (window.workspace and window.workspace.id == launch.workspace_id) then
                        hl.dispatch(hl.dsp.window.move({
                            workspace = tostring(launch.workspace_id),
                            window = window,
                        }))
                    end
                    window_actions.focus_exact(window)
                end, { timeout = 60, type = "oneshot" })
                return
            end
        end
    end)

    local function toggle(app)
        local cycle

        return function()
            local workspace = current_workspace()
            if not (workspace and workspace.id) then return end

            local active = hl.get_active_window()
            if active and M.matches(app.classes, active.class) then
                local windows = hl.get_windows() or {}
                local local_windows = app_windows(windows, app.classes, workspace.id)

                if app.cycle_windows and #local_windows > 1 then
                    local active_id = tostring(window_model.id(active))
                    local current_ids = ids_of(local_windows)
                    local by_id = windows_by_id(windows)
                    local valid = cycle
                        and cycle.workspace_id == workspace.id
                        and cycle.expected_id == active_id
                        and same_ids(cycle.app_ids, current_ids)
                        and cycle.index < #cycle.target_ids

                    if not valid then
                        local return_plan = window_model.previous_group_plan(active, windows)
                            or window_model.next_group_plan(active)
                        local targets = cycle_targets(
                            local_windows,
                            active,
                            return_plan and return_plan.target
                        )
                        local target_ids = {}
                        for _, target in ipairs(targets) do
                            target_ids[#target_ids + 1] = tostring(window_model.id(target))
                        end
                        cycle = {
                            app_ids = current_ids,
                            expected_id = active_id,
                            index = 0,
                            target_ids = target_ids,
                            workspace_id = workspace.id,
                        }
                    end

                    cycle.index = cycle.index + 1
                    local target = by_id[cycle.target_ids[cycle.index]]
                    if target then
                        cycle.expected_id = tostring(window_model.id(target))
                        window_actions.focus_exact(target)
                        return
                    end
                    cycle = nil
                else
                    cycle = nil
                end

                -- Pressing an app's key while it already has focus puts its
                -- group back to whatever tab it was showing before, so the key
                -- reads as a toggle. Cycling to the next tab is the fallback
                -- for a group nobody has focused elsewhere yet.
                if not window_actions.previous_group(active, hl.get_windows()) then
                    window_actions.next_group(active)
                end
                return
            end

            cycle = nil

            local target, running = M.select(
                hl.get_windows(),
                app.classes,
                workspace.id
            )

            if not target then
                pending[app.name] = {
                    classes = app.classes,
                    workspace_id = workspace.id,
                }
                local command = running and (app.new_window or app.launch) or app.launch
                hl.exec_cmd(command, { workspace = tostring(workspace.id) })
                return
            end

            if options.select_target and options.select_target(target) then return end
            window_actions.focus_exact(target)
        end
    end

    return {
        toggle = toggle,
        consume_managed_launch = function(window)
            local id = window_model.id(window)
            if not id then return false end
            local launch_id = tostring(id)
            if not managed_launches[launch_id] then return false end
            managed_launches[launch_id] = nil
            return true
        end,
    }
end

return M
