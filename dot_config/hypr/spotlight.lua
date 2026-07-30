-- spotlight.lua — temporarily pull one window onto a dimmed special workspace.

local M = {}

function M.centred_size(monitor)
    if not (monitor and monitor.width and monitor.height) then return nil end
    local scale = monitor.scale or 1
    return {
        math.floor(monitor.width / scale * 0.5),
        math.floor(monitor.height / scale * 0.8),
    }
end

function M.new(hl, window_actions, options)
    options = options or {}
    local workspace = options.workspace or "spotlight"
    local default_dim = options.default_dim or 0.4
    local spotlit

    local function is_visible()
        for _, monitor in ipairs(hl.get_monitors() or {}) do
            local special = monitor.active_special_workspace
            if special and (special.name == workspace
                or special.name == "special:" .. workspace)
            then
                return true
            end
        end
        return false
    end

    local function hide()
        local held = spotlit
        spotlit = nil
        hl.config({ decoration = { dim_special = default_dim } })
        if not held then return false end

        for _, window in ipairs(hl.get_windows() or {}) do
            if window.address == held.address then
                if is_visible() then
                    hl.dispatch(hl.dsp.workspace.toggle_special(workspace))
                end
                hl.dispatch(hl.dsp.window.move({
                    workspace = tostring(held.home),
                    silent = true,
                    window = window,
                }))
                if held.floated then
                    if window.floating then
                        hl.dispatch(hl.dsp.window.float({
                            action = "off",
                            window = window,
                        }))
                        hl.dispatch(hl.dsp.layout("restore"))
                    end
                elseif held.geometry then
                    hl.dispatch(hl.dsp.window.resize({
                        x = held.geometry.size.x,
                        y = held.geometry.size.y,
                        window = window,
                    }))
                    hl.dispatch(hl.dsp.window.move({
                        x = held.geometry.at.x,
                        y = held.geometry.at.y,
                        window = window,
                    }))
                end
                window_actions.focus_exact(window)
                return true
            end
        end
        return false
    end

    local function show(window, show_options)
        if not window then return false end
        show_options = show_options or {}

        local home = window.workspace and window.workspace.id
        if not home then return false end

        local floated = not window.floating
        local geometry
        if floated then
            hl.dispatch(hl.dsp.layout("hold"))
            hl.dispatch(hl.dsp.window.float({
                action = "on",
                window = window,
            }))
        else
            geometry = { at = window.at, size = window.size }
        end

        spotlit = {
            address = window.address,
            home = home,
            floated = floated,
            geometry = geometry,
            transitioning = true,
        }
        hl.config({
            decoration = {
                dim_special = show_options.dim or default_dim,
            },
        })
        hl.dispatch(hl.dsp.window.move({
            workspace = "special:" .. workspace,
            silent = true,
            window = window,
        }))
        hl.dispatch(hl.dsp.workspace.toggle_special(workspace))
        hl.dispatch(hl.dsp.focus({ window = window }))
        if show_options.size then
            hl.dispatch(hl.dsp.window.resize({
                x = show_options.size[1],
                y = show_options.size[2],
                window = window,
            }))
        end
        hl.dispatch(hl.dsp.window.center({ window = window }))
        spotlit.transitioning = false
        return true
    end

    local function toggle()
        local active = hl.get_active_window()
        if not active then return false end

        if spotlit and spotlit.address == active.address then
            return hide()
        end
        return show(active, {
            size = M.centred_size(hl.get_active_monitor()),
            dim = options.toggle_dim or 0.2,
        })
    end

    hl.on("window.open", function(window)
        if window and window.class == (options.auto_class or "imv") then
            show(window)
        end
    end)

    hl.on("window.active", function()
        if not spotlit or spotlit.transitioning then return end
        local active = hl.get_active_window()
        if not active or active.address ~= spotlit.address then hide() end
    end)

    hl.on("window.close", function(window)
        if spotlit and window and window.address == spotlit.address then hide() end
    end)

    return {
        hide = hide,
        is_active = function() return spotlit ~= nil end,
        show = show,
        toggle = toggle,
    }
end

return M
