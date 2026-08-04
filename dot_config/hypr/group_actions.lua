-- Native Hyprland group lifecycle and tab-to-pane actions.

local M = {}

local DIR_SHORT = { left = "l", right = "r", up = "u", down = "d" }

function M.lone_group_windows(windows)
    local lone = {}
    for _, candidate in ipairs(windows or {}) do
        local group = candidate.group
        if group and group.size == 1 then lone[#lone + 1] = candidate end
    end
    return lone
end

function M.new(hl)
    local sweeping = false

    local function dissolve_lone_groups()
        for _, candidate in ipairs(M.lone_group_windows(hl.get_windows())) do
            hl.dispatch(hl.dsp.group.toggle({ window = candidate }))
        end
    end

    local function sweep_lone_groups()
        if sweeping then return end
        sweeping = true
        hl.timer(function()
            sweeping = false
            dissolve_lone_groups()
        end, { timeout = 60, type = "oneshot" })
    end

    for _, event in ipairs({
        "window.close",
        "window.destroy",
        "window.active",
        "window.move_to_workspace",
    }) do
        hl.on(event, sweep_lone_groups)
    end

    local function ungroup()
        local active = hl.get_active_window()
        if active and active.group then
            hl.dispatch(hl.dsp.group.toggle())
            return true
        end
        return false
    end

    local function untab(direction)
        local short = DIR_SHORT[direction]
        if not short then return false end

        local active = hl.get_active_window()
        if not (active and active.group and active.group.size > 1) then return false end

        hl.dispatch(hl.dsp.layout("untab " .. short))
        hl.dispatch(hl.dsp.window.move({ out_of_group = direction }))
        dissolve_lone_groups()
        return true
    end

    -- Hyprland's move-to-workspace dispatcher relocates every member of a group,
    -- so a tabbed window has to leave its group before it travels alone.
    local function move_to_workspace(workspace)
        local active = hl.get_active_window()
        local tabbed = active and active.group and active.group.size > 1

        if tabbed then
            hl.dispatch(hl.dsp.window.move({ out_of_group = true }))
        end
        hl.dispatch(hl.dsp.window.move({ workspace = workspace }))
        if tabbed then dissolve_lone_groups() end
        return tabbed or false
    end

    return {
        dissolve_lone_groups = dissolve_lone_groups,
        move_to_workspace = move_to_workspace,
        sweep_lone_groups = sweep_lone_groups,
        ungroup = ungroup,
        untab = untab,
    }
end

return M
