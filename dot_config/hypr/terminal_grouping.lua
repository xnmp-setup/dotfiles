-- terminal_grouping.lua — group GUI windows with the terminal that launched them.

local window_model = require("window_model")

local M = {}

local TERMINAL_CLASSES = {
    ["com.mitchellh.ghostty"] = true,
    ["org.wezfurlong.wezterm"] = true,
}

-- These apps commonly forward a CLI launch to an existing GUI process, which
-- severs /proc ancestry. Limit the focus fallback to known forwarders so an
-- unrelated window opening while a terminal is focused is not auto-grouped.
local FOCUS_FALLBACK_CLASSES = {
    ["dev.zed.Zed"] = true,
    ["dev.zed.Zed-Dev"] = true,
    ["google-chrome"] = true,
    ["obsidian"] = true,
    ["tauri-explorer"] = true,
}

local function proc_parent_pid(pid)
    local file = io.open("/proc/" .. tostring(pid) .. "/stat", "r")
    if not file then return nil end
    local stat = file:read("*l")
    file:close()
    return stat and tonumber(stat:match("^%d+ %b() %S+ (%d+)")) or nil
end

function M.new(hl, options)
    options = options or {}
    local parent_pid = options.parent_pid or proc_parent_pid
    local direction_towards = options.direction_towards
        or window_model.direction_towards
    local consume_managed_launch = options.consume_managed_launch
        or function() return false end
    local exclude_source = options.exclude_source
        or function() return false end

    local function is_terminal(window)
        return window and TERMINAL_CLASSES[window.class] == true
    end

    local function terminal_ancestor(window)
        local terminals = {}
        for _, candidate in ipairs(hl.get_windows() or {}) do
            if candidate.mapped and is_terminal(candidate)
                and not window_model.same(candidate, window)
            then
                local pid = tonumber(candidate.pid)
                if pid then
                    terminals[pid] = terminals[pid] or {}
                    terminals[pid][#terminals[pid] + 1] = candidate
                end
            end
        end

        local seen = {}
        local pid = tonumber(window and window.pid)
        while pid and pid > 1 and not seen[pid] do
            seen[pid] = true
            local matches = terminals[pid]
            if matches then
                table.sort(matches, function(a, b)
                    return (a.focus_history_id or math.huge)
                        < (b.focus_history_id or math.huge)
                end)
                return matches[1]
            end
            pid = parent_pid(pid)
        end
    end

    local focus_serial = 0
    local recent_terminal

    local initially_active = hl.get_active_window()
    if is_terminal(initially_active) then
        recent_terminal = { window = initially_active, serial = focus_serial }
    end

    hl.on("window.active", function()
        focus_serial = focus_serial + 1
        local active = hl.get_active_window()
        if is_terminal(active) then
            recent_terminal = { window = active, serial = focus_serial }
        end
    end)

    local function launch_source(window)
        local ancestor = terminal_ancestor(window)
        if ancestor then return ancestor end

        if FOCUS_FALLBACK_CLASSES[window.class]
            and recent_terminal
            and focus_serial - recent_terminal.serial <= 1
            and recent_terminal.window.mapped
        then
            return recent_terminal.window
        end
    end

    hl.on("window.open", function(window)
        if not (window and window.mapped) then return end
        local source = launch_source(window)
        if not source then return end

        if exclude_source(source) then return end

        hl.timer(function()
            if consume_managed_launch(window) then return end
            if not (window.mapped and source.mapped) or window.floating then return end
            if window.group and window.group.size > 1 then return end

            local window_ws = window.workspace
            local source_ws = source.workspace
            if not (window_ws and source_ws
                and window_ws.id > 0
                and window_ws.id == source_ws.id
                and window.at and window.size and source.at and source.size)
            then
                return
            end

            hl.dispatch(hl.dsp.window.move({
                window = window,
                into_or_create_group = direction_towards(window, source),
            }))
        end, { timeout = 80, type = "oneshot" })
    end)
end

return M
