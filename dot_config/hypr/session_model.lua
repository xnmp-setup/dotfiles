-- session_model.lua — the pure half of Hyprland session save/restore.
--
-- Everything here is a function of its arguments: no hl, no hyprctl, no io.
-- session_restore.lua supplies the live data and executes what this module
-- plans. That split is what makes the interesting parts (which window claims
-- which saved slot, which workspace an invisible terminal tab belonged to)
-- testable without a compositor — see session_test.lua.
--
-- What is deliberately NOT modelled:
--   * Ghostty tab grouping. Ghostty's CLI can only open windows, never a tab
--     in an existing one, and its surfaces are not addressable from outside
--     the process. Every saved shell restores as its own window.
--   * Terminal scrollback, and WezTerm pane layout — sessionstore.lua owns the
--     latter and restores it itself on gui-startup.

local M = {}

--------------------------------------------------------------------------
-- Invisible title tags
--------------------------------------------------------------------------
-- Unicode tag characters are default-ignorable: compositors keep them in the
-- title, renderers do not draw them. Same encoding as
-- dot_config/wezterm/wezterm_window_identity.lua and the statusbar's
-- lib/ghostty_status.py, so a title can carry several payloads at once
-- ("codex" from the agent animator, "pid:1234" from us).

local TAG_OFFSET = 0xE0000
local TAG_CANCEL = 0xE007F

-- Byte-wise, matching the zsh encoder in ghostty-title-tags.zsh for the ASCII
-- payloads either side actually emits ("pid:1234", "wid:0"). A non-ASCII
-- payload would encode differently on the two sides; nothing sends one, and
-- the tag alphabet (U+E0020..U+E007E) cannot represent one anyway.
function M.encode_tag(payload)
    local encoded = tostring(payload):gsub(".", function(character)
        return utf8.char(TAG_OFFSET + string.byte(character))
    end)
    return encoded .. utf8.char(TAG_CANCEL)
end

-- Window titles arrive from the compositor and can be cut mid-codepoint, which
-- makes utf8.codes raise. Decode as far as the text is well-formed and stop —
-- both callers want a best effort, not an error.
local function each_code(text, visit)
    pcall(function()
        for _, code in utf8.codes(tostring(text or "")) do visit(code) end
    end)
end

