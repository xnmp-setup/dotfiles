local M = {}

local UNIT = "laptop-display-mirror.service"

local function output_name(monitor)
    local name = monitor and monitor.name
    if type(name) ~= "string" or not name:match("^[%w_.-]+$") then return nil end
    return name
end

local function is_builtin(name)
    return name:match("^eDP") or name:match("^LVDS") or name:match("^DSI")
end

---@param monitors table[]|nil
---@return boolean
function M.has_builtin(monitors)
    for _, monitor in ipairs(monitors or {}) do
        local name = output_name(monitor)
        if name and is_builtin(name) then return true end
    end
    return false
end

--- Select a stable source/target pair without depending on connector numbering.
---@param monitors table[]|nil
---@return table|nil
function M.plan(monitors)
    local builtins, externals = {}, {}
    for _, monitor in ipairs(monitors or {}) do
        local name = output_name(monitor)
        if name then
            local outputs = is_builtin(name) and builtins or externals
            outputs[#outputs + 1] = name
        end
    end

    table.sort(builtins)
    table.sort(externals)
    if not builtins[1] or not externals[1] then return nil end
    return { target = builtins[1], source = externals[1] }
end

---@param plan table|nil
---@return string
function M.command(plan)
    local stop = "systemctl --user stop " .. UNIT .. " >/dev/null 2>&1 || true"
    if not plan then return stop end

    -- Software mirroring keeps both outputs independently color-managed. Hardware
    -- mirrors bypass the follower's wlsunset transform in Hyprland 0.55.
    return stop
        .. "; mirror_bin=$(command -v wl-mirror) || exit 0"
        .. "; exec systemd-run --user --quiet --collect"
        .. " --unit=" .. UNIT
        .. " --property=Restart=on-failure --property=RestartSec=1s"
        .. " -- \"$mirror_bin\" --scaling fit"
        .. " --fullscreen-output " .. plan.target
        .. " --title laptop-display-mirror " .. plan.source
end

---@param hl table
---@return table
function M.new(hl)
    local function reconcile()
        local monitors = hl.get_monitors()
        -- Desktop-only systems share this config but never own this service.
        if not M.has_builtin(monitors) then return end
        hl.exec_cmd(M.command(M.plan(monitors)))
    end

    hl.on("hyprland.start", reconcile)
    hl.on("monitor.added", reconcile)
    hl.on("monitor.removed", reconcile)
    hl.on("config.reloaded", reconcile)

    return { reconcile = reconcile }
end

return M
