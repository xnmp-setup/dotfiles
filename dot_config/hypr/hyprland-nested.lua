-- Nested test config for the nary layout.
--
-- Hyprland picks its config manager (legacy vs lua) once at startup from the
-- file extension, so `hyprctl reload` can never switch a running .conf session
-- over to .lua. Rather than restart your real session to find out whether nary
-- works, run a second Hyprland inside the current one:
--
--     HYPRLAND_CONFIG=~/.config/hypr/hyprland-nested.lua Hyprland
--
-- It opens as a normal window on the Wayland backend. Close it to exit.
--
-- This file is NOT the real config — Hyprland only auto-discovers the exact
-- name "hyprland.lua", so this one is inert unless pointed at explicitly. It
-- deliberately has no monitor fleet, no autostart and no scratchpads: just
-- enough to spawn windows and shove them around.
--
-- mainMod is ALT, not SUPER: the outer Hyprland claims SUPER binds first, so
-- SUPER chords would never reach the nested session.

require("nary")

hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })

hl.config({
    general = {
        gaps_in     = 5,
        gaps_out    = 10,
        border_size = 2,
        col = {
            active_border   = { colors = { "rgba(33ccffee)", "rgba(00ff99ee)" }, angle = 45 },
            inactive_border = "rgba(595959aa)",
        },
        layout = "lua:nary",
    },
    decoration = { rounding = 3 },
    animations = { enabled = false }, -- instant redraws make the slot ladder easier to read
    input      = { kb_layout = "us", follow_mouse = 1 },
})

local mainMod = "ALT"

-- Spawn windows to play with. Each gets a distinct title so you can tell which
-- one you are moving.
hl.bind(mainMod .. " + RETURN", hl.dsp.exec_cmd("wezterm"))
hl.bind(mainMod .. " + Q",      hl.dsp.window.close())

-- Focus
hl.bind(mainMod .. " + left",  hl.dsp.focus({ direction = "left" }))
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "right" }))
hl.bind(mainMod .. " + up",    hl.dsp.focus({ direction = "up" }))
hl.bind(mainMod .. " + down",  hl.dsp.focus({ direction = "down" }))

-- The thing under test. Same chord shape as the real config (ctrl + mod + arrow).
hl.bind("CTRL + " .. mainMod .. " + left",  hl.dsp.layout("move l"))
hl.bind("CTRL + " .. mainMod .. " + right", hl.dsp.layout("move r"))
hl.bind("CTRL + " .. mainMod .. " + up",    hl.dsp.layout("move u"))
hl.bind("CTRL + " .. mainMod .. " + down",  hl.dsp.layout("move d"))

hl.bind(mainMod .. " + comma", hl.dsp.layout("toggleorient"))

-- Multiple workspaces, to exercise the per-space tree partitioning.
for i = 1, 3 do
    hl.bind(mainMod .. " + " .. i,          hl.dsp.focus({ workspace = i }))
    hl.bind("CTRL + " .. mainMod .. " + " .. i, hl.dsp.window.move({ workspace = i }))
end
