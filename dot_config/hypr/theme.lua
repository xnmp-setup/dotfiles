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
    mode         = "dark",
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

-- Keep light windows nearly solid: a faint wallpaper tint without washed-out ink.
-- This is the only transparency layer in light mode; Ghostty adds none of its
-- own (background-opacity 1), so every app shows the same tint.
function M.window_opacity(dark_opacity)
    local opacity = M.colors.mode == "light" and "0.94" or tostring(dark_opacity)
    return opacity .. " " .. opacity
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

--- Linear blend of two hex colours: mix("000000", "ffffff", 0.25) -> "404040".
--- @param a string  hex colour at t = 0
--- @param b string  hex colour at t = 1
--- @param t number  0..1
function M.mix(a, b, t)
    local out = {}
    for i = 1, 5, 2 do
        local ca, cb = tonumber(a:sub(i, i + 1), 16), tonumber(b:sub(i, i + 1), 16)
        out[#out + 1] = ("%02x"):format(math.floor(ca + (cb - ca) * t + 0.5))
    end
    return table.concat(out)
end

--- The focused tab's body: the background nudged toward the accent, so the
--- pill carries the theme's hue instead of a neutral lift toward the text.
--- Light themes take a lighter touch — a saturated tint under dark ink reads
--- muddy, and the accent edge already does the pointing.
--- @param t number|nil  extra push toward the accent, 0..1 (default 0)
function M.tab_tint(t)
    local base = M.colors.mode == "light" and 0.10 or 0.16
    return M.mix(M.colors.background, M.colors.accent, base + (t or 0))
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
--- The same ramp is also the only way to give a tab any internal detail, so
--- the body may be a bottom-to-top gradient and may end in an `edge`: a band
--- of a second colour along the top of the pill, which the rect's rounding
--- clips into the corner curve. That is how the focused tab gets its accent
--- line without an indicator (see the groupbar block for why not).
---
--- Stops sit half a pixel apart, which is what makes the carve line land on a
--- pixel boundary instead of straddling one. Cairo interpolates between
--- adjacent stops, so the fill ramps from clear to opaque over that half
--- pixel; each screen row samples the ramp at its centre, and with the last
--- clear stop at `carve - 0.5` the row below the line reads 0 and the row
--- above reads 1. A whole-pixel spacing would put a half-lit row on the
--- window's border instead. The edge boundary is placed the same way.
--- (Cairo works in the texture's own space, not the screen's; the two
--- coincide because the fill is stretched to the rect.)
---
--- @param spec table|string  body colour hex, or {
---   bottom  = hex,        body colour at the carve line
---   top     = hex|nil,    body colour just under the edge (default: bottom)
---   alpha   = string|nil, body alpha, two hex digits (default "ff")
---   edge    = hex|nil,    colour of the band along the top of the pill
---   edge_px = number|nil, height of that band in px (default 2)
--- }
--- @param alpha string|nil  body alpha when `spec` is a plain hex string
--- @param height number     height of the tab rect in px (group:groupbar:height)
--- @param carve number      px carved off the bottom of the rect
function M.tab_fill(spec, alpha, height, carve)
    if type(spec) == "string" then spec = { bottom = spec, alpha = alpha } end
    local bottom, top = spec.bottom, spec.top or spec.bottom
    local body_alpha  = spec.alpha or "ff"
    local edge_px     = spec.edge and (spec.edge_px or 2) or 0
    local edge_at     = height - edge_px -- px above the rect's bottom
    local body_span   = math.max(edge_at - carve, 1)

    local stops = {}
    for i = 1, height * 2 - 1 do -- stop i sits i/2 px above the rect's bottom
        local y = i / 2
        if y <= carve - 0.5 then
            stops[i] = M.rgba(bottom, "00")
        elseif y <= edge_at - 0.5 then
            stops[i] = M.rgba(M.mix(bottom, top, (y - carve) / body_span), body_alpha)
        else
            stops[i] = M.rgba(spec.edge)
        end
    end
    return { colors = stops, angle = 0 }
end

return M
