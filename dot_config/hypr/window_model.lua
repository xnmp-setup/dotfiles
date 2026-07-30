-- window_model.lua — pure window/group queries and focus planning.
--
-- Hyprland window values are live handles, but deciding what they mean does not
-- need a compositor. Keeping these operations pure gives every feature one
-- definition of window identity and exact grouped-tab focus.

local M = {}

function M.id(window)
    if not window then return nil end
    return window.stable_id or window.address
end

function M.same(a, b)
    local a_id, b_id = M.id(a), M.id(b)
    return a_id ~= nil and a_id == b_id
end

function M.direction_towards(from, to)
    if not (from and from.at and from.size and to and to.at and to.size) then
        return nil
    end

    local dx = (to.at.x + to.size.x / 2) - (from.at.x + from.size.x / 2)
    local dy = (to.at.y + to.size.y / 2) - (from.at.y + from.size.y / 2)
    if math.abs(dx) >= math.abs(dy) then
        return dx < 0 and "left" or "right"
    end
    return dy < 0 and "up" or "down"
end

function M.group_members(group)
    local members = group and group.members
    if not members then return {} end
    if M.id(members) then return { members } end
    return members
end

function M.group_index(window)
    local id = M.id(window)
    if not id then return nil end

    for index, member in ipairs(M.group_members(window.group)) do
        if M.id(member) == id then return index end
    end
end

-- A plan is data, not a dispatch: adapters and tests can consume the same
-- decision. `group` is omitted for ordinary windows.
function M.exact_focus_plan(window)
    if not (window and window.mapped) then return nil end

    local plan = { window = window }
    local group = window.group
    if group and group.size > 1 then
        local index = M.group_index(window)
        if index then
            plan.group = {
                index = index,
                window = group.current or window,
            }
        end
    end
    return plan
end

function M.next_group_plan(window)
    local group = window and window.group
    if not (group and group.size > 1) then return nil end

    local members = M.group_members(group)
    local current = M.group_index(window) or group.current_index
    if not (current and #members > 1) then return nil end

    return {
        index = current % #members + 1,
        window = group.current or window,
    }
end

return M
