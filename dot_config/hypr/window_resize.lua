-- Tiled/floating resize routing and held-key acceleration.

local M = {}

local DEFAULT_ACCEL = {
    base = 40,
    max = 200,
    increment = 30,
    idle_ms = 400,
}

function M.new(hl, options)
    options = options or {}
    local config = options.acceleration or DEFAULT_ACCEL
    local acceleration = { step = config.base, generation = 0 }

    local function resize_tile(dx, dy)
        return function()
            local active = hl.get_active_window()
            if active and active.floating then
                hl.dispatch(hl.dsp.window.resize({
                    x = dx,
                    y = dy,
                    relative = true,
                }))
            else
                hl.dispatch(hl.dsp.layout(("resize %d %d"):format(dx, dy)))
            end
        end
    end

    local function accelerated(sign)
        return function()
            local step = sign * acceleration.step
            hl.dispatch(hl.dsp.layout(("resize %d %d"):format(step, step)))
            acceleration.step = math.min(
                config.max,
                acceleration.step + config.increment
            )

            acceleration.generation = acceleration.generation + 1
            local generation = acceleration.generation
            hl.timer(function()
                if acceleration.generation == generation then
                    acceleration.step = config.base
                end
            end, { timeout = config.idle_ms, type = "oneshot" })
        end
    end

    return {
        resize_tile = resize_tile,
        accelerated = accelerated,
    }
end

return M