-- Every payload in the title, in order. Runs that never terminate are ignored,
-- so a title truncated mid-tag decodes to the payloads that did complete.
function M.tag_payloads(title)
    local payloads, current = {}, {}
    each_code(title, function(code)
        if code == TAG_CANCEL then
            if #current > 0 then payloads[#payloads + 1] = table.concat(current) end
            current = {}
        elseif code > TAG_OFFSET and code < TAG_CANCEL then
            current[#current + 1] = string.char(code - TAG_OFFSET)
        end
    end)
    return payloads
end

-- The title as a human reads it. Used for matching restored windows whose
-- identity tag has not been written yet.
function M.strip_tags(title)
    local kept = {}
    each_code(title, function(code)
        if code < TAG_OFFSET or code > TAG_CANCEL then
            kept[#kept + 1] = utf8.char(code)
        end
    end)
    return table.concat(kept)
end

local function tagged_value(title, prefix)
    for _, payload in ipairs(M.tag_payloads(title)) do
        local value = payload:match("^" .. prefix .. ":(.+)$")
        if value then return value end
    end
    return nil
end

-- The shell PID stamped by ghostty-title-tags.zsh, or nil when the shell has
-- not drawn a prompt yet.
function M.shell_pid_from_title(title)
    return tonumber(tagged_value(title, "pid"))
end

-- WezTerm's mux window id, stamped by wezterm_window_identity.lua.
function M.wezterm_id_from_title(title)
    return tonumber(tagged_value(title, "wid"))
end

--------------------------------------------------------------------------
-- Providers
--------------------------------------------------------------------------
-- Which relaunch strategy owns a class. "chrome" and "wezterm" restore their
-- own contents, so we launch them once and only place the windows they
-- produce; "ghostty" is driven off the saved shell list; "generic" is relaunched
-- from session-restore-map.conf.

M.GHOSTTY_CLASS = "com.mitchellh.ghostty"
M.WEZTERM_CLASS = "org.wezfurlong.wezterm"
M.CHROME_CLASS = "google-chrome"

local PROVIDERS = {
    [M.GHOSTTY_CLASS] = "ghostty",
    [M.WEZTERM_CLASS] = "wezterm",
    [M.CHROME_CLASS] = "chrome",
}

function M.provider_for(class)
    return PROVIDERS[class] or "generic"
end

--------------------------------------------------------------------------
-- Snapshot
--------------------------------------------------------------------------

M.VERSION = 2

-- Monitors arrive as HL.Monitor objects, which the serializer cannot hold: only
-- the name goes into the snapshot. Read through a pcall because an opaque
-- object may not even be indexable, and a monitor is recorded for diagnosis
-- only — placement follows the workspace, which the compositor puts back on the
-- right output through the workspace rules.
local function monitor_name(monitor)
    if type(monitor) == "string" then return monitor end
    -- Some callers hand back an output id rather than an object; it identifies
    -- a monitor just as well, and dropping it would lose the field silently.
    if type(monitor) == "number" then return tostring(monitor) end
    if monitor == nil then return nil end
    local ok, name = pcall(function() return monitor.name end)
    if ok and type(name) == "string" then return name end
    return nil
end

local function workspace_of(window)
    local workspace = window.workspace or {}
    return workspace.id, workspace.name
end

-- Special workspaces have negative ids and a "special:" name. They are kept in
-- the snapshot (the old shell script dropped them) so the F8/F9 drop-downs come
-- back parked rather than as stray ordinary windows.
function M.is_special(workspace_id)
    return type(workspace_id) == "number" and workspace_id < 0
end

-- Attribute each ghostty shell to a workspace. Precedence matters enough to be
-- recorded in the snapshot as `workspace_source`, because it is the one field
-- that explains a window landing somewhere surprising:
--
--   title    — a live ghostty window's title carries this shell's pid tag, so
--              the shell is the visible tab of that window. Exact.
--   sighting — the tracker saw this pid on a workspace earlier in the session,
--              i.e. it was the visible tab at some point and has since been
--              backgrounded. Stale but almost always right.
--   fallback — never seen. Follows the most recently focused ghostty window.
function M.attribute_shells(shells, ghostty_windows, sightings, workspaces)
    sightings = sightings or {}

    -- Names are carried alongside ids because a special workspace can only be
    -- addressed by name; a shell in the F9 drop-down would otherwise be
    -- dispatched to the literal workspace "-99". Sourced from the full
    -- workspace list, since a shell attributed by sighting can name a
    -- workspace that has no ghostty window on it right now.
    local names = {}
    for _, workspace in ipairs(workspaces or {}) do
        if workspace.id then names[workspace.id] = workspace.name end
    end

    local by_pid = {}
    for _, window in ipairs(ghostty_windows or {}) do
        local pid = M.shell_pid_from_title(window.title)
        local workspace_id, workspace_name = workspace_of(window)
        if workspace_id and not names[workspace_id] then
            names[workspace_id] = workspace_name
        end
        if pid and workspace_id then by_pid[pid] = workspace_id end
    end

    -- focus_history_id counts up from 0 at the most recently focused window.
    local fallback
    local best_history = math.huge
    for _, window in ipairs(ghostty_windows or {}) do
        local history = tonumber(window.focus_history_id) or math.huge
        local workspace_id = select(1, workspace_of(window))
        if workspace_id and history < best_history then
            fallback, best_history = workspace_id, history
        end
    end

    local attributed = {}
    for index, shell in ipairs(shells or {}) do
        local workspace_id, source = by_pid[shell.pid], "title"
        if not workspace_id then
            workspace_id, source = sightings[shell.pid], "sighting"
        end
        if not workspace_id then
            workspace_id, source = fallback, "fallback"
        end
        attributed[index] = {
            pid = shell.pid,
            cwd = shell.cwd,
            command = shell.command,
            workspace = workspace_id,
            workspace_name = workspace_id and names[workspace_id] or nil,
            workspace_source = workspace_id and source or nil,
        }
    end
    return attributed
end

-- input = { windows, workspaces, shells, sightings, now }
function M.build_snapshot(input)
    local windows, ghostty_windows = {}, {}

    for _, window in ipairs(input.windows or {}) do
        local workspace_id, workspace_name = workspace_of(window)
        if window.class and window.class ~= "" and workspace_id then
            local group = window.group
            windows[#windows + 1] = {
                class = window.class,
                title = window.title,
                workspace = workspace_id,
                workspace_name = workspace_name,
                monitor = monitor_name(window.monitor),
                floating = window.floating or false,
                at = window.at and { window.at.x or window.at[1], window.at.y or window.at[2] },
                size = window.size and { window.size.x or window.size[1], window.size.y or window.size[2] },
                fullscreen = tonumber(window.fullscreen) or 0,
                pinned = window.pinned or false,
                focus_history_id = tonumber(window.focus_history_id),
                -- HL.Group carries no id of its own. `current` is the active
                -- member and is the same object for every member, so its
                -- address buckets a group consistently within one snapshot —
                -- which is all group identity has to survive.
                group = group and (group.size or 0) > 1 and group.current
                    and { id = group.current.address, index = group.current_index }
                    or nil,
                provider = M.provider_for(window.class),
            }
            if window.class == M.GHOSTTY_CLASS then
                ghostty_windows[#ghostty_windows + 1] = window
            end
        end
    end

    table.sort(windows, function(a, b)
        if a.workspace ~= b.workspace then return a.workspace < b.workspace end
        return (a.focus_history_id or math.huge) < (b.focus_history_id or math.huge)
    end)

    local workspaces = {}
    for _, workspace in ipairs(input.workspaces or {}) do
        if workspace.id and not M.is_special(workspace.id) then
            workspaces[#workspaces + 1] = {
                id = workspace.id,
                name = workspace.name,
                monitor = monitor_name(workspace.monitor),
            }
        end
    end
    table.sort(workspaces, function(a, b) return a.id < b.id end)

    return {
        version = M.VERSION,
        saved_at = input.now,
        workspaces = workspaces,
        windows = windows,
        shells = M.attribute_shells(input.shells, ghostty_windows, input.sightings,
            input.workspaces),
    }
end

--------------------------------------------------------------------------
-- Serialization
--------------------------------------------------------------------------
-- The snapshot is written as a Lua table literal rather than JSON: Lua has no
-- stdlib JSON parser, `loadfile` + `pcall` gives us parsing and corruption
-- detection in one step, and the repo already generates Lua data this way
-- (theme.lua, from scripts/set-theme.sh). Keys are sorted so two snapshots of
-- the same state produce byte-identical files.

-- A table is treated as a list only when its keys are exactly 1..n. Anything
-- else — a hole, a mixed table — is written as a keyed table, because the
-- alternative is silently dropping the keys that do not fit.
local function is_array(value)
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then return false end
        count = count + 1
    end
    return count == #value
end

local function serialize_value(value, indent)
    local kind = type(value)
    if kind == "string" then return string.format("%q", value) end
    if kind == "number" or kind == "boolean" then return tostring(value) end
    if kind ~= "table" then
        error("session snapshots cannot hold a " .. kind)
    end

    local pad, inner = string.rep(" ", indent), string.rep(" ", indent + 2)
    local parts = {}
    if is_array(value) then
        for _, item in ipairs(value) do
            parts[#parts + 1] = inner .. serialize_value(item, indent + 2)
        end
    else
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, key in ipairs(keys) do
            parts[#parts + 1] = ("%s[%s] = %s")
                :format(inner, string.format("%q", tostring(key)),
                    serialize_value(value[key], indent + 2))
        end
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
end

function M.serialize(snapshot)
    return "return " .. serialize_value(snapshot, 0) .. "\n"
end

-- Anything that is not a v2 snapshot is treated as absent rather than
-- half-restored: session_restore falls back to the ordinary startup launches.
function M.validate(snapshot)
    if type(snapshot) ~= "table" then return nil, "snapshot is not a table" end
    if snapshot.version ~= M.VERSION then
        return nil, "unsupported snapshot version " .. tostring(snapshot.version)
    end
    if type(snapshot.windows) ~= "table" then return nil, "snapshot has no windows" end
    if #snapshot.windows == 0 and #(snapshot.shells or {}) == 0 then
        return nil, "snapshot is empty"
    end
    return snapshot
end

--------------------------------------------------------------------------
-- Restore planning
--------------------------------------------------------------------------

-- A workspace whose name is just its number was never renamed; re-issuing that
-- is a no-op that would only race the bar.
local function is_named(workspace)
    return workspace.name and workspace.name ~= "" and workspace.name ~= tostring(workspace.id)
end

local function quote_shell(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

-- Ghostty's IPC forwards only --working-directory, --title and -e/--command to
-- the running instance, and the spawned surface inherits the *daemon's*
-- environment, not ours. So the pre-typed command has to be exported inside the
-- -e command itself. -e also swallows the rest of the line, hence its position.
--
-- The shell is named, not pathed: /usr/bin/zsh does not exist on NixOS, where
-- it lives under /run/current-system/sw/bin. Ghostty resolves a bare name on
-- PATH. The inner shell is re-exec'd with -l because -e replaces ghostty's
-- default login shell, and on NixOS the system PATH and environment come from
-- /etc/zprofile, which a non-login shell never reads.
function M.ghostty_command(shell, options)
    options = options or {}
    local shell_bin = options.shell_bin or "zsh"
    local parts = { "ghostty", "+new-window" }
    if shell.cwd and shell.cwd ~= "" then
        parts[#parts + 1] = "--working-directory=" .. quote_shell(shell.cwd)
    end
    if shell.command and shell.command ~= "" then
        parts[#parts + 1] = ("-e %s -c %s"):format(
            shell_bin,
            quote_shell(("export HYPR_RESTORE_CMD=%s; exec %s -l")
                :format(quote_shell(shell.command), shell_bin)))
    else
        parts[#parts + 1] = ("-e %s -l"):format(shell_bin)
    end
    return table.concat(parts, " ")
end

-- A window already on screen when the restore starts is left alone and its
-- saved slot is dropped entirely — not just its launch. Re-launching would
-- duplicate it, and it can never be claimed by match_window() because its
-- window.open event fired long ago. This only comes up on a manual re-restore
-- (SUPER+CTRL+R); at boot nothing is running yet.
local function live_pool(live_windows)
    local pool = {}
    for _, window in ipairs(live_windows or {}) do
        if window.class then
            pool[window.class] = pool[window.class] or {}
            local bucket = pool[window.class]
            bucket[#bucket + 1] = {
                title = M.strip_tags(window.title),
                shell_pid = M.shell_pid_from_title(window.title),
            }
        end
    end
    return pool
end

-- Consume one live window of `class`, preferring an exact title match so that
-- three open Chrome windows are matched to the right three saved slots.
local function take_live(pool, class, title)
    local bucket = pool[class]
    if not bucket or #bucket == 0 then return false end
    for index, candidate in ipairs(bucket) do
        if title and candidate.title == title then
            table.remove(bucket, index)
            return true
        end
    end
    table.remove(bucket, 1)
    return true
end

-- Returns { workspace_names, launches, placements, groups }.
--
-- `placements` is the queue that match_window() claims from as windows appear;
-- `launches` is what produces them. The two are deliberately not 1:1 — one
-- Chrome launch yields every Chrome window, and one WezTerm launch yields
-- every mux window.
function M.plan_restore(snapshot, live_windows, options)
    options = options or {}
    local pool = live_pool(live_windows)

    local workspace_names = {}
    for _, workspace in ipairs(snapshot.workspaces or {}) do
        if is_named(workspace) then
            workspace_names[#workspace_names + 1] = { id = workspace.id, name = workspace.name }
        end
    end

    local launches, placements = {}, {}
    local launched_provider, launched_generic = {}, {}

    -- Ghostty first: one window per saved shell, in save order, which is also
    -- the order they will be claimed in (their pid tag does not exist until the
    -- restored shell draws its first prompt).
    -- shells.lua is written by a background /proc walk and can legitimately be
    -- empty (it has never run, or it ran before any shell existed). Without a
    -- fallback every terminal in the snapshot would be silently dropped, so the
    -- saved ghostty *windows* drive the restore instead — workspace only, since
    -- with no shell record there is no working directory to reopen in.
    local have_shells = #(snapshot.shells or {}) > 0

    for _, shell in ipairs(snapshot.shells or {}) do
        if shell.workspace and not take_live(pool, M.GHOSTTY_CLASS, nil) then
            launches[#launches + 1] = {
                provider = "ghostty",
                cmd = M.ghostty_command(shell, options),
            }
            placements[#placements + 1] = {
                class = M.GHOSTTY_CLASS,
                provider = "ghostty",
                workspace = shell.workspace,
                workspace_name = shell.workspace_name,
                floating = false,
                cwd = shell.cwd,
            }
        end
    end

    for _, window in ipairs(snapshot.windows or {}) do
        local provider = window.provider or M.provider_for(window.class)
        local title = window.title and M.strip_tags(window.title) or nil
        if provider == "ghostty" then
            if not have_shells and not take_live(pool, window.class, nil) then
                launches[#launches + 1] = {
                    provider = "ghostty",
                    cmd = M.ghostty_command({}, options),
                }
                placements[#placements + 1] = {
                    class = window.class,
                    provider = "ghostty",
                    workspace = window.workspace,
                    workspace_name = window.workspace_name,
                    floating = false,
                }
            end
        elseif not take_live(pool, window.class, title) then
            if provider == "chrome" then
                if not launched_provider.chrome then
                    launched_provider.chrome = true
                    launches[#launches + 1] = {
                        provider = "chrome",
                        cmd = (options.chrome_command or "google-chrome-stable")
                            .. " --restore-last-session",
                    }
                end
            elseif provider == "wezterm" then
                if not launched_provider.wezterm then
                    launched_provider.wezterm = true
                    launches[#launches + 1] = {
                        provider = "wezterm",
                        cmd = options.wezterm_command or "wezterm",
                    }
                end
            else
                -- Only the curated map. Replaying a /proc cmdline was the
                -- obvious alternative and is a trap twice over: argv arrives
                -- from /proc as a NUL-joined string with its word boundaries
                -- already destroyed, so `zathura "Some Paper (2024).pdf"` comes
                -- back as a syntax error and anything containing ; or $( ) is
                -- re-executed as shell code at every login; and what a process
                -- *became* is not what launched it — Obsidian reports a bare
                -- electron invocation that skips the wrapper setting its
                -- environment. An unmapped class is reported at restore time so
                -- it can be added here deliberately.
                local cmd = (options.class_commands or {})[window.class]
                -- Most of these are single-instance and would only focus
                -- the window they already own, so one launch per class.
                if cmd and cmd ~= "" and not launched_generic[window.class] then
                    launched_generic[window.class] = true
                    launches[#launches + 1] = { provider = "generic", cmd = cmd }
                end
            end

            placements[#placements + 1] = {
                class = window.class,
                provider = provider,
                title = title,
                wezterm_id = window.title and M.wezterm_id_from_title(window.title) or nil,
                workspace = window.workspace,
                workspace_name = window.workspace_name,
                at = window.at,
                size = window.size,
                floating = window.floating or false,
                fullscreen = window.fullscreen or 0,
                pinned = window.pinned or false,
                group = window.group,
            }
        end
    end

    for index, placement in ipairs(placements) do placement.order = index end

    -- Groups are rebuilt after every member has landed; a group whose members
    -- were split across workspaces at save time is dropped rather than guessed.
    local by_group = {}
    for _, placement in ipairs(placements) do
        local group = placement.group
        if group and group.id then
            local bucket = by_group[group.id]
            if not bucket then
                bucket = { workspace = placement.workspace, members = {} }
                by_group[group.id] = bucket
            end
            if bucket.workspace == placement.workspace then
                bucket.members[#bucket.members + 1] = placement.order
            else
                bucket.mixed = true
            end
        end
    end

    local groups = {}
    for id, bucket in pairs(by_group) do
        if not bucket.mixed and #bucket.members > 1 then
            table.sort(bucket.members)
            groups[#groups + 1] = { id = id, members = bucket.members }
        end
    end
    table.sort(groups, function(a, b) return a.members[1] < b.members[1] end)

    return {
        workspace_names = workspace_names,
        launches = launches,
        placements = placements,
        groups = groups,
    }
end

-- Claim the placement a newly opened window belongs to, most specific first:
-- an exact identity tag, then an exact stripped title, then save order among
-- windows of the same class. Returns the placement, or nil when the window is
-- not one we asked for (the user opened something mid-restore).
function M.match_window(placements, window)
    if not (window and window.class) then return nil end

    local wezterm_id = M.wezterm_id_from_title(window.title)
    if wezterm_id then
        for _, placement in ipairs(placements) do
            if not placement.claimed and placement.wezterm_id == wezterm_id then
                placement.claimed = true
                return placement
            end
        end
    end

    local title = M.strip_tags(window.title)
    if title ~= "" then
        for _, placement in ipairs(placements) do
            if not placement.claimed and placement.class == window.class
                and placement.title == title
            then
                placement.claimed = true
                return placement
            end
        end
    end

    for _, placement in ipairs(placements) do
        if not placement.claimed and placement.class == window.class then
            placement.claimed = true
            return placement
        end
    end
end

function M.unclaimed(placements)
    local pending = {}
    for _, placement in ipairs(placements) do
        if not placement.claimed then pending[#pending + 1] = placement end
    end
    return pending
end

return M
