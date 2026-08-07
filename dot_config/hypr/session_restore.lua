-- session_restore.lua — save the desktop on the way out, rebuild it on the way in.
--
-- The impure half of the feature; session_model.lua holds everything that can
-- be decided without a compositor. This module talks to hl and owns the one
-- piece of mutable state that matters: which ghostty tab was last seen on which
-- workspace.
--
-- Nothing here calls hyprctl
-- ---------------------------
-- Windows and workspaces come from hl.get_windows() / hl.get_workspaces().
-- Shelling out to `hyprctl` from Lua deadlocks: the request can only be served
-- by Hyprland's main event loop, which is exactly the thread blocked waiting
-- for the child to exit. It would hang for the subprocess timeout, return
-- nothing, and then quietly overwrite a good snapshot with an empty one.
--
-- The only external program is hypr-session-shells, which reads /proc and knows
-- nothing about Hyprland. It is run in the background and its output is read
-- from a file on the *next* save, so a ~50 ms /proc walk never stalls a frame.
-- The cost is that a working directory can be one save interval stale.
--
-- Why placement is observed rather than requested
-- -----------------------------------------------
-- Ghostty, Chrome and WezTerm are single-instance or mux-backed. The process
-- Hyprland spawns messages the real daemon and exits, so Hyprland's exec window
-- rules ({ workspace = "5 silent" }) never attach to the window that eventually
-- appears. Every restored window has to be caught on window.open and moved —
-- the same shape scratchpad.lua already uses to place a drop-down.
--
-- Why a Lua module rather than a script
-- -------------------------------------
-- An out-of-process restorer would race terminal_grouping.lua, startup_pairing.lua
-- and scratchpad.lua, all of which handle window.open in here, with no ordering
-- primitive between them. In-process it can expose is_restoring() as the
-- suppression signal those modules already know how to take.

local session_model = require("session_model")
local window_model = require("window_model")

local M = {}

