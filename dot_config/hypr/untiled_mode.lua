-- untiled_mode.lua — workspace-scoped opt-out from automatic tiling.
--
-- Hyprland has per-workspace layout selection, but no "floating layout". This
-- controller therefore owns the distinction that matters: windows it floated
-- for an untiled workspace versus windows that were already floating because
-- they are dialogs, scratchpads, or explicitly configured that way.

local window_model = require("window_model")

local M = {}

local function workspace_id(workspace)
    local id = workspace and workspace.id
    if type(id) == "number" and id > 0 then return id end
end

local function window_id(window)
    local id = window_model.id(window)
    if id ~= nil then return tostring(id) end
end

local function on_workspace(window, id)
    return window and window.workspace and window.workspace.id == id
end

function M.new(hl, options)
    options = options or {}
    -- modes[id].owned contains only windows changed from tiled to floating by
    -- this mode. pending_tile covers one of those windows temporarily parked
    -- on a special workspace when its home mode is switched off.
    local modes = {}
    local pending_tile = {}
    -- Floating geometry survives ordinary tile/untile cycles for each live
    -- window on each workspace. Tables are copied because Hyprland's window
    -- handles expose live vector objects which change as soon as tiling runs.
    local geometries = {}

    local function copy_geometry(window)
        local at, size = window and window.at, window and window.size
        if not (at and size and type(at.x) == "number" and type(at.y) == "number"
            and type(size.x) == "number" and type(size.y) == "number")
        then
            return nil
        end
        return { x = at.x, y = at.y, w = size.x, h = size.y }
    end

    local function remember(workspace, identity, window)
        local geometry = copy_geometry(window)
        if not (workspace and identity and geometry) then return end
        geometries[workspace] = geometries[workspace] or {}
        geometries[workspace][identity] = geometry
    end

    local function forget(identity)
        for _, workspace_geometries in pairs(geometries) do
            workspace_geometries[identity] = nil
        end
    end

    local function visible_workspace()
        local monitor = hl.get_active_monitor()
        local workspace = monitor and monitor.active_workspace
        if workspace_id(workspace) then return workspace end
        return hl.get_active_workspace()
    end

    local function float_for(mode, window)
        local id = window_id(window)
        if mode.suspended or not (id and window and window.mapped and not window.floating) then
            return false
        end

        mode.owned[id] = true
        pending_tile[id] = nil
        hl.dispatch(hl.dsp.window.float({ action = "on", window = window }))
        return true
    end

    local function owner_of(id)
        for workspace, mode in pairs(modes) do
            if mode.owned[id] then return workspace, mode end
        end
    end

    local function tile(window)
        if window and window.mapped and window.floating then
            hl.dispatch(hl.dsp.window.float({ action = "off", window = window }))
            return true
        end
        return false
    end

    local function disable(id, restore_layout)
        local mode = modes[id]
        if not mode then return false end
        modes[id] = nil

        local owned = {}
        for _, window in ipairs(hl.get_windows() or {}) do
            local identity = window_id(window)
            if identity and mode.owned[identity] then
                if workspace_id(window.workspace) then
                    if not mode.suspended then remember(id, identity, window) end
                    owned[#owned + 1] = window
                else
                    -- Tiling a window on a special workspace can pull it back
                    -- into the ordinary workspace. Defer until it returns.
                    pending_tile[identity] = true
                end
            end
        end
        -- Capture every box before tiling a grouped member updates its peers.
        for _, window in ipairs(owned) do tile(window) end

        if restore_layout then hl.dispatch(hl.dsp.layout("restore")) end
        return true
    end

    local function enable(id, mode)
        mode = mode or { owned = {} }
        mode.suspended = false
        modes[id] = mode

        -- nary restores this photograph only when the set of windows is still
        -- identical. If one opens or closes while untiled, its normal arrival
        -- layout is retained instead of resurrecting stale structure.
        local to_float = {}
        for _, window in ipairs(hl.get_windows() or {}) do
            local identity = window_id(window)
            if on_workspace(window, id) and identity and window.mapped
                and not window.floating
            then
                -- Build the complete ownership plan before dispatching. One
                -- float can update every member of a tab group immediately;
                -- observing between dispatches would otherwise own only its
                -- visible member and strand the others after F1 unfolds it.
                mode.owned[identity] = true
                pending_tile[identity] = nil
                to_float[#to_float + 1] = window
            end
        end

        -- Selection may finish after focus crossed to another workspace.
        -- Photograph the source directly when the layout adapter supports it.
        if options.hold_layout then
            options.hold_layout(id)
        elseif workspace_id(visible_workspace()) == id then
            hl.dispatch(hl.dsp.layout("hold"))
        end
        for _, window in ipairs(to_float) do
            hl.dispatch(hl.dsp.window.float({ action = "on", window = window }))
        end
        local saved = geometries[id] or {}
        for _, window in ipairs(to_float) do
            local geometry = saved[window_id(window)]
            if geometry then
                hl.dispatch(hl.dsp.window.resize({
                    x = geometry.w, y = geometry.h, window = window,
                }))
                hl.dispatch(hl.dsp.window.move({
                    x = geometry.x, y = geometry.y, window = window,
                }))
            end
        end
        return true
    end

    local function toggle()
        local id = workspace_id(visible_workspace())
        if not id then return false end
        if modes[id] then return disable(id, true) end
        return enable(id)
    end

    -- Suspend the opt-out while exposé lays out selectable panes. Ownership
    -- stays attached to this mode, and the returned continuation can resume
    -- only that exact workspace/mode, even if focus changes or it is removed.
    local function begin_selection()
        local id = workspace_id(visible_workspace())
        local mode = id and modes[id]
        if not mode or mode.suspended then return nil end
        local owned = {}
        for _, window in ipairs(hl.get_windows() or {}) do
            local identity = window_id(window)
            if identity and on_workspace(window, id) and window.mapped and mode.owned[identity] then
                remember(id, identity, window)
                owned[#owned + 1] = window
            end
        end
        mode.suspended = true
        for _, window in ipairs(owned) do tile(window) end
        hl.dispatch(hl.dsp.layout("restore"))
        return function()
            if modes[id] ~= mode or not mode.suspended then return false end
            return enable(id, mode)
        end
    end

    hl.on("window.open", function(window)
        local id = workspace_id(window and window.workspace)
        local mode = id and modes[id]
        if mode then float_for(mode, window) end
    end)

    hl.on("window.move_to_workspace", function(window, destination)
        local identity = window_id(window)
        if not identity then return end

        local old_id, old_mode = owner_of(identity)
        if old_mode and not old_mode.suspended then remember(old_id, identity, window) end
        local destination_id = workspace_id(destination or (window and window.workspace))
        if not destination_id then
            -- Special workspaces are overlays, not a change in ownership.
            return
        end

        local destination_mode = modes[destination_id]

        if destination_mode then
            if old_mode and old_id ~= destination_id then
                old_mode.owned[identity] = nil
                destination_mode.owned[identity] = true
                pending_tile[identity] = nil
            elseif not old_mode then
                float_for(destination_mode, window)
            end
            if destination_mode.suspended and destination_mode.owned[identity] then tile(window) end
            return
        end

        if old_mode then old_mode.owned[identity] = nil end
        if old_mode or pending_tile[identity] then
            pending_tile[identity] = nil
            tile(window)
        end
    end)

    hl.on("window.close", function(window)
        local identity = window_id(window)
        if not identity then return end
        pending_tile[identity] = nil
        forget(identity)
        for _, mode in pairs(modes) do mode.owned[identity] = nil end
    end)

    hl.on("workspace.removed", function(workspace)
        local id = workspace_id(workspace)
        if id then
            disable(id, false)
            geometries[id] = nil
        end
    end)

    return {
        toggle = toggle,
        begin_selection = begin_selection,
        is_active = function(workspace)
            local id = type(workspace) == "number" and workspace
                or workspace_id(workspace or visible_workspace())
            return id ~= nil and modes[id] ~= nil
        end,
    }
end

return M
