local M = {}

local WLSUNSET =
    "wlsunset -l -33.87 -L 151.21 -t 3500 -T 6500"
local HYPRSHADE =
    "sh -c 'dbus-update-activation-environment --systemd"
    .. " HYPRLAND_INSTANCE_SIGNATURE && exec hyprshade auto'"

---@param is_laptop boolean
---@return string
function M.command(is_laptop)
    return is_laptop and HYPRSHADE or WLSUNSET
end

---@param hl table
---@param is_laptop boolean
function M.start(hl, is_laptop)
    hl.exec_cmd(M.command(is_laptop))
end

return M
