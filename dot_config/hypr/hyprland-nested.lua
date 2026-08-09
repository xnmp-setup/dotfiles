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
-- has no monitor fleet and no autostart.
--
-- It does load the window-adopting modules — scratchpads, startup pairing,
-- terminal grouping and session restore — because those are the ones that
-- fight each other over a window that has just opened, and a nested session
-- that omitted them would pass green while the real one double-launched
-- Obsidian and tab-grouped every restored terminal.
--
-- mainMod is ALT, not SUPER: the outer Hyprland claims SUPER binds first, so
-- SUPER chords would never reach the nested session.

require("nary")
local wezterm_launcher = require("wezterm_launcher")
local window_actions   = require("window_actions").new(hl)
local scratchpad       = require("scratchpad").new(hl, window_actions)
local terminal_groups  = require("terminal_grouping")
local startup_pairing  = require("startup_pairing").new(hl, {
    browser_class = "google-chrome",
    notes_class = "obsidian",
    workspace = 1,
})

-- Its own snapshot, emphatically not ~/.local/state/hypr/session.lua: a nested
-- session saving over the real one would destroy the thing under test the
-- moment you opened a window in here.
session = require("session_restore").new(hl, {
    snapshot_path = (os.getenv("XDG_STATE_HOME")
        or ((os.getenv("HOME") or ".") .. "/.local/state"))
        .. "/hypr/session-nested.lua",
    workspaces_dir = (os.getenv("XDG_STATE_HOME")
        or ((os.getenv("HOME") or ".") .. "/.local/state"))
        .. "/hypr/workspaces-nested",
    wezterm_command = wezterm_launcher.launch,
    wezterm_restore_command = wezterm_launcher.restore_window,
})

terminal_groups.new(hl, {
    exclude_source = scratchpad.is_scratchpad,
    suppress = function(window)
        return session.is_restoring() or startup_pairing.is_waiting(window)
    end,
})

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
hl.bind(mainMod .. " + RETURN", hl.dsp.exec_cmd(wezterm_launcher.launch))
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

-- Session save/restore, the thing the extra modules above are here for.
-- Arrange some windows across the workspaces below, save, quit the nested
-- Hyprland, start it again and restore.
scratchpad.define("ghostty-drop", {
    class = "com.mitchellh.ghostty",
    cmd = "ghostty",
    w = 0.8, h = 0.7,
    anchor = "top",
})
hl.bind("F9",                    function() scratchpad.toggle("ghostty-drop") end)
hl.bind(mainMod .. " + S",       function() session.save() end)
hl.bind(mainMod .. " + CTRL + R", function() session.restore() end)
hl.bind(mainMod .. " + CTRL + D", function() session.restore({ dry_run = true }) end)
hl.bind(mainMod .. " + CTRL + W", function() session.close_workspace() end)

-- Multiple workspaces, to exercise the per-space tree partitioning.
for i = 1, 3 do
    hl.bind(mainMod .. " + " .. i,          hl.dsp.focus({ workspace = i }))
    hl.bind("CTRL + " .. mainMod .. " + " .. i, hl.dsp.window.move({ workspace = i }))
end
