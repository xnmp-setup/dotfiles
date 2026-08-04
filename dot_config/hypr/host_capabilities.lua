local M = {}

local BATTERY_PREFIXES = { "BAT", "CMB" }

local function read_line(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local value = file:read("*l")
    file:close()
    return value
end

---@param reader? fun(path: string): string|nil
---@return boolean
function M.has_battery(reader)
    reader = reader or read_line
    for _, prefix in ipairs(BATTERY_PREFIXES) do
        for index = 0, 9 do
            local path = ("/sys/class/power_supply/%s%d/type"):format(prefix, index)
            if reader(path) == "Battery" then return true end
        end
    end
    return false
end

return M
