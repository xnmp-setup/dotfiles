-- window_actions.lua — Hyprland adapter for pure window_model plans.

local model = require("window_model")

local M = {}

function M.new(hl)
    local function select_group(group)
        if group then
            hl.dispatch(hl.dsp.group.active({
                index = group.index,
                window = group.window,
            }))
        end
    end

    return {
        focus_exact = function(window)
            local plan = model.exact_focus_plan(window)
            if not plan then return false end

            select_group(plan.group)
            hl.dispatch(hl.dsp.focus({ window = plan.window }))
            return true
        end,

        previous_group = function(window, windows)
            local plan = model.previous_group_plan(window, windows)
            if not plan then return false end

            select_group(plan)
            return true
        end,

        next_group = function(window)
            local plan = model.next_group_plan(window)
            if not plan then return false end

            select_group(plan)
            return true
        end,
    }
end

return M
