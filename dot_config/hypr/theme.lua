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
--- lands at the bottom, stops are evenly spaced, and the ramp pads past its
--- end stops. Transparent stops carve gaps into the fill — the only per-tab
--- shaping there is, since gaps_out is global to the bar — but a carved edge
--- is always square; only the rect's real edges get gradient_rounding. So
--- pills keep their real (rounded) top, and only the bottom is ever carved:
--- a `detached` tab gets transparent bottom stops (~4px of the bar) so its
--- pill floats above the window, while the focused tab keeps its body all
--- the way down and touches it. The FIRST stop doubles as the colour of the
--- indicator strip tucked under the pill (see the groupbar comment in
--- hyprland.lua): opaque there it squares the focused pill's bottom
--- corners; transparent here it vanishes under detached pills.
--- @param hex string        body colour of the pill
--- @param alpha string|nil  alpha for the body of the pill
--- @param detached boolean  lift the pill off the window's top edge
function M.tab_fill(hex, alpha, detached)
    local clear, body = M.rgba(hex, "00"), M.rgba(hex, alpha)
    local stops = {}
    for i = 1, 16 do
        stops[i] = (detached and i <= 2) and clear or body
    end
    return { colors = stops, angle = 0 }
end

return M
