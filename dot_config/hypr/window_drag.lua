-- Capture a tiled drag at press and rearrange only after Hyprland has retiled
-- it. Native drag ends before release binds run (ensureMouseBindState), so a
-- release bind can issue a layout command without a timer or floating toggle.
local M = {}
local window_model = require("window_model")

function M.new(hl, modifier)
    local gesture
    local function uses_nary(window)
        local layout = window.layout
        return layout and layout.name == "lua:nary"
    end

    local pickup
    local function begin()
        gesture, pickup = nil, nil
        local pos = hl.get_cursor_pos()
        if not pos then return end
        local eligible = {}
        for _, window in ipairs(hl.get_windows() or {}) do
            if window.mapped and not window.hidden and not window.floating and uses_nary(window) then
                local members = { [tostring(window.stable_id)] = true }
                for _, member in ipairs(window_model.group_members(window.group)) do
                    members[tostring(member.stable_id)] = true
                end
                eligible[tostring(window.stable_id)] = members
            end
        end
        pickup = { eligible = eligible, start = { x = pos.x, y = pos.y } }
    end

    local function arm()
        -- Native dragBegin focuses its actual hit-tested target. Read that
        -- after dispatch so decoration extents and animations use Hyprland's
        -- own hit test, rather than duplicating it with content rectangles.
        local window = hl.get_active_window()
        if pickup and window and pickup.eligible[tostring(window.stable_id)] then
            gesture = { window = window, start = pickup.start,
                members = pickup.eligible[tostring(window.stable_id)] }
        end
        pickup = nil
    end

    local function finish()
        local drag = gesture
        gesture = nil
        if not drag then return end
        local window = drag.window
        local pos = drag.interrupted_at or hl.get_cursor_pos()
        if not pos or not window.mapped or window.floating or not uses_nary(window) then return end
        -- A native tab-strip drop may have joined another group. Let that
        -- explicit grouping stand instead of moving the combined tile.
        for _, member in ipairs(window_model.group_members(window.group)) do
            if not drag.members[tostring(member.stable_id)] then return end
        end
        local dx, dy = pos.x - drag.start.x, pos.y - drag.start.y
        if dx * dx + dy * dy <= 25 then return end
        hl.dispatch(hl.dsp.layout(("drop %s %.17g %.17g"):format(window.stable_id, pos.x, pos.y)))
    end

    -- Observe the press before the native dispatcher removes the tile. These
    -- observers are transparent so the native drag binding still runs.
    hl.bind(modifier .. " + mouse:272", begin, { transparent = true, non_consuming = true })
    local native_drag = hl.dsp.window.drag()
    hl.bind(modifier .. " + mouse:272", function()
        local result = hl.dispatch(native_drag)
        -- The dispatcher also runs on release (releasePending), when pickup
        -- has already been spent. A miss passes the event through; do not arm
        -- whichever unrelated tile happened to have focus on wallpaper.
        if pickup then
            if result.ok and not result.pass_event then arm() else pickup = nil end
        end
        return result
    end, { mouse = true })
    hl.bind("mouse:272", finish, {
        release = true, ignore_mods = true, transparent = true, non_consuming = true,
    })
    -- Native dragging also ends on keyboard input. Save that position before
    -- the native handler runs, including when Cmd is released first.
    hl.on("input.keyboard.key", function()
        if gesture and not gesture.interrupted_at then
            local pos = hl.get_cursor_pos()
            if pos then gesture.interrupted_at = { x = pos.x, y = pos.y } end
        end
    end)
    for _, key in ipairs({ "Super_L", "Super_R", "Control_L", "Control_R", "Alt_L", "Alt_R", "Shift_L", "Shift_R" }) do
        hl.bind(key, finish, {
            release = true, ignore_mods = true, transparent = true, non_consuming = true,
        })
    end
    hl.on("window.close", function(window)
        if gesture and window.stable_id == gesture.window.stable_id then gesture = nil end
    end)
    return { begin = begin, arm = arm, finish = finish }
end

return M
