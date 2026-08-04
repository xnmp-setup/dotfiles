local M = {}

-- Sydney. One source of truth for both backends, so a laptop's shader and a
-- desktop's wlsunset warm the screen at the same solar moments.
local LATITUDE = -33.87
local LONGITUDE = 151.21
local NIGHT_TEMP = 3500
local DAY_TEMP = 6500

local WLSUNSET = ("wlsunset -l %s -L %s -t %d -T %d")
    :format(LATITUDE, LONGITUDE, NIGHT_TEMP, DAY_TEMP)

-- hyprshade can only schedule fixed clock times, so hyprshade_solar.py owns
-- the schedule and toggles the shader at sunset and sunrise itself, using
-- wlsunset's own solar math. Where python3 is absent we fall back to
-- `hyprshade auto` and the fixed hours in hyprshade.toml -- worse, but still
-- a night light.
local SOLAR = ('"$HOME"/.config/hypr/hyprshade_solar.py --lat %s --lon %s')
    :format(LATITUDE, LONGITUDE)
local HYPRSHADE =
    "sh -c 'dbus-update-activation-environment --systemd"
    .. " HYPRLAND_INSTANCE_SIGNATURE;"
    .. " { command -v python3 >/dev/null 2>&1 && exec " .. SOLAR .. "; };"
    .. " exec hyprshade auto'"

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
