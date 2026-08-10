local M = {}

local function output_name(monitor)
    if type(monitor) == "string" then
        return monitor:match("^[%w_.-]+$") and monitor or nil
    end
    if monitor == nil then return nil end
    local ok, name = pcall(function() return monitor.name end)
    if not ok then return nil end
    if type(name) ~= "string" or not name:match("^[%w_.-]+$") then return nil end
    return name
end

local function is_builtin(name)
    return name:match("^eDP") or name:match("^LVDS") or name:match("^DSI")
end

local function classified_outputs(monitors)
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
    return builtins, externals
end

---@param monitors table[]|nil
---@return boolean
function M.has_builtin(monitors)
    local builtins = classified_outputs(monitors)
    return builtins[1] ~= nil
end

--- Select a stable source/target pair without depending on connector numbering.
---@param monitors table[]|nil
---@return table|nil
function M.plan(monitors)
    local builtins, externals = classified_outputs(monitors)
    if not builtins[1] or not externals[1] then return nil end
    return { target = builtins[1], source = externals[1] }
end

---@param plan table|nil
---@return table[]|nil
function M.mirror_specs(plan)
    if not plan then return nil end
    return {
        { output = plan.source, mode = "preferred", position = "0x0", scale = 1 },
        {
            output = plan.target,
            mode = "preferred",
            position = "auto",
            scale = 1,
            mirror = plan.source,
        },
    }
end

---@param monitors table[]|nil
---@return table|nil
function M.standalone_spec(monitors)
    local builtins = classified_outputs(monitors)
    if not builtins[1] then return nil end
    return {
        output = builtins[1],
        mode = "preferred",
        position = "auto",
        scale = 1,
    }
end

--- Find ordinary workspaces whose owning output is no longer present.
--- Pure so monitor transitions can be tested without a compositor.
---@param workspaces table[]|nil
---@param monitors table[]|nil
---@return table[]
function M.orphaned_workspaces(workspaces, monitors)
    local present = {}
    for _, monitor in ipairs(monitors or {}) do
        local name = output_name(monitor)
        if name then present[name] = true end
    end

    local orphaned = {}
    for _, workspace in ipairs(workspaces or {}) do
        local id = workspace and workspace.id
        local monitor = workspace and output_name(workspace.monitor)
        if type(id) == "number"
            and id == math.floor(id)
            and id >= 1
            and id <= 2147483647
            and not present[monitor]
        then
            orphaned[#orphaned + 1] = workspace
        end
    end
    table.sort(orphaned, function(left, right) return left.id < right.id end)
    return orphaned
end

---@param hl table
---@param options? { enabled?: boolean }
---@return table
function M.new(hl, options)
    options = options or {}

    local function reconcile()
        if options.enabled == false then return end
        local monitors = hl.get_monitors()
        if not M.has_builtin(monitors) then return end

        local specs = M.mirror_specs(M.plan(monitors))
        if not specs then
            local standalone = M.standalone_spec(monitors)
            hl.monitor(standalone)
            for _, workspace in ipairs(M.orphaned_workspaces(hl.get_workspaces(), monitors)) do
                hl.dispatch(hl.dsp.workspace.move({
                    workspace = workspace,
                    monitor = standalone.output,
                }))
            end
            return
        end
        for _, spec in ipairs(specs) do hl.monitor(spec) end
    end

    hl.on("hyprland.start", reconcile)
    hl.on("monitor.added", reconcile)
    hl.on("monitor.removed", reconcile)
    hl.on("config.reloaded", reconcile)

    return { reconcile = reconcile }
end

return M
