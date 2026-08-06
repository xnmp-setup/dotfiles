-- theme.lua — the palette Hyprland paints itself with.
--
-- Colours are not edited here. scripts/set-theme.sh derives them from the
-- theme's tauri-explorer stylesheet — the same source it already reads to build
-- Dark Reader's palette — and writes theme-colors.lua next to this file. So
-- switching themes moves the window borders, the tab strip and the backdrop
-- behind a resize along with the terminal and the editor, instead of leaving
-- Hyprland on whatever it was built with.
--
-- The defaults below are Cosmic Dusk and are what shows when that file is
-- absent: a fresh machine, or a theme with no stylesheet to read.

local M = {}

local defaults = {
    accent       = "d4607a", -- borders and the locked-group tint
    accent_light = "e87898", -- the far end of the active-border gradient
    background   = "0a0e28", -- also what shows through a window mid-resize
    surface      = "2a3352", -- background lifted toward the text: the active tab
    border       = "3c4268", -- inactive window borders
    text         = "d8dce8",
    text_dim     = "8088b4",
}

-- Dropped from the cache first: a `hyprctl reload` re-runs this config, and a
-- module still loaded from the previous run would hand back the old palette.
package.loaded["theme-colors"] = nil
local ok, generated = pcall(require, "theme-colors")

M.colors = defaults
if ok and type(generated) == "table" then
    -- Anything the generator could not derive falls through to the default,
    -- so a partial file degrades one colour at a time rather than all of them.
    M.colors = setmetatable(generated, { __index = defaults })
end

--- "d4607a" -> "rgba(d4607aff)". Alpha is the usual two hex digits.
--- @param hex string
--- @param alpha string|nil
function M.rgba(hex, alpha)
    return ("rgba(%s%s)"):format(hex, alpha or "ff")
end

--- The two-stop gradient used for anything focused.
--- @param angle number|nil
function M.active_gradient(angle)
    return {
        colors = { M.rgba(M.colors.accent), M.rgba(M.colors.accent_light) },
        angle  = angle or 45,
    }
end

--- A groupbar tab fill. The groupbar renders its fill as a vertical cairo
--- ramp stretched over the tab rect: the angle is ignored, the FIRST colour
--- lands at the bottom, stops are spaced evenly across the rect, and the ramp
--- pads past its end stops. Transparent stops therefore carve the bottom of
--- the fill away — the only per-tab shaping there is, since every other
--- groupbar geometry knob is global to the bar. A carved edge is square while
--- the rect's real edges get gradient_rounding, so carving is also how a pill
--- gets a square bottom under a rounded top: hang the rect below the bar by
--- more than the corner radius and carve everything that hangs over, and the
--- real (rounded) bottom corners are cut off along with it.
---
--- Stops sit half a pixel apart, which is what makes the carve line land on a
--- pixel boundary instead of straddling one. Cairo interpolates between
--- adjacent stops, so the fill ramps from clear to opaque over that half
--- pixel; each screen row samples the ramp at its centre, and with the last
--- clear stop at `carve - 0.5` the row below the line reads 0 and the row
--- above reads 1. A whole-pixel spacing would put a half-lit row on the
--- window's border instead. (Cairo works in the texture's own space, not the
--- screen's; the two coincide because the fill is stretched to the rect.)
---
--- @param hex string        body colour of the pill
--- @param alpha string|nil  alpha for the body of the pill
--- @param height number     height of the tab rect in px (group:groupbar:height)
--- @param carve number      px carved off the bottom of the rect
function M.tab_fill(hex, alpha, height, carve)
    local clear, body = M.rgba(hex, "00"), M.rgba(hex, alpha)
    local stops = {}
    for i = 1, height * 2 - 1 do -- stop i sits i/2 px above the rect's bottom
        stops[i] = i <= carve * 2 - 1 and clear or body
    end
    return { colors = stops, angle = 0 }
end

return M
