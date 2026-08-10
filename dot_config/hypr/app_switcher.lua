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
        return function()
            local workspace = current_workspace()
            if not (workspace and workspace.id) then return end

            local active = hl.get_active_window()
            if active and M.matches(app.classes, active.class) then
                -- Pressing an app's key while it already has focus puts its
                -- group back to whatever tab it was showing before, so the key
                -- reads as a toggle. Cycling to the next tab is the fallback
                -- for a group nobody has focused elsewhere yet.
                if not window_actions.previous_group(active, hl.get_windows()) then
                    window_actions.next_group(active)
                end
                return
            end

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
