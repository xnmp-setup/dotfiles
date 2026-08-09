-- session_restore.lua — save the desktop on the way out, rebuild it on the way in.
--
-- The impure half of the feature; session_model.lua holds everything that can
-- be decided without a compositor. This module talks to hl and owns the one
-- piece of mutable state that matters: which ghostty tab was last seen on which
-- workspace.
--
-- Nothing here asks hyprctl a question
-- ------------------------------------
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
local workspace_catalog = require("workspace_catalog")
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
    local workspaces_dir = options.workspaces_dir or (STATE_DIR .. "/workspaces")
    local catalog_path = options.catalog_path or (workspaces_dir .. "/index.lua")
    local shells_command = options.shells_command or (HOME .. "/.local/bin/hypr-session-shells")
    local map_path = options.map_path or (CONFIG_DIR .. "/session-restore-map.conf")
    local wezterm_command = options.wezterm_command or "wezterm"
    local wezterm_restore_command = options.wezterm_restore_command
    local chrome_command = options.chrome_command or "google-chrome-stable"
    local save_interval = options.save_interval or 30000
    local workspace_retention = options.workspace_retention
        or workspace_catalog.RETENTION_SECONDS
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
    local now = options.now or os.time
    local read_state = options.read_file or read_file
    local write_file = options.write_file
    local remove_file = options.remove_file
    local direction_towards = options.direction_towards or window_model.direction_towards

    -- pid -> workspace id. A ghostty tab that is not currently visible has no
    -- window to read a workspace off, so the last workspace it *was* seen on is
    -- the best answer available. Lives only for the session; a cold boot has an
    -- empty table and falls back to the focused ghostty window.
    local sightings = {}
    local restoring = false
    local placements, groups, placed = {}, {}, {}
    -- Kept past the launches because the renames are re-run at the end, when
    -- the workspaces the placements created finally exist.
    local workspace_names = {}
    local ghostty_queue, ghostty_pending = {}, 0
    -- Saving is held off until the first restore has settled. Otherwise the
    -- 30 s timer can fire while Chrome is still coming up and write a snapshot
    -- with half the session missing — permanently, since that is what the next
    -- boot would read.
    local savable = false
    -- A manual workspace restore that fails to recreate every saved window must
    -- not let the next periodic capture replace the richer source snapshot with
    -- that incomplete result. An explicit close is authoritative and clears the
    -- floor; a successful restore clears it once the expected count is live.
    local protected_workspaces = {}

    -- The snapshot and the shell list record the working directory and the full
    -- argv of every foreground process, which is nobody else's business on a
    -- multi-user machine. Derived from the paths actually in use rather than
    -- from STATE_DIR, so a nested or test instance protects its own directory.
    -- Done through hl.exec_cmd because Lua has no chmod.
    local function secure_state_dirs()
        local seen = {}
        for _, path in ipairs({ snapshot_path, shells_path, catalog_path }) do
            local directory = path:match("^(.*)/[^/]+$")
            if directory and directory ~= "" and not seen[directory] then
                seen[directory] = true
                hl.exec_cmd(("sh -c %s"):format(shell_quote(
                    ("mkdir -p %s && chmod 700 %s"):format(
                        shell_quote(directory), shell_quote(directory)))))
            end
        end
    end

    ----------------------------------------------------------------------
    -- Capture
    ----------------------------------------------------------------------

    local function refresh_shells()
        -- Fire and forget, into a temp file and renamed, so a save that lands
        -- mid-write reads the previous complete file rather than a partial one.
        --
        -- umask here rather than in hypr-session-shells: the script only writes
        -- to stdout, and it is this shell that creates the file. The list holds
        -- the working directory and full argv of every foreground process, so it
        -- is not for the rest of the machine to read.
        hl.exec_cmd(("sh -c %s"):format(shell_quote(
            ("umask 077; %s > %s.tmp && mv %s.tmp %s"):format(
                shells_command, shells_path, shells_path, shells_path))))
    end

    local function read_shells()
        return load_lua(read_state(shells_path), shells_path, log) or {}
    end

    local function class_commands()
        local commands = {}
        local text = read_state(map_path)
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

    local function write_atomic(path, text)
        if write_file then return write_file(path, text) end
        -- Written beside the target and renamed, so a save interrupted by
        -- shutdown leaves the previous snapshot intact rather than a truncated
        -- file that would fail to load at the next boot.
        local temporary = path .. ".tmp"
        local handle = io.open(temporary, "w")
        if not handle then
            log("cannot write %s", temporary)
            return false
        end
        handle:write(text)
        handle:close()
        return os.rename(temporary, path)
    end

    -- The last snapshot written, read back off disk rather than remembered:
    -- after a reboot the file is the only thing that knows.
    local function previous_snapshot()
        return load_lua(read_state(snapshot_path), snapshot_path, log)
    end

    -- Carrying the previous shell list forward covers a /proc walk that has not
    -- landed yet. It must not become permanent: if hypr-session-shells breaks
    -- for good, an unbounded carry pins the terminals of the last working
    -- session into every snapshot from then on, and the empty-shells fallback
    -- in plan_restore — which reopens the ghostty windows that *are* in the
    -- capture — can never be reached. After this many consecutive carries the
    -- empty list is recorded and that fallback takes over: stale but true,
    -- rather than confidently wrong.
    local MAX_CARRIES = 3

    local function has_ghostty(windows)
        for _, window in ipairs(windows) do
            if window and window.class == session_model.GHOSTTY_CLASS then return true end
        end
        return false
    end

    local function capture_snapshot()
        -- A restore in flight is a half-built desktop. Recording it would throw
        -- away the very session being rebuilt, so an explicit save waits.
        if restoring then
            log("not saving while a restore is in flight")
            return nil
        end
        local windows = hl.get_windows() or {}
        record_sightings(windows)
        local snapshot = session_model.build_snapshot({
            now = now(),
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
            return nil
        end
        -- Same reasoning one level down: terminals on screen but no shell list
        -- means the background /proc walk has not landed yet, not that the
        -- terminals are empty. Recording that would drop every one of them.
        if #snapshot.shells == 0 and has_ghostty(windows) then
            local previous = previous_snapshot() or {}
            local carried = type(previous.shells) == "table" and #previous.shells > 0
                and previous.shells or nil
            -- Consecutive, because a walk that succeeds writes no counter and
            -- the next empty one starts again from zero.
            local carries = (tonumber(previous.shells_carried) or 0) + 1
            if carried and carries <= MAX_CARRIES then
                snapshot.shells = carried
                snapshot.shells_carried = carries
                log("shell list is empty; carrying %d shells forward (%d of %d)",
                    #carried, carries, MAX_CARRIES)
            elseif carried then
                log("the shell list has been empty for %d saves; recording none", carries)
            end
        end
        return snapshot
    end

    local function read_catalog()
        return workspace_catalog.normalize(
            load_lua(read_state(catalog_path), catalog_path, log))
    end

    local function workspace_snapshot_path(workspace_id)
        return ("%s/%d.lua"):format(workspaces_dir, workspace_id)
    end

    local function app_count(windows)
        local classes, count = {}, 0
        for _, window in ipairs(windows or {}) do
            if window.class and not classes[window.class] then
                classes[window.class], count = true, count + 1
            end
        end
        return count
    end

    local function remove_snapshot(workspace_id)
        local path = workspace_snapshot_path(workspace_id)
        if remove_file then return remove_file(path) end
        if read_state(path) == nil then return true end
        return os.remove(path)
    end

    -- Write the newest independently restorable snapshot for every populated
    -- ordinary workspace. Missing workspaces are retained in the catalog until
    -- they age out; that is what makes a workspace remain restorable after all
    -- of its windows have closed.
    local function workspace_is_complete(windows, protection)
        if not protection or #windows < protection.window_count then return false end
        local identities = {}
        for _, window in ipairs(windows) do
            local identity = window.class == session_model.WEZTERM_CLASS
                and session_model.wezterm_id_from_title(window.title)
            if identity then identities[identity] = true end
        end
        for identity in pairs(protection.wezterm_ids or {}) do
            if not identities[identity] then return false end
        end
        return true
    end

    local function save_workspaces(snapshot, only_workspace_id, authoritative)
        local updated, handled_any = read_catalog(), false
        for _, workspace in ipairs(snapshot.workspaces or {}) do
            if not only_workspace_id or workspace.id == only_workspace_id then
                local isolated = session_model.for_workspace(snapshot, workspace.id)
                if isolated then
                    local protection = protected_workspaces[workspace.id]
                    if protection and not workspace_is_complete(
                        isolated.windows, protection) and not authoritative
                    then
                        handled_any = true
                        log("keeping workspace %d snapshot; restored state is incomplete",
                            workspace.id)
                    else
                        local path = workspace_snapshot_path(workspace.id)
                        if write_atomic(path, session_model.serialize(isolated)) then
                            local next_catalog = workspace_catalog.upsert(updated, {
                                workspace_id = workspace.id,
                                name = workspace.name,
                                saved_at = snapshot.saved_at,
                                window_count = #isolated.windows,
                                app_count = app_count(isolated.windows),
                                shell_count = #isolated.shells,
                            })
                            updated, handled_any = next_catalog, true
                            if authoritative or (protection and workspace_is_complete(
                                isolated.windows, protection))
                            then
                                protected_workspaces[workspace.id] = nil
                            end
                        else
                            log("cannot save workspace %d", workspace.id)
                        end
                    end
                end
            end
        end

        local pruned, expired = workspace_catalog.prune(
            updated, snapshot.saved_at, workspace_retention)
        if not write_atomic(catalog_path, session_model.serialize(pruned)) then
            log("cannot update the workspace catalog")
            return false
        end
        for _, entry in ipairs(expired) do
            if not remove_snapshot(entry.workspace_id) then
                log("expired workspace %d was hidden but its snapshot remains",
                    entry.workspace_id)
            end
        end
        return handled_any
    end

    local function do_save()
        local snapshot = capture_snapshot()
        if not snapshot then return false end
        local rolling_written = write_atomic(snapshot_path, session_model.serialize(snapshot))
        local workspaces_written = save_workspaces(snapshot)
        if rolling_written then
            log("saved %d windows, %d shells", #snapshot.windows, #snapshot.shells)
        end
        return rolling_written and workspaces_written
    end

    local function do_forget_workspace(requested_id)
        local updated, entry, message = workspace_catalog.remove(
            read_catalog(), requested_id)
        if not updated then
            log("cannot forget workspace: %s", message)
            return false
        end
        if not entry then
            log("workspace %s is not restorable", tostring(requested_id))
            return false
        end
        -- Hide the entry first. If removing the snapshot then fails, the stale
        -- private file is harmless and no picker row points at missing data.
        if not write_atomic(catalog_path, session_model.serialize(updated)) then
            log("cannot update the workspace catalog")
            return false
        end
        if not remove_snapshot(entry.workspace_id) then
            log("forgot workspace %d, but could not remove its snapshot",
                entry.workspace_id)
            return false
        end
        log("forgot workspace %d", entry.workspace_id)
        return true
    end

    local function active_ordinary_workspace()
        local monitor = hl.get_active_monitor and hl.get_active_monitor()
        local workspace = monitor and monitor.active_workspace
        if not (workspace and workspace.id) and hl.get_active_workspace then
            workspace = hl.get_active_workspace()
        end
        if not workspace_catalog.workspace_id(workspace and workspace.id) then
            return nil
        end
        return workspace
    end

    local function monitor_id(monitor)
        if type(monitor) == "number" or type(monitor) == "string" then
            return tostring(monitor)
        end
        if not monitor then return nil end
        local ok, value = pcall(function() return monitor.id or monitor.name end)
        return ok and value ~= nil and tostring(value) or nil
    end

    local function next_ordinary_workspace(workspace)
        local active_monitor = hl.get_active_monitor and hl.get_active_monitor()
        local wanted_monitor = monitor_id(active_monitor) or monitor_id(workspace.monitor)
        local candidates = {}
        for _, candidate in ipairs(hl.get_workspaces() or {}) do
            if workspace_catalog.workspace_id(candidate.id)
                and candidate.id ~= workspace.id
                and (not wanted_monitor or monitor_id(candidate.monitor) == wanted_monitor)
            then
                candidates[#candidates + 1] = candidate.id
            end
        end
        table.sort(candidates)
        for _, workspace_id in ipairs(candidates) do
            if workspace_id > workspace.id then return workspace_id end
        end
        return candidates[1]
    end

    local function do_close_workspace()
        local workspace = active_ordinary_workspace()
        if not workspace then
            log("cannot close a special or unknown workspace")
            return false
        end

        local snapshot = capture_snapshot()
        if not snapshot or not save_workspaces(snapshot, workspace.id, true) then
            log("workspace %d was not closed because its snapshot could not be saved",
                workspace.id)
            return false
        end

        local next_workspace = next_ordinary_workspace(workspace)
        local closed = 0
        for _, window in ipairs(hl.get_windows() or {}) do
            local owner = window.workspace
            if window.mapped and not window.pinned and owner
                and owner.id == workspace.id
            then
                hl.dispatch(hl.dsp.window.close({ window = window }))
                closed = closed + 1
            end
        end
        if closed > 0 and next_workspace then
            -- Resolve the target before teardown and focus it by id. A relative
            -- m+1 dispatched while the source workspace is asynchronously
            -- disappearing can resolve back to that same workspace.
            hl.dispatch(hl.dsp.focus({ workspace = next_workspace }))
        end
        log("closed workspace %d after saving %d windows", workspace.id, closed)
        return closed > 0
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

    local function rename_workspace(workspace)
        local ok, err = pcall(function()
            hl.dispatch(hl.dsp.workspace.rename({
                workspace = workspace.id,
                name = workspace.name,
            }))
        end)
        if not ok then
            log("could not rename workspace %d to %q: %s",
                workspace.id, workspace.name, tostring(err))
        end
    end

    local function rename_workspaces(existing_only)
        local existing = {}
        if existing_only then
            for _, workspace in ipairs(hl.get_workspaces() or {}) do
                existing[workspace.id] = true
            end
        end
        for _, workspace in ipairs(workspace_names) do
            if not existing_only or existing[workspace.id] then
                rename_workspace(workspace)
            end
        end
    end

    local function rename_saved_workspace(workspace_id)
        for _, workspace in ipairs(workspace_names) do
            if workspace.id == workspace_id then
                rename_workspace(workspace)
                return true
            end
        end
        return false
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
            rename_workspaces(true)
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
        local windows_by_workspace = {}
        for _, window in ipairs(hl.get_windows() or {}) do
            local workspace = window.workspace
            if window.mapped and not window.pinned and workspace and workspace.id then
                local windows = windows_by_workspace[workspace.id] or {}
                windows[#windows + 1] = window
                windows_by_workspace[workspace.id] = windows
            end
        end
        for workspace_id, protection in pairs(protected_workspaces) do
            if workspace_is_complete(
                windows_by_workspace[workspace_id] or {}, protection)
            then
                protected_workspaces[workspace_id] = nil
            end
        end
        placements, groups, placed = {}, {}, {}
        workspace_names = {}
    end

    local function start(plan)
        restoring = true
        placements, groups, placed = plan.placements, plan.groups, {}
        workspace_names = plan.workspace_names or {}
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
            rename_workspaces(true)
            for _, launch in ipairs(immediate) do
                hl.exec_cmd(launch.cmd)
            end
            launch_ghostty(1)
        end)
        if not ok then log("restore could not be started cleanly: %s", tostring(err)) end
    end

    local function plan_from_snapshot(source_path)
        source_path = source_path or snapshot_path
        local snapshot = load_lua(read_state(source_path), source_path, log)
        if not snapshot then return nil end
        if not session_model.validate(snapshot) then
            log("snapshot is not usable; leaving the session alone")
            return nil
        end
        local plan = session_model.plan_restore(snapshot, hl.get_windows(), {
            class_commands = class_commands(),
            wezterm_command = wezterm_command,
            wezterm_restore_command = wezterm_restore_command,
            chrome_command = chrome_command,
            shell_bin = options.shell_bin,
        })
        plan.wezterm_ids = {}
        for _, window in ipairs(snapshot.windows or {}) do
            local identity = window.class == session_model.WEZTERM_CLASS
                and session_model.wezterm_id_from_title(window.title)
            if identity then plan.wezterm_ids[identity] = true end
        end
        return plan
    end

    local function do_restore(request)
        request = request or {}
        if restoring then
            log("a restore is already in flight")
            return false
        end
        local plan = plan_from_snapshot(request.snapshot_path)
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

        -- At boot, claiming the session means the caller skips its startup set,
        -- so a plan that launches nothing would leave an empty desktop: a
        -- snapshot of classes that are all absent from session-restore-map.conf
        -- produces placements and no launches. Placements alone are worth
        -- keeping only on a manual re-restore, where the windows they are
        -- waiting for may already be opening.
        if request.boot then
            if #plan.launches == 0 then
                log("nothing to launch; leaving the startup set to the caller")
                return false
            end
        elseif #plan.launches == 0 and #plan.placements == 0 then
            log("nothing to restore")
            return false
        end

        if request.protect_workspace_id and request.protect_window_count then
            protected_workspaces[request.protect_workspace_id] = {
                window_count = request.protect_window_count,
                wezterm_ids = plan.wezterm_ids,
            }
        end
        start(plan)
        return true
    end

    ----------------------------------------------------------------------
    -- Events
    ----------------------------------------------------------------------

    -- Event bursts are coalesced into one capture after window properties and
    -- layout have settled. This closes the only gap in the 30-second timer: a
    -- workspace created and removed inside one interval is still observed.
    local auto_save_generation = 0
    local function schedule_save()
        if restoring or not savable then return end
        auto_save_generation = auto_save_generation + 1
        local generation = auto_save_generation
        hl.timer(function()
            if generation ~= auto_save_generation or restoring or not savable then return end
            local ok, err = pcall(do_save)
            if not ok then log("event save failed: %s", tostring(err)) end
        end, { timeout = 1000, type = "oneshot" })
    end

    hl.on("window.open", function(window)
        schedule_save()
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

    hl.on("window.move_to_workspace", schedule_save)
    hl.on("workspace.active", schedule_save)
    hl.on("workspace.created", function(workspace)
        schedule_save()
        if not restoring then return end
        local workspace_id = type(workspace) == "table" and workspace.id
            or tonumber(workspace)
        if workspace_id then rename_saved_workspace(workspace_id) end
    end)

    local tick, tick_armed
    local function arm_tick()
        if tick_armed then return end
        tick_armed = true
        hl.timer(function()
            tick_armed = false
            tick()
        end, { timeout = save_interval, type = "oneshot" })
    end

    tick = function()
        -- A crash or a power cut should cost the last half-minute of window
        -- arrangement, not the whole session, so the snapshot is refreshed on a
        -- timer as well as at logout. Re-armed rather than repeating: hl.timer
        -- only offers oneshots.
        --
        -- Re-armed *first*, and the body guarded: this is the only thing
        -- keeping the snapshot fresh, and a single throw out of do_save would
        -- otherwise end the periodic save for the rest of the session.
        arm_tick()
        local ok, err = pcall(function()
            -- The /proc walk is asked for before the save so that a shell list
            -- is on disk by the time the next tick reads it — but never during
            -- a restore, when only some of the terminals have been launched.
            -- That list would be complete-looking and short, which no guard
            -- downstream can tell from a real one.
            if not restoring then refresh_shells() end
            if savable then do_save() end
        end)
        if not ok then log("periodic save failed: %s", tostring(err)) end
    end

    -- Armed from the start event rather than here. M.new() runs while the
    -- config is still being read, and every other module in this config only
    -- registers handlers at that point — arming a timer during config load is
    -- unproven ground, and a throw here would take the whole config down.
    -- No refresh_shells() here: at boot it would run before the restore has
    -- opened a single terminal and overwrite the saved shell list with an empty
    -- one. The first tick asks for it, once there is something to see.
    hl.on("hyprland.start", function()
        secure_state_dirs()
        arm_tick()
    end)

    -- A reload does not emit hyprland.start. Open the save gate and arm both
    -- an immediate coalesced capture and the periodic loop for the new config
    -- context, so automatic snapshots do not silently stop until next login.
    hl.on("config.reloaded", function()
        savable = true
        secure_state_dirs()
        schedule_save()
        arm_tick()
    end)

    return {
        save = function()
            -- Explicit saves (the keybind, the exit path) are not gated on
            -- `savable`: the caller has asked for one. They are still refused
            -- mid-restore, inside do_save, because the desktop is half-built.
            savable = true
            local ok, err = pcall(do_save)
            if not ok then log("save failed: %s", tostring(err)) end
            -- hyprctl wraps its argument as `return hl.dispatch(<arg>)`, so a
            -- function reachable that way has to hand back a dispatcher. This
            -- is the cheapest harmless one; without it every
            -- `hyprctl dispatch "session.save()"` logs a dispatcher error after
            -- doing the work.
            return hl.dsp.exec_cmd("true")
        end,

        -- Leaving the session, the only way the last save is guaranteed to
        -- happen: the compositor is still up here, so the capture is real.
        -- Nothing outside Hyprland can do this — an ExecStop, a logout hook or
        -- anything else systemd orders runs after the compositor is gone, with
        -- no windows left to record.
        exit = function()
            local ok, err = pcall(do_save)
            if not ok then log("save before exit failed: %s", tostring(err)) end
            -- Dispatched here rather than returned: a keybind callback is
            -- invoked with nresults=0, so whatever it hands back is discarded
            -- and the desktop would save and then carry on running. The return
            -- value exists only for `hyprctl dispatch "session.exit()"`, which
            -- does read one.
            hl.dispatch(hl.dsp.exit())
            return hl.dsp.exec_cmd("true")
        end,
        restore = function(request)
            do_restore(request)
            return hl.dsp.exec_cmd("true")
        end,
        close_workspace = function()
            savable = true
            local ok, result = pcall(do_close_workspace)
            if not ok then
                log("workspace close failed: %s", tostring(result))
            elseif not result then
                log("workspace was not closed")
            end
            return hl.dsp.exec_cmd("true")
        end,
        restore_workspace = function(requested_id)
            local entry = workspace_catalog.find(read_catalog(), requested_id)
            if not entry then
                log("workspace %s is not restorable", tostring(requested_id))
            else
                local ok, result = pcall(do_restore, {
                    snapshot_path = workspace_snapshot_path(entry.workspace_id),
                    protect_workspace_id = entry.workspace_id,
                    protect_window_count = entry.window_count,
                })
                if not ok then
                    log("workspace restore failed: %s", tostring(result))
                elseif not result then
                    log("workspace %d could not be restored", entry.workspace_id)
                end
            end
            return hl.dsp.exec_cmd("true")
        end,
        forget_workspace = function(requested_id)
            local ok, result = pcall(do_forget_workspace, requested_id)
            if not ok then
                log("forget workspace failed: %s", tostring(result))
            elseif not result then
                log("workspace was not forgotten")
            end
            return hl.dsp.exec_cmd("true")
        end,

        -- Called from the startup block, in a pcall, and returns whether it
        -- took responsibility for populating the session. False means "no
        -- usable snapshot" and the caller launches its normal startup set — so
        -- a missing, truncated or unreadable snapshot degrades to today's
        -- behaviour instead of an empty desktop.
        boot = function()
            local claimed = do_restore({ boot = true })
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