local HOME = os.getenv("HOME") or ""
local STATE_DIR = (os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/hypr"
local CONFIG_DIR = (os.getenv("XDG_CONFIG_HOME") or (HOME .. "/.config")) .. "/hypr"

-- Goes to Hyprland's log. Overridable per instance (options.log) so the test
-- suite is not narrated by the failure paths it deliberately exercises.
local function default_log(format, ...)
    print("[session] " .. format:format(...))
end

local function shell_quote(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

-- Read a Lua data file. Loaded with an empty environment: a snapshot is data,
-- and a corrupted or tampered one should fail to parse rather than get to call
-- anything. Anything that is not a loadable table comes back as nil, which
-- every caller treats as "no session" rather than as a failure worth stopping
-- for.
local function load_lua(chunk, source, log)
    if not chunk then return nil end
    local loaded, message = load(chunk, source, "t", {})
    if not loaded then
        log("%s is not loadable: %s", source, message)
        return nil
    end
    local ok, value = pcall(loaded)
    if not ok or type(value) ~= "table" then
        log("%s did not evaluate to a table", source)
        return nil
    end
    return value
end

local function read_file(path)
    local handle = io.open(path, "r")
    if not handle then return nil end
    local text = handle:read("a")
    handle:close()
    return text
end

function M.new(hl, options)
    options = options or {}

    local snapshot_path = options.snapshot_path or (STATE_DIR .. "/session.lua")
    local shells_path = options.shells_path or (STATE_DIR .. "/shells.lua")
    local shells_command = options.shells_command or (HOME .. "/.local/bin/hypr-session-shells")
    local rename_command = options.rename_command or (HOME .. "/.local/bin/rename-hypr-workspace")
    local map_path = options.map_path or (CONFIG_DIR .. "/session-restore-map.conf")
    local wezterm_command = options.wezterm_command or "wezterm"
    local chrome_command = options.chrome_command or "google-chrome-stable"
    local save_interval = options.save_interval or 30000
    -- Long enough for WezTerm's tagged title formatter to run — a wezterm
    -- window is mapped before its window id is in the title, so matching at
    -- window.open would see every one of them untagged.
    local match_delay = options.match_delay or 200
    -- How long the restore stays open for windows to appear. Chrome with a
    -- large session is the slow case.
    local settle = options.settle or 20000
    -- Ghostty windows are launched one at a time (see launch_ghostty). This is
    -- how long to wait for one to appear before giving up and starting the
    -- next, so a single failure cannot stall the rest.
    local ghostty_step = options.ghostty_step or 1500
    local log = options.log or default_log
    local write_file = options.write_file
    local direction_towards = options.direction_towards or window_model.direction_towards

    -- pid -> workspace id. A ghostty tab that is not currently visible has no
    -- window to read a workspace off, so the last workspace it *was* seen on is
    -- the best answer available. Lives only for the session; a cold boot has an
    -- empty table and falls back to the focused ghostty window.
    local sightings = {}
    local restoring = false
    local placements, groups, placed = {}, {}, {}
    local ghostty_queue, ghostty_pending = {}, 0
    -- Saving is held off until the first restore has settled. Otherwise the
    -- 30 s timer can fire while Chrome is still coming up and write a snapshot
    -- with half the session missing — permanently, since that is what the next
    -- boot would read.
    local savable = false

    ----------------------------------------------------------------------
    -- Capture
    ----------------------------------------------------------------------

    local function refresh_shells()
        -- Fire and forget, into a temp file and renamed, so a save that lands
        -- mid-write reads the previous complete file rather than a partial one.
        hl.exec_cmd(("sh -c %s"):format(shell_quote(
            ("%s > %s.tmp && mv %s.tmp %s"):format(
                shells_command, shells_path, shells_path, shells_path))))
    end

    local function read_shells()
        return load_lua(read_file(shells_path), shells_path, log) or {}
    end

    local function class_commands()
        local commands = {}
        local text = read_file(map_path)
        if not text then return commands end
        for line in text:gmatch("[^\n]+") do
            if not line:match("^%s*#") then
                local class, command = line:match("^([^=]+)=(.*)$")
                if class and command and command ~= "" then
                    commands[class:match("^%s*(.-)%s*$")] = command:match("^%s*(.-)%s*$")
                end
            end
        end
        return commands
    end

    ----------------------------------------------------------------------
    -- Sightings
    ----------------------------------------------------------------------

    local function record_sightings(windows)
        for _, window in ipairs(windows or {}) do
            if window and window.class == session_model.GHOSTTY_CLASS then
                local pid = session_model.shell_pid_from_title(window.title)
                local workspace = window.workspace
                if pid and workspace and workspace.id then
                    sightings[pid] = workspace.id
                end
            end
        end
    end

    ----------------------------------------------------------------------
    -- Save
    ----------------------------------------------------------------------

    local function write_snapshot(text)
        if write_file then return write_file(snapshot_path, text) end
        -- Written beside the target and renamed, so a save interrupted by
        -- shutdown leaves the previous snapshot intact rather than a truncated
        -- file that would fail to load at the next boot.
        local temporary = snapshot_path .. ".tmp"
        local handle = io.open(temporary, "w")
        if not handle then
            log("cannot write %s", temporary)
            return false
        end
        handle:write(text)
        handle:close()
        return os.rename(temporary, snapshot_path)
    end

    local function do_save()
        local windows = hl.get_windows() or {}
        record_sightings(windows)
        local snapshot = session_model.build_snapshot({
            now = os.time(),
            windows = windows,
            workspaces = hl.get_workspaces() or {},
            shells = read_shells(),
            sightings = sightings,
        })
        -- A snapshot with no windows means the compositor handed back nothing,
        -- which is far more likely than a genuinely empty desktop. Overwriting
        -- with it would lose the session this exists to protect.
        if #snapshot.windows == 0 then
            log("refusing to overwrite the snapshot with an empty capture")
            return false
        end
        local written = write_snapshot(session_model.serialize(snapshot))
        if written then
            log("saved %d windows, %d shells", #snapshot.windows, #snapshot.shells)
        end
        return written and true or false
    end

    ----------------------------------------------------------------------
    -- Restore
    ----------------------------------------------------------------------

    local function workspace_selector(placement)
        -- Special workspaces are addressed by name; ordinary ones by id.
        if placement.workspace and placement.workspace < 0 then
            return placement.workspace_name
        end
        return placement.workspace and tostring(placement.workspace) or nil
    end

    local function apply(window, placement)
        local target = workspace_selector(placement)
        if target and target ~= "" then
            -- `silent` moves the window without following it, so a restore
            -- never yanks the view around.
            hl.dispatch(hl.dsp.window.move({
                workspace = target,
                silent = true,
                window = window,
            }))
        end

        if placement.floating then
            hl.dispatch(hl.dsp.window.float({ action = "on", window = window }))
            if placement.size then
                hl.dispatch(hl.dsp.window.resize({
                    x = placement.size[1], y = placement.size[2], window = window,
                }))
            end
            if placement.at then
                hl.dispatch(hl.dsp.window.move({
                    x = placement.at[1], y = placement.at[2], window = window,
                }))
            end
        end

        placed[placement.order] = window
    end

    -- Ghostty windows carry no identity when they open — the pid tag only
    -- appears once the restored shell draws its first prompt, long after
    -- placement. So they are matched by order, which means they have to *have*
    -- an order: fired in a loop, the single-instance daemon services the
    -- requests concurrently and maps them in whatever sequence it likes, and
    -- terminals land on arbitrary workspaces. One at a time, each launched when
    -- the previous window has been claimed, makes the order the saved order.
    local function launch_ghostty(index)
        local launch = ghostty_queue[index]
        if not launch then return end
        ghostty_pending = index
        hl.exec_cmd(launch.cmd)
        hl.timer(function()
            -- Only advance if the window never showed up; a claim will have
            -- moved `ghostty_pending` on already.
            if restoring and ghostty_pending == index then
                log("ghostty window %d never appeared; continuing", index)
                launch_ghostty(index + 1)
            end
        end, { timeout = ghostty_step, type = "oneshot" })
    end

    local function ghostty_claimed()
        local index = ghostty_pending
        if index == 0 then return end
        ghostty_pending = 0
        launch_ghostty(index + 1)
    end

    local function rebuild_groups()
        for _, group in ipairs(groups) do
            local anchor = placed[group.members[1]]
            if anchor and anchor.mapped then
                for index = 2, #group.members do
                    local member = placed[group.members[index]]
                    if member and member.mapped and not member.floating then
                        hl.dispatch(hl.dsp.window.move({
                            window = member,
                            into_or_create_group = direction_towards(member, anchor),
                        }))
                    end
                end
            end
        end
    end

    -- Fullscreen and pin are the two states with no window-targeted dispatcher:
    -- both act on whatever is focused. Applying them inline would fullscreen
    -- whatever the user happens to be looking at while the restore runs
    -- silently in the background. So they are done last, one window at a time,
    -- with focus moved to the target and handed back afterwards.
    local function apply_focus_states()
        local wanted = {}
        for _, placement in ipairs(placements) do
            local window = placed[placement.order]
            if window and window.mapped
                and ((placement.fullscreen or 0) ~= 0 or placement.pinned)
            then
                wanted[#wanted + 1] = { window = window, placement = placement }
            end
        end
        if #wanted == 0 then return end

        local previous = hl.get_active_window()
        for _, entry in ipairs(wanted) do
            hl.dispatch(hl.dsp.focus({ window = entry.window }))
            if (entry.placement.fullscreen or 0) ~= 0 then
                hl.dispatch(hl.dsp.window.fullscreen({ mode = "fullscreen" }))
            end
            -- Only a floating window qualifies to be pinned.
            if entry.placement.pinned and entry.placement.floating then
                hl.dispatch(hl.dsp.window.pin())
            end
        end
        if previous and previous.mapped then
            hl.dispatch(hl.dsp.focus({ window = previous }))
        end
    end

    local function finish()
        if not restoring then return end
        -- Every step is guarded: a throw in one must not leave `restoring`
        -- stuck true, which would permanently suppress terminal grouping and
        -- silently stop all further saves.
        local ok, err = pcall(function()
            rebuild_groups()
            apply_focus_states()
            for _, placement in ipairs(session_model.unclaimed(placements)) do
                -- Not an error: an app may be uninstalled, absent from
                -- session-restore-map.conf, or just slower than the settle
                -- window. Naming it is the difference between a bug report and
                -- a line to add to the map.
                log("never appeared: %s (workspace %s)",
                    placement.class, tostring(placement.workspace))
            end
        end)
        if not ok then log("restore cleanup failed: %s", tostring(err)) end
        restoring = false
        savable = true
        placements, groups, placed = {}, {}, {}
    end

    local function start(plan)
        restoring = true
        placements, groups, placed = plan.placements, plan.groups, {}
        ghostty_queue, ghostty_pending = {}, 0

        local immediate = {}
        for _, launch in ipairs(plan.launches) do
            if launch.provider == "ghostty" then
                ghostty_queue[#ghostty_queue + 1] = launch
            else
                immediate[#immediate + 1] = launch
            end
        end

        -- Armed before anything can throw, and wide enough to cover the
        -- serialized ghostty launches in the worst case. If a launch or a
        -- rename raises, the restore still ends and the session keeps saving.
        hl.timer(finish, {
            timeout = settle + #ghostty_queue * ghostty_step,
            type = "oneshot",
        })

        local ok, err = pcall(function()
            for _, workspace in ipairs(plan.workspace_names) do
                -- rename-hypr-workspace owns the length cap, the Lua %q quoting
                -- of the name and the lock against concurrent renames from the
                -- bar.
                hl.exec_cmd(("%s %d %s"):format(
                    rename_command, workspace.id, shell_quote(workspace.name)))
            end
            for _, launch in ipairs(immediate) do
                hl.exec_cmd(launch.cmd)
            end
            launch_ghostty(1)
        end)
        if not ok then log("restore could not be started cleanly: %s", tostring(err)) end
    end

    local function plan_from_snapshot()
        local snapshot = load_lua(read_file(snapshot_path), snapshot_path, log)
        if not snapshot then return nil end
        if not session_model.validate(snapshot) then
            log("snapshot is not usable; leaving the session alone")
            return nil
        end
        return session_model.plan_restore(snapshot, hl.get_windows(), {
            class_commands = class_commands(),
            wezterm_command = wezterm_command,
            chrome_command = chrome_command,
            shell_bin = options.shell_bin,
        })
    end

    local function do_restore(request)
        request = request or {}
        if restoring then
            log("a restore is already in flight")
            return false
        end
        local plan = plan_from_snapshot()
        if not plan then return false end

        if request.dry_run then
            for _, workspace in ipairs(plan.workspace_names) do
                log("would rename workspace %d to %q", workspace.id, workspace.name)
            end
            for _, launch in ipairs(plan.launches) do
                log("would launch (%s) %s", launch.provider, launch.cmd)
            end
            for _, placement in ipairs(plan.placements) do
                log("would place %s on workspace %s", placement.class,
                    tostring(workspace_selector(placement)))
            end
            return true
        end

        if #plan.launches == 0 and #plan.placements == 0 then
            log("nothing to restore")
            return false
        end

        start(plan)
        return true
    end

    ----------------------------------------------------------------------
    -- Events
    ----------------------------------------------------------------------

    hl.on("window.open", function(window)
        if not (restoring and window and window.class) then return end
        -- Deliberately deferred: WezTerm windows map before their title carries
        -- a window id, and Chromium windows map with a placeholder class that
        -- is corrected a frame later.
        hl.timer(function()
            if not (restoring and window.mapped) then return end
            local placement = session_model.match_window(placements, window)
            if not placement then return end
            apply(window, placement)
            if placement.provider == "ghostty" then ghostty_claimed() end
        end, { timeout = match_delay, type = "oneshot" })
    end)

    hl.on("window.active", function()
        record_sightings({ hl.get_active_window() })
    end)

    local function tick()
        -- A crash or a power cut should cost the last half-minute of window
        -- arrangement, not the whole session, so the snapshot is refreshed on a
        -- timer as well as at logout. Re-armed rather than repeating: hl.timer
        -- only offers oneshots.
        if savable and not restoring then do_save() end
        refresh_shells()
        hl.timer(tick, { timeout = save_interval, type = "oneshot" })
    end

    -- Armed from the start event rather than here. M.new() runs while the
    -- config is still being read, and every other module in this config only
    -- registers handlers at that point — arming a timer during config load is
    -- unproven ground, and a throw here would take the whole config down.
    hl.on("hyprland.start", function()
        refresh_shells()
        hl.timer(tick, { timeout = save_interval, type = "oneshot" })
    end)

    return {
        save = function()
            -- Explicit saves (the keybind, the systemd ExecStop) are not gated
            -- on `savable`: the caller has asked for one.
            savable = true
            do_save()
            -- hyprctl wraps its argument as `return hl.dispatch(<arg>)`, so a
            -- function reachable that way has to hand back a dispatcher. This
            -- is the cheapest harmless one; without it every
            -- `hyprctl dispatch "session.save()"` logs a dispatcher error after
            -- doing the work.
            return hl.dsp.exec_cmd("true")
        end,
        restore = function(request)
            do_restore(request)
            return hl.dsp.exec_cmd("true")
        end,

        -- Called from the startup block, in a pcall, and returns whether it
        -- took responsibility for populating the session. False means "no
        -- usable snapshot" and the caller launches its normal startup set — so
        -- a missing, truncated or unreadable snapshot degrades to today's
        -- behaviour instead of an empty desktop.
        boot = function()
            local claimed = do_restore({})
            -- Nothing was restored, so nothing is pending and the periodic save
            -- can start immediately. When a restore *is* running, finish() opens
            -- the gate instead.
            if not claimed then savable = true end
            return claimed
        end,

        -- Suppression signal for terminal_grouping and startup_pairing: while a
        -- restore is in flight the windows appearing are ours, already have a
        -- destination, and must not be adopted, grouped or paired by anything
        -- else.
        is_restoring = function() return restoring end,
    }
end

return M
