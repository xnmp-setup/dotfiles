-- Directional tile movement, monitor crossing, and neighbour invasion.

local M = {}

local DIR_SHORT = { left = "l", right = "r", up = "u", down = "d" }

local function centre(monitor)
    local scale = monitor.scale or 1
    return (monitor.x or 0) + (monitor.width or 0) / scale / 2,
           (monitor.y or 0) + (monitor.height or 0) / scale / 2
end

function M.monitor_in(monitors, from, direction)
    if not from then return nil end

    local horizontal = direction == "left" or direction == "right"
    local ahead = (direction == "right" or direction == "down") and 1 or -1
    local from_x, from_y = centre(from)
    local best, best_cost

    for _, monitor in ipairs(monitors or {}) do
        if monitor.id ~= from.id then
            local x, y = centre(monitor)
            local along = horizontal and (x - from_x) or (y - from_y)
            local across = horizontal and (y - from_y) or (x - from_x)

            if along * ahead > 0 then
                local cost = math.abs(along) + math.abs(across) * 2
                if not best_cost or cost < best_cost then
                    best, best_cost = monitor, cost
                end
            end
        end
    end
    return best
end

function M.tile_id(window)
    local members = window and window.group and window.group.members
    if not members then return "" end
    if members.stable_id then members = { members } end

    local ids = {}
    for _, member in ipairs(members) do
        ids[#ids + 1] = tostring(member.stable_id)
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

function M.new(hl, nary, group_actions)
    local function layout_shape()
        local workspace = hl.get_active_workspace()
        return workspace and workspace.id
            and nary.shape(nary.space(workspace.id))
            or nil
    end

    local function cross_monitor(direction)
        local monitor = M.monitor_in(
            hl.get_monitors(),
            hl.get_active_monitor(),
            direction
        )
        local workspace = monitor and monitor.active_workspace
        if not (workspace and workspace.id) then return false end

        hl.dispatch(hl.dsp.layout(
            ("enter %s %s"):format(DIR_SHORT[direction], nary.space(workspace.id))
        ))
        hl.dispatch(hl.dsp.window.move({ workspace = tostring(workspace.id) }))
        return true
    end

    local function step_or_cross(direction)
        local before = layout_shape()
        hl.dispatch(hl.dsp.layout("move " .. DIR_SHORT[direction]))
        if before and layout_shape() == before then cross_monitor(direction) end
    end

    local function untab_or_step(direction)
        return function()
            if not group_actions.untab(direction) then step_or_cross(direction) end
        end
    end

    local function invade(direction)
        return function()
            local active = hl.get_active_window()
            if not active then return end

            local before = M.tile_id(active)
            hl.dispatch(hl.dsp.window.move({ into_or_create_group = direction }))
            if M.tile_id(hl.get_active_window()) ~= before then return end

            if cross_monitor(direction) then
                hl.dispatch(hl.dsp.window.move({ into_or_create_group = direction }))
            end
        end
    end

    return {
        cross_monitor = cross_monitor,
        step_or_cross = step_or_cross,
        untab_or_step = untab_or_step,
        invade = invade,
    }
end

return M
