-- expose.lua — temporarily unfold grouped tabs into selectable panes.

local window_model = require("window_model")

local M = {}

local function copy_box(window)
    local at, size = window and window.at, window and window.size
    if not (at and size) then return nil end
    return { x = at.x, y = at.y, w = size.x, h = size.y }
end

local function grid_boxes(box, count, columns)
    local boxes = {}
    if not (box and count > 0 and columns > 0) then return boxes end

    local rows = math.ceil(count / columns)
    for index = 1, count do
        local column = (index - 1) % columns
        local row = math.floor((index - 1) / columns)
        local left = math.floor(box.x + box.w * column / columns)
        local right = math.floor(box.x + box.w * (column + 1) / columns)
        local top = math.floor(box.y + box.h * row / rows)
        local bottom = math.floor(box.y + box.h * (row + 1) / rows)
        boxes[index] = {
            x = left,
            y = top,
            w = right - left,
            h = bottom - top,
        }
    end
    return boxes
end

-- How many columns to use for `n` panes in a tile. Every count is tried and
-- scored by cell squareness plus the unevenness of an incomplete last row.
function M.grid_columns(w, h, n)
    if n < 2 or not w or not h or w <= 0 or h <= 0 then return 1 end

    local best, best_cost = 1, nil
    for cols = n, 1, -1 do
        local rows = math.ceil(n / cols)
        local aspect = (w / cols) / (h / rows)
        local cost = math.abs(math.log(aspect)) + (rows * cols - n) / n
        if not best_cost or cost < best_cost then
            best, best_cost = cols, cost
        end
    end
    return best
end

function M.new(hl, options)
    options = options or {}
    local dissolve_lone_groups = options.dissolve_lone_groups or function() end

    local exposed
    local armed = false
    local busy = false
    local select_button = options.select_button or "mouse:272"
    local expose_click

    local function visible_workspaces()
        local ids = {}
        for _, monitor in ipairs(hl.get_monitors() or {}) do
            local workspace = monitor.active_workspace
            local special = monitor.active_special_workspace
            if workspace and workspace.id then ids[workspace.id] = true end
            if special and special.id then ids[special.id] = true end
        end
        return ids
    end

    local function window_at_cursor()
        local pos = hl.get_cursor_pos()
        if not pos then return nil end

        local visible = visible_workspaces()
        local best
        for _, window in ipairs(hl.get_windows() or {}) do
            local at, size = window.at, window.size
            if window.mapped and not window.hidden and at and size
                and window.workspace and visible[window.workspace.id]
                and pos.x >= at.x and pos.x < at.x + size.x
                and pos.y >= at.y and pos.y < at.y + size.y
            then
                local over = not best
                    or (window.floating and not best.floating)
                    or (window.floating == best.floating
                        and (window.focus_history_id or 0)
                            < (best.focus_history_id or 0))
                if over then best = window end
            end
        end
        return best
    end

    local function tabbed_groups()
        local workspace = hl.get_active_workspace()
        local seen, groups = {}, {}

        for _, window in ipairs(hl.get_windows() or {}) do
            local group = window.group
            if group and group.size > 1 and group.current
                and workspace and window.workspace
                and window.workspace.id == workspace.id
            then
                local anchor = group.current
                local key = tostring(window_model.id(anchor))
                if not seen[key] then
                    seen[key] = true
                    local rest = {}
                    for _, member in ipairs(window_model.group_members(group)) do
                        if not window_model.same(member, anchor) then
                            rest[#rest + 1] = member
                        end
                    end
                    groups[#groups + 1] = {
                        anchor = anchor,
                        rest = rest,
                        floating = anchor.floating or false,
                        box = copy_box(anchor),
                    }
                end
            end
        end
        return groups
    end

    local function unfold()
        local groups = tabbed_groups()
        if #groups == 0 then return false end

        busy = true
        for _, group in ipairs(groups) do
            local size = group.anchor.size
            group.cols = M.grid_columns(
                size and size.x,
                size and size.y,
                #group.rest + 1
            )
            hl.dispatch(hl.dsp.layout(
                ("explode %s %d"):format(window_model.id(group.anchor), group.cols)
            ))
        end
        for _, group in ipairs(groups) do
            hl.dispatch(hl.dsp.group.toggle({ window = group.anchor }))
        end
        -- A floating group is absent from nary's target list, so the layout
        -- message above cannot place its newly freed members. Arrange that one
        -- group directly inside its original box; folding restores the box.
        for _, group in ipairs(groups) do
            if group.floating and group.box then
                local members = { group.anchor }
                for _, window in ipairs(group.rest) do members[#members + 1] = window end
                local boxes = grid_boxes(group.box, #members, group.cols)
                for index, window in ipairs(members) do
                    local box = boxes[index]
                    hl.dispatch(hl.dsp.window.resize({
                        x = box.w, y = box.h, window = window,
                    }))
                    hl.dispatch(hl.dsp.window.move({
                        x = box.x, y = box.y, window = window,
                    }))
                end
            end
        end
        busy = false

        exposed, armed = groups, false
        hl.timer(function() armed = (exposed ~= nil) end, {
            timeout = 120,
            type = "oneshot",
        })
        hl.bind(select_button, expose_click)
        return true
    end

    local function fold(selected)
        if not exposed then return false end

        selected = selected or hl.get_active_window()
        local selected_id = window_model.id(selected)
        local groups = exposed
        exposed, armed = nil, false
        hl.unbind(select_button)

        busy = true
        for _, group in ipairs(groups) do
            local merged, raise = 0, 1
            for index, window in ipairs(group.rest) do
                if window.mapped then
                    local direction = (index < (group.cols or 1))
                        and "left" or "up"
                    hl.dispatch(hl.dsp.window.move({
                        window = window,
                        into_or_create_group = direction,
                    }))
                    merged = merged + 1
                    if window_model.id(window) == selected_id then
                        raise = merged + 1
                    end
                end
            end

            if merged > 0 and group.anchor.mapped then
                hl.dispatch(hl.dsp.group.active({
                    index = raise,
                    window = group.anchor,
                }))
            end

            if group.floating and group.box and group.anchor.mapped then
                hl.dispatch(hl.dsp.window.resize({
                    x = group.box.w, y = group.box.h, window = group.anchor,
                }))
                hl.dispatch(hl.dsp.window.move({
                    x = group.box.x, y = group.box.y, window = group.anchor,
                }))
            end
        end

        if selected and selected.mapped then
            hl.dispatch(hl.dsp.focus({ window = selected }))
        end
        busy = false
        dissolve_lone_groups()
        return true
    end

    hl.on("window.active", function()
        if exposed and armed and not busy then fold() end
    end)

    expose_click = function()
        if not exposed then return end
        local window = window_at_cursor()
        if window then fold(window) end
    end

    return {
        is_active = function() return exposed ~= nil end,
        select_target = fold,
        toggle = function()
            if exposed then return fold() end
            return unfold()
        end,
    }
end

return M
