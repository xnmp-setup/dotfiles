-- Offline tests for the pure session save/restore model.
-- Run: lua session_test.lua

package.path = (arg[0]:match("^(.*)/") or ".") .. "/?.lua;" .. package.path

local session_model = require("session_model")

local checks, failures = 0, 0

local function check(label, value)
    checks = checks + 1
    if value then return end
    failures = failures + 1
    io.write("FAIL  " .. label .. "\n")
end

local function equal(label, got, want)
    check(("%s (got %s, want %s)"):format(label, tostring(got), tostring(want)), got == want)
end

-- hl hands back an HL.Monitor object, never a name: a fake that used a bare
-- string would let a snapshot holding the object serialize cleanly here and
-- throw on every real save.
local function monitor(name)
    return { id = 0, name = name or "DP-1", width = 3440, height = 1440 }
end

local function window(options)
    return {
        class = options.class,
        title = options.title,
        mapped = true,
        workspace = { id = options.workspace, name = options.workspace_name },
        monitor = options.monitor or monitor(),
        floating = options.floating or false,
        at = options.at or { x = 0, y = 0 },
        size = options.size or { x = 800, y = 600 },
        fullscreen = options.fullscreen or 0,
        pinned = options.pinned or false,
        focus_history_id = options.history or 0,
        group = options.group,
    }
end

--------------------------------------------------------------------------
-- Invisible title tags
--------------------------------------------------------------------------

do
    local tagged = "codex session" .. session_model.encode_tag("pid:1234")
    equal("a stamped title decodes back to its payload",
        session_model.tag_payloads(tagged)[1], "pid:1234")
    equal("the visible title survives stripping",
        session_model.strip_tags(tagged), "codex session")
    equal("the shell pid is read off the title",
        session_model.shell_pid_from_title(tagged), 1234)

    -- The agent animator stamps its own payload; ours is appended after it.
    local both = "◈︎ Codex"
        .. session_model.encode_tag("codex")
        .. session_model.encode_tag("pid:99")
    local payloads = session_model.tag_payloads(both)
    equal("both payloads decode", #payloads, 2)
    equal("the agent payload keeps its position", payloads[1], "codex")
    equal("the pid payload is last", payloads[2], "pid:99")
    equal("the pid is still found behind an agent tag",
        session_model.shell_pid_from_title(both), 99)
    equal("stripping removes every tag run",
        session_model.strip_tags(both), "◈︎ Codex")

    -- Byte-compatible with dot_config/wezterm/wezterm_window_identity.lua.
    equal("wezterm window ids decode with the same scheme",
        session_model.wezterm_id_from_title("shell" .. session_model.encode_tag("wid:7")), 7)
    equal("a wid tag is not mistaken for a pid tag",
        session_model.shell_pid_from_title("shell" .. session_model.encode_tag("wid:7")), nil)

    equal("an untagged title has no pid",
        session_model.shell_pid_from_title("❯ chezmoi"), nil)
    equal("an empty title is handled", session_model.strip_tags(nil), "")
    -- A title truncated mid-tag has no terminator; the partial run is dropped
    -- rather than decoded into a bogus pid.
    local truncated = "x" .. session_model.encode_tag("pid:5"):sub(1, 6)
    equal("a truncated tag run yields no payload", #session_model.tag_payloads(truncated), 0)
    equal("a non-numeric pid payload is rejected",
        session_model.shell_pid_from_title("x" .. session_model.encode_tag("pid:abc")), nil)
end

--------------------------------------------------------------------------
-- Workspace attribution for ghostty shells
--------------------------------------------------------------------------

do
    local ghostty = session_model.GHOSTTY_CLASS
    local windows = {
        window({ class = ghostty, workspace = 3, history = 0,
            title = "❯ notes" .. session_model.encode_tag("pid:11") }),
        window({ class = ghostty, workspace = 7, history = 2,
            title = "❯ repo" .. session_model.encode_tag("pid:22") }),
    }
    local shells = {
        { pid = 11, cwd = "/a", command = "" },
        { pid = 22, cwd = "/b", command = "vim" },
        { pid = 33, cwd = "/c", command = "" },  -- background tab, seen earlier
        { pid = 44, cwd = "/d", command = "" },  -- never seen at all
    }
    local attributed = session_model.attribute_shells(shells, windows, { [33] = 5 })

    equal("a visible shell takes its window's workspace", attributed[1].workspace, 3)
    equal("and is recorded as exact", attributed[1].workspace_source, "title")
    equal("the second visible shell is not confused with the first",
        attributed[2].workspace, 7)
    equal("a backgrounded shell falls back to its last sighting",
        attributed[3].workspace, 5)
    equal("and says so", attributed[3].workspace_source, "sighting")
    equal("an unseen shell follows the focused ghostty window",
        attributed[4].workspace, 3)
    equal("and says so", attributed[4].workspace_source, "fallback")
    equal("the command is carried through", attributed[2].command, "vim")

    -- Precedence: a live title wins over a stale sighting for the same pid.
    local reattributed = session_model.attribute_shells(
        { { pid = 11, cwd = "/a" } }, windows, { [11] = 9 })
    equal("a live title beats a stale sighting", reattributed[1].workspace, 3)

    -- With no ghostty windows at all there is nothing to fall back to.
    local orphaned = session_model.attribute_shells({ { pid = 1, cwd = "/x" } }, {}, {})
    equal("an orphaned shell gets no workspace", orphaned[1].workspace, nil)
    equal("and no source", orphaned[1].workspace_source, nil)
end

--------------------------------------------------------------------------
-- Snapshot building
--------------------------------------------------------------------------

do
    local snapshot = session_model.build_snapshot({
        now = 1786058449,
        workspaces = {
            { id = 2, name = "SillyTavern", monitor = "DP-1" },
            { id = 1, name = "Base", monitor = "DP-1" },
            { id = 9, name = "9", monitor = "DP-1" },          -- never renamed
            { id = -98, name = "special:ghostty-drop" },        -- not a workspace to name
        },
        windows = {
            window({ class = "google-chrome", workspace = 1, history = 1, title = "New tab" }),
            window({ class = "obsidian", workspace = 6, history = 0, title = "Vault" }),
            window({ class = "", workspace = 1 }),              -- unusable
        },
        shells = {},
    })

    equal("the snapshot declares its version", snapshot.version, session_model.VERSION)
    equal("the save time is recorded", snapshot.saved_at, 1786058449)
    equal("classless windows are dropped", #snapshot.windows, 2)
    equal("special workspaces are not offered for renaming", #snapshot.workspaces, 3)
    equal("workspaces come out sorted", snapshot.workspaces[1].id, 1)
    equal("a never-renamed workspace is still captured", snapshot.workspaces[3].name, "9")
    equal("windows are grouped by workspace", snapshot.windows[1].workspace, 1)
    equal("the provider is resolved at save time", snapshot.windows[1].provider, "chrome")
    equal("an unknown class falls to the generic provider",
        snapshot.windows[2].provider, "generic")

    -- Special *windows* are kept even though special workspaces are not
    -- renamed: that is how the F8/F9 drop-downs come back parked.
    local with_pad = session_model.build_snapshot({
        windows = { window({ class = "google-chrome", workspace = -97,
            workspace_name = "special:chrome-drop" }) },
    })
    equal("a drop-down window is captured", #with_pad.windows, 1)
    equal("with its special workspace", with_pad.windows[1].workspace, -97)

    -- Monitors are objects. Only the name may reach the snapshot: the object
    -- itself is userdata, which the serializer refuses, so storing it would
    -- make every save throw.
    local named = session_model.build_snapshot({
        workspaces = { { id = 1, name = "Base", monitor = monitor("DP-2") } },
        windows = { window({ class = "obsidian", workspace = 1, monitor = monitor("DP-2") }) },
    })
    equal("a window records the monitor by name", named.windows[1].monitor, "DP-2")
    equal("and so does a workspace", named.workspaces[1].monitor, "DP-2")
    check("a snapshot carrying a monitor still serializes",
        pcall(session_model.serialize, named))

    -- An opaque object stands in for the userdata a real monitor is: it may not
    -- even be indexable, and that must cost the field, not the save.
    local opaque = session_model.build_snapshot({
        workspaces = { { id = 1, name = "Base", monitor = coroutine.create(function() end) } },
        windows = { window({ class = "obsidian", workspace = 1,
            monitor = coroutine.create(function() end) }) },
    })
    equal("an unreadable monitor is dropped", opaque.windows[1].monitor, nil)

    -- Some callers describe a monitor by id rather than by object.
    local numbered = session_model.build_snapshot({
        windows = { window({ class = "obsidian", workspace = 1, monitor = 2 }) },
    })
    equal("a numeric monitor id is kept as text", numbered.windows[1].monitor, "2")
    check("and the snapshot still serializes",
        pcall(session_model.serialize, opaque))
end

--------------------------------------------------------------------------
-- Serialization
--------------------------------------------------------------------------

do
    local snapshot = session_model.build_snapshot({
        now = 1,
        workspaces = { { id = 1, name = "Base" } },
        windows = { window({ class = "obsidian", workspace = 1, title = 'quote " and \\ and \n' }) },
        shells = { { pid = 7, cwd = "/tmp/a b", command = "echo 'hi'" } },
    })

    local text = session_model.serialize(snapshot)
    local loaded = assert(load(text))()
    equal("a snapshot survives a serialize/load round trip",
        loaded.windows[1].title, snapshot.windows[1].title)
    equal("shell commands survive quoting", loaded.shells[1].command, "echo 'hi'")
    equal("paths with spaces survive", loaded.shells[1].cwd, "/tmp/a b")
    equal("serialization is deterministic", session_model.serialize(loaded), text)

    equal("an empty table serializes", session_model.serialize({}), "return {}\n")

    -- Sizes worth refusing rather than half-writing.
    local big = { version = session_model.VERSION, windows = {} }
    for index = 1, 500 do
        big.windows[index] = { class = "x", workspace = 1, title = string.rep("t", 200) }
    end
    check("a large snapshot still serializes", #session_model.serialize(big) > 100000)
end

--------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------

do
    equal("a non-table is rejected", session_model.validate("nope"), nil)
    equal("nil is rejected", session_model.validate(nil), nil)
    equal("a v1 snapshot is rejected", session_model.validate({ version = 1, windows = {} }), nil)
    equal("a snapshot with no windows table is rejected",
        session_model.validate({ version = 2 }), nil)
    equal("an empty snapshot is rejected",
        session_model.validate({ version = 2, windows = {}, shells = {} }), nil)
    check("a snapshot with only shells is accepted",
        session_model.validate({ version = 2, windows = {}, shells = { {} } }) ~= nil)
    check("a populated snapshot is accepted",
        session_model.validate({ version = 2, windows = { {} } }) ~= nil)
end

--------------------------------------------------------------------------
-- Ghostty launch command
--------------------------------------------------------------------------

do
    local plain = session_model.ghostty_command({ cwd = "/home/chong/repo" })
    check("the working directory comes before -e, which swallows the rest",
        plain:find("--working%-directory") < plain:find("%-e "))
    -- Named, not pathed: /usr/bin/zsh does not exist on NixOS. And -l, because
    -- -e replaces ghostty's default login shell and the system environment
    -- comes from /etc/zprofile, which a non-login shell never reads.
    check("a login shell is launched by name", plain:find("-e zsh -l", 1, true) ~= nil)
    check("no absolute shell path is baked in", plain:find("/usr/bin/zsh") == nil)
    check("no command is exported when none was saved",
        plain:find("HYPR_RESTORE_CMD") == nil)

    local pretyped = session_model.ghostty_command({
        cwd = "/tmp/a b", command = "npm run test:e2e",
    })
    check("the saved command is exported for print -z, not executed",
        pretyped:find("export HYPR_RESTORE_CMD=", 1, true) ~= nil)
    check("the shell is re-exec'd as a login shell after the export",
        pretyped:find("exec zsh -l", 1, true) ~= nil)
    check("a directory with spaces is quoted", pretyped:find("'/tmp/a b'", 1, true) ~= nil)

    -- A command carrying single quotes must not break out of either quoting
    -- layer. Assert on behaviour, not on an escaping shape: run the generated
    -- `-e` fragment for real, with sh standing in for zsh, and read back what
    -- the re-exec'd interactive shell would see in its environment. If the
    -- quoting leaked, `rm -rf /` would be a second command rather than data.
    local nasty = [[echo 'it'"'"'s'; rm -rf /]]
    local command = session_model.ghostty_command(
        { cwd = "/tmp", command = nasty }, { shell_bin = "sh" })
    local fragment = assert(command:match("%-e (.+)$"))
    local function shell_quote(text) return "'" .. text:gsub("'", "'\\''") .. "'" end
    -- `exec sh -l` reads the script from stdin, which is where the probe goes.
    local pipe = io.popen(("echo 'printf %%s \"$HYPR_RESTORE_CMD\"' | sh -c %s 2>/dev/null")
        :format(shell_quote(fragment)))
    local rendered = pipe:read("*a")
    pipe:close()
    equal("a command with quotes survives both quoting layers", rendered, nasty)
end

--------------------------------------------------------------------------
-- Restore planning
--------------------------------------------------------------------------

local function snapshot_for(windows, shells, workspaces)
    return {
        version = session_model.VERSION,
        workspaces = workspaces or {},
        windows = windows or {},
        shells = shells or {},
    }
end

-- A saved ghostty window, tagged with the pid of the shell that was its visible
-- tab — which is how the restore knows what to reopen it with.
local function ghostty_window(workspace, pid, title)
    return {
        class = session_model.GHOSTTY_CLASS,
        provider = "ghostty",
        workspace = workspace,
        title = (title or "❯ term") .. session_model.encode_tag("pid:" .. pid),
    }
end

do
    local plan = session_model.plan_restore(snapshot_for(
        {
            { class = "google-chrome", workspace = 1, title = "Inbox", provider = "chrome" },
            { class = "google-chrome", workspace = 2, title = "Docs", provider = "chrome" },
            { class = "obsidian", workspace = 6, title = "Vault", provider = "generic",
              cmdline = "obsidian" },
            ghostty_window(1, 1, "❯ a"),
            ghostty_window(3, 2, "❯ b"),
        },
        { { pid = 1, cwd = "/a", workspace = 1 }, { pid = 2, cwd = "/b", workspace = 3 } },
        { { id = 1, name = "Base" }, { id = 2, name = "SillyTavern" }, { id = 9, name = "9" } }
    ), {})

    equal("only renamed workspaces are re-named", #plan.workspace_names, 2)
    equal("the name is carried", plan.workspace_names[1].name, "Base")

    equal("chrome is launched once for all its windows",
        #(function()
            local chrome = {}
            for _, launch in ipairs(plan.launches) do
                if launch.provider == "chrome" then chrome[#chrome + 1] = launch end
            end
            return chrome
        end)(), 1)
    equal("every window still gets a placement", #plan.placements, 5)

    local ghostty_launches = 0
    for _, launch in ipairs(plan.launches) do
        if launch.provider == "ghostty" then ghostty_launches = ghostty_launches + 1 end
    end
    equal("one terminal is launched per saved ghostty window", ghostty_launches, 2)

    check("chrome is launched with its own session restore",
        (function()
            for _, launch in ipairs(plan.launches) do
                if launch.provider == "chrome" then
                    return launch.cmd:find("--restore-last-session", 1, true) ~= nil
                end
            end
        end)())
end

do
    -- The old script collapsed every window of a class into one launch. It must
    -- not do that any more: three saved Chrome windows are three placements.
    local plan = session_model.plan_restore(snapshot_for({
        { class = "google-chrome", workspace = 1, title = "a", provider = "chrome" },
        { class = "google-chrome", workspace = 2, title = "b", provider = "chrome" },
        { class = "google-chrome", workspace = 3, title = "c", provider = "chrome" },
    }), {})
    equal("saved windows are not deduplicated by class", #plan.placements, 3)
    equal("the third window keeps its own workspace", plan.placements[3].workspace, 3)
end

do
    -- A generic app with no recorded cmdline falls back to the class map.
    local plan = session_model.plan_restore(
        snapshot_for({ { class = "Thunar", workspace = 4, provider = "generic" } }),
        {},
        { class_commands = { Thunar = "thunar" } })
    equal("the class map supplies the missing command", plan.launches[1].cmd, "thunar")

    -- A class with no map entry launches nothing at all. The tempting
    -- alternative — replay the command line /proc reported — cannot be done
    -- safely: argv arrives NUL-joined with its word boundaries gone, so it
    -- would be re-parsed by a shell at every login.
    local unlaunchable = session_model.plan_restore(
        snapshot_for({ { class = "mystery", workspace = 4, provider = "generic" } }), {}, {})
    equal("an unknown class launches nothing", #unlaunchable.launches, 0)
    equal("but is still placed if it happens to appear", #unlaunchable.placements, 1)
end

do
    -- Manual re-restore: what is already on screen is left alone.
    local plan = session_model.plan_restore(snapshot_for(
        {
            { class = "google-chrome", workspace = 1, title = "Inbox", provider = "chrome" },
            { class = "google-chrome", workspace = 2, title = "Docs", provider = "chrome" },
        },
        { { pid = 1, cwd = "/a", workspace = 1 } }
    ), {
        { class = "google-chrome", title = "Inbox" },
    })

    equal("an already-open window is neither relaunched nor moved", #plan.placements, 1)
    equal("and the remaining one is the one still missing",
        plan.placements[1].title, "Docs")
    equal("chrome is still launched for the missing window", #plan.launches, 1)
end

--------------------------------------------------------------------------
-- Matching opened windows to placements
--------------------------------------------------------------------------

do
    local plan = session_model.plan_restore(snapshot_for({
        { class = "google-chrome", workspace = 1, title = "New tab", provider = "chrome" },
        { class = "google-chrome", workspace = 5, title = "New tab", provider = "chrome" },
        { class = "obsidian", workspace = 6, title = "Vault", provider = "generic" },
    }), {})
    local placements = plan.placements

    local first = session_model.match_window(placements, { class = "google-chrome", title = "New tab" })
    equal("an ambiguous title claims the earliest saved slot", first.workspace, 1)
    local second = session_model.match_window(placements, { class = "google-chrome", title = "New tab" })
    equal("the next identical window claims the next slot", second.workspace, 5)
    equal("a third is unaccounted for",
        session_model.match_window(placements, { class = "google-chrome", title = "New tab" }), nil)

    equal("a different class matches on class alone",
        session_model.match_window(placements, { class = "obsidian", title = "Vault - renamed" }).workspace, 6)
    equal("an uninvited window matches nothing",
        session_model.match_window(placements, { class = "firefox", title = "x" }), nil)
    equal("a window with no class matches nothing",
        session_model.match_window(placements, { title = "x" }), nil)
    equal("everything was claimed", #session_model.unclaimed(placements), 0)
end

do
    -- Exact title beats save order, so a distinguishable window is not stolen
    -- by an earlier ambiguous slot.
    local plan = session_model.plan_restore(snapshot_for({
        { class = "google-chrome", workspace = 1, title = "New tab", provider = "chrome" },
        { class = "google-chrome", workspace = 5, title = "Docs", provider = "chrome" },
    }), {})
    local matched = session_model.match_window(plan.placements,
        { class = "google-chrome", title = "Docs" })
    equal("an exact title wins over save order", matched.workspace, 5)
end

do
    -- WezTerm windows carry a deterministic mux id in their title, so they are
    -- matched on identity rather than on a title that changes as tabs switch.
    local plan = session_model.plan_restore(snapshot_for({
        { class = session_model.WEZTERM_CLASS, workspace = 2, provider = "wezterm",
          title = "editing" .. session_model.encode_tag("wid:0") },
        { class = session_model.WEZTERM_CLASS, workspace = 8, provider = "wezterm",
          title = "building" .. session_model.encode_tag("wid:1") },
    }), {})

    local matched = session_model.match_window(plan.placements, {
        class = session_model.WEZTERM_CLASS,
        title = "something else entirely" .. session_model.encode_tag("wid:1"),
    })
    equal("a wezterm window is matched by mux id, not title", matched.workspace, 8)

    -- Before the tagged title formatter runs the window is untagged; it must
    -- still land somewhere rather than be dropped.
    local untagged = session_model.match_window(plan.placements,
        { class = session_model.WEZTERM_CLASS, title = "" })
    equal("an untagged wezterm window falls back to save order", untagged.workspace, 2)
end

do
    -- Ghostty windows have no identity at open time, so they are claimed in
    -- launch order, which is save order.
    local plan = session_model.plan_restore(snapshot_for(
        { ghostty_window(1, 1), ghostty_window(4, 2) },
        {
            { pid = 1, cwd = "/first", workspace = 1 },
            { pid = 2, cwd = "/second", workspace = 4 },
        }), {})
    local first = session_model.match_window(plan.placements,
        { class = session_model.GHOSTTY_CLASS, title = "" })
    local second = session_model.match_window(plan.placements,
        { class = session_model.GHOSTTY_CLASS, title = "" })
    equal("the first ghostty window takes the first shell's workspace", first.workspace, 1)
    equal("the second takes the second", second.workspace, 4)
    equal("and carries its cwd for logging", second.cwd, "/second")
end

--------------------------------------------------------------------------
-- Group reconstruction
--------------------------------------------------------------------------

do
    local plan = session_model.plan_restore(snapshot_for({
        { class = "google-chrome", workspace = 1, title = "a", provider = "chrome",
          group = { id = "g1", index = 0 } },
        { class = "obsidian", workspace = 1, title = "b", provider = "generic",
          group = { id = "g1", index = 1 } },
        { class = "code", workspace = 2, title = "c", provider = "generic" },
    }), {})

    equal("one group is planned", #plan.groups, 1)
    equal("with both members", #plan.groups[1].members, 2)
    equal("identified by placement order", plan.groups[1].members[1], 1)

    -- A group whose members were saved on different workspaces cannot be
    -- rebuilt without guessing which workspace wins, so it is dropped.
    local split = session_model.plan_restore(snapshot_for({
        { class = "google-chrome", workspace = 1, title = "a", provider = "chrome",
          group = { id = "g1", index = 0 } },
        { class = "obsidian", workspace = 3, title = "b", provider = "generic",
          group = { id = "g1", index = 1 } },
    }), {})
    equal("a group split across workspaces is not rebuilt", #split.groups, 0)

    -- A one-member "group" is not a group.
    local lonely = session_model.plan_restore(snapshot_for({
        { class = "obsidian", workspace = 1, title = "b", provider = "generic",
          group = { id = "g1", index = 0 } },
    }), {})
    equal("a single-member group is ignored", #lonely.groups, 0)
end

--------------------------------------------------------------------------
-- Degenerate input
--------------------------------------------------------------------------

do
    local empty = session_model.plan_restore(snapshot_for({}, {}, {}), {})
    equal("an empty snapshot plans no launches", #empty.launches, 0)
    equal("and no placements", #empty.placements, 0)

    local nils = session_model.plan_restore({ version = 2 }, nil)
    equal("missing tables are tolerated", #nils.placements, 0)

    -- Shells are what a restored window resumes, never what produces one: a
    -- shell whose window is not in the capture has nowhere to be put.
    local windowless = session_model.plan_restore(
        snapshot_for({}, { { pid = 1, cwd = "/a", workspace = 1 } }), {})
    equal("a shell with no window of its own is not restored", #windowless.launches, 0)
end

do
    -- shells.lua is written by a background /proc walk and can legitimately be
    -- empty — it has never run, or it ran before any shell existed. The saved
    -- ghostty windows still come back; only their directories are lost.
    local ghostty = session_model.GHOSTTY_CLASS
    local plan = session_model.plan_restore(snapshot_for({
        { class = ghostty, workspace = 3, title = "❯ a", provider = "ghostty" },
        { class = ghostty, workspace = 5, title = "❯ b", provider = "ghostty" },
    }, {}), {})
    equal("a terminal is launched for every saved ghostty window", #plan.launches, 2)
    equal("each is placed where it was", (plan.placements[2] or {}).workspace, 5)
    check("with no working directory, since none was recorded",
        (plan.launches[1] or { cmd = "" }).cmd:find("--working%-directory") == nil)

    -- A terminal already on screen is not relaunched.
    local live = session_model.plan_restore(
        snapshot_for({ { class = ghostty, workspace = 3, provider = "ghostty" } }, {}),
        { { class = ghostty, title = "❯ a" } })
    equal("an open terminal is not relaunched", #live.launches, 0)
end

do
    -- Ghostty tabs are surfaces of one process: the CLI can only open windows,
    -- so six shells in three windows would restore as six windows and the
    -- tabbing could not be put back. One window per saved window, resuming the
    -- shell whose pid its title carried — the tab that was visible.
    local plan = session_model.plan_restore(snapshot_for(
        { ghostty_window(1, 11, "❯ repo"), ghostty_window(4, 22, "❯ notes") },
        {
            { pid = 11, cwd = "/repo", command = "vim", workspace = 1 },
            { pid = 12, cwd = "/hidden-a", command = "", workspace = 1 },
            { pid = 13, cwd = "/hidden-b", command = "", workspace = 1 },
            { pid = 22, cwd = "/notes", command = "less log", workspace = 4 },
            { pid = 23, cwd = "/hidden-c", command = "", workspace = 4 },
        }), {})

    equal("five shells in two windows restore as two windows", #plan.launches, 2)
    check("the first resumes its visible tab's directory",
        plan.launches[1].cmd:find("'/repo'", 1, true) ~= nil)
    check("and that tab's command", plan.launches[1].cmd:find("vim", 1, true) ~= nil)
    check("the second resumes its own",
        plan.launches[2].cmd:find("'/notes'", 1, true) ~= nil)
    check("no background tab is opened as a window of its own",
        not table.concat({ plan.launches[1].cmd, plan.launches[2].cmd }, " ")
            :find("hidden", 1, true))
    equal("and each lands where its window was", plan.placements[2].workspace, 4)

    -- Both windows still open: nothing to launch, and no extra window per tab.
    local live = session_model.plan_restore(snapshot_for(
        { ghostty_window(1, 11, "❯ repo"), ghostty_window(4, 22, "❯ notes") },
        {
            { pid = 11, cwd = "/repo", workspace = 1 },
            { pid = 12, cwd = "/hidden-a", workspace = 1 },
            { pid = 22, cwd = "/notes", workspace = 4 },
        }), {
            { class = session_model.GHOSTTY_CLASS, title = "❯ repo" },
            { class = session_model.GHOSTTY_CLASS, title = "❯ notes" },
        })
    equal("terminals already on screen launch nothing", #live.launches, 0)
    equal("and are left where they are", #live.placements, 0)
end

do
    -- The greedy-claim bug, from the desktop it was found on: three windows of
    -- one class saved on workspaces 1, 2 and 3, the first one closed, then a
    -- manual re-restore. Claiming in one pass, the saved workspace-1 slot ate a
    -- live window and looked satisfied, and the relaunch inherited the last
    -- slot's placement — the window came back on workspace 3.
    local plan = session_model.plan_restore(snapshot_for({
        { class = "tauri-explorer", workspace = 1, title = "one", provider = "generic" },
        { class = "tauri-explorer", workspace = 2, title = "two", provider = "generic" },
        { class = "tauri-explorer", workspace = 3, title = "three", provider = "generic" },
    }), {
        { class = "tauri-explorer", title = "two" },
        { class = "tauri-explorer", title = "three" },
    }, { class_commands = { ["tauri-explorer"] = "tauri-explorer" } })

    equal("only the closed window is relaunched", #plan.launches, 1)
    equal("and only it is placed", #plan.placements, 1)
    equal("on the workspace it was closed from", plan.placements[1].workspace, 1)
    equal("as the window it actually was", plan.placements[1].title, "one")

    -- An exact title still beats save order when several are missing.
    local two_gone = session_model.plan_restore(snapshot_for({
        { class = "tauri-explorer", workspace = 1, title = "one", provider = "generic" },
        { class = "tauri-explorer", workspace = 2, title = "two", provider = "generic" },
        { class = "tauri-explorer", workspace = 3, title = "three", provider = "generic" },
    }), { { class = "tauri-explorer", title = "three" } }, {})
    equal("the two missing windows are the two planned", #two_gone.placements, 2)
    equal("in save order", two_gone.placements[1].workspace, 1)
    equal("with the surviving one dropped", two_gone.placements[2].workspace, 2)

    -- Identical titles, from the desktop this one was found on too: a stale
    -- duplicate of the same page parked on another workspace. With the title
    -- alone to go on, the closed workspace-1 slot claims the live workspace-3
    -- window and the relaunch lands on workspace 3 all over again. Where the
    -- live window actually is settles it.
    local duplicate = "Inbox - Tauri Explorer"
    local twins = session_model.plan_restore(snapshot_for({
        { class = "tauri-explorer", workspace = 1, title = duplicate, provider = "generic" },
        { class = "tauri-explorer", workspace = 3, title = duplicate, provider = "generic" },
    }), { { class = "tauri-explorer", title = duplicate, workspace = { id = 3 } } }, {})
    equal("only the closed twin is planned", #twins.placements, 1)
    equal("and it is the one that was on workspace 1", twins.placements[1].workspace, 1)

    -- The live window having moved since the save is the case the title pass
    -- is still there for.
    local moved = session_model.plan_restore(snapshot_for({
        { class = "tauri-explorer", workspace = 1, title = "one", provider = "generic" },
        { class = "tauri-explorer", workspace = 3, title = "three", provider = "generic" },
    }), { { class = "tauri-explorer", title = "three", workspace = { id = 8 } } }, {})
    equal("a window that moved is still recognised by title", #moved.placements, 1)
    equal("leaving the one that is really missing", moved.placements[1].workspace, 1)

    -- A live window whose title matches nothing saved still satisfies a slot,
    -- because it is a window of that class that is already on screen.
    local renamed = session_model.plan_restore(snapshot_for({
        { class = "tauri-explorer", workspace = 1, title = "one", provider = "generic" },
        { class = "tauri-explorer", workspace = 2, title = "two", provider = "generic" },
    }), { { class = "tauri-explorer", title = "something else" } }, {})
    equal("an unrecognised live window is still accounted for", #renamed.placements, 1)
    equal("against the earliest unclaimed slot", renamed.placements[1].workspace, 2)
end


--------------------------------------------------------------------------
-- The adapter
--------------------------------------------------------------------------
-- Driven through a fake hl in the desktop_test.lua style. Two things the fake
-- deliberately models faithfully, because the module's correctness rests on
-- them: timers honour their timeouts (the short per-window match delay versus
-- the long settle), and hl.get_windows/get_workspaces are the *only* source of
-- window data — this module must never shell out to hyprctl, which would
-- deadlock the compositor that is waiting for it.
--
-- What the fake cannot catch: whether Hyprland actually accepts a given
-- dispatcher's arguments. That is why the dispatches used here are restricted
-- to forms with existing precedent elsewhere in this config.

local session_restore = require("session_restore")

local function fake_hl(live_windows, live_workspaces)
    local control = {
        dispatches = {}, executed = {}, timers = {}, handlers = {},
        windows = live_windows or {},
        workspaces = live_workspaces or {},
    }
    local function record(kind)
        return function(arguments) return { kind = kind, args = arguments or {} } end
    end
    local hl = {
        dsp = {
            exec_cmd = function(cmd, rules) return { kind = "exec", cmd = cmd, rules = rules } end,
            exit = record("exit"),
            focus = record("focus"),
            window = {
                move = record("move"),
                float = record("float"),
                resize = record("resize"),
                pin = record("pin"),
                fullscreen = record("fullscreen"),
            },
        },
        dispatch = function(descriptor)
            control.dispatches[#control.dispatches + 1] = descriptor
        end,
        exec_cmd = function(cmd) control.executed[#control.executed + 1] = cmd end,
        on = function(event, handler) control.handlers[event] = handler end,
        timer = function(fn, timer_options)
            control.timers[#control.timers + 1] = {
                at = control.clock + ((timer_options or {}).timeout or 0),
                fn = fn,
            }
        end,
        get_windows = function() return control.windows end,
        get_workspaces = function() return control.workspaces end,
        get_active_window = function() return control.active end,
    }

    -- A virtual clock rather than a fire-everything tick. The module leans on
    -- the gap between the short per-window match delay and the long settle: a
    -- fake that ignored timeouts would run the settle first and every
    -- assertion about placement would pass for the wrong reason.
    control.clock = 0
    function control.advance(milliseconds)
        local target = control.clock + milliseconds
        while true do
            local due_index, due_at
            for index, timer in ipairs(control.timers) do
                if timer.at <= target and (not due_at or timer.at < due_at) then
                    due_index, due_at = index, timer.at
                end
            end
            if not due_index then break end
            local timer = table.remove(control.timers, due_index)
            control.clock = timer.at
            timer.fn()
        end
        control.clock = target
    end

    function control.open(window) control.handlers["window.open"](window) end
    function control.start() control.handlers["hyprland.start"]() end

    function control.dispatches_of(kind)
        local found = {}
        for _, descriptor in ipairs(control.dispatches) do
            if descriptor.kind == kind then found[#found + 1] = descriptor end
        end
        return found
    end

    -- The shapes a restore plan can produce here. An allowlist, not "everything
    -- that is not housekeeping": renames, the /proc walk and the state
    -- directory permissions go through the same exec_cmd, and a denylist
    -- quietly counts the next piece of housekeeping added as a restored window.
    control.launch_patterns = { "^ghostty ", "^google%-chrome", "^wezterm" }

    function control.launches()
        local found = {}
        for _, command in ipairs(control.executed) do
            for _, pattern in ipairs(control.launch_patterns) do
                if command:match(pattern) then
                    found[#found + 1] = command
                    break
                end
            end
        end
        return found
    end

    -- Requests for the background /proc walk, which must not run while a
    -- restore is placing windows.
    function control.walks()
        local found = {}
        for _, command in ipairs(control.executed) do
            if command:match("hypr%-session%-shells") then found[#found + 1] = command end
        end
        return found
    end

    function control.renames()
        local found = {}
        for _, command in ipairs(control.executed) do
            if command:match("^rename%-ws") then found[#found + 1] = command end
        end
        return found
    end

    return hl, control
end

-- os.tmpname() insists on /tmp, which is not writable under every sandbox this
-- suite runs in. TMPDIR plus a counter is enough: the files are removed by the
-- test that made them, and a collision would only affect a concurrent run of
-- this same suite.
local temp_serial = 0
local function temp_path()
    temp_serial = temp_serial + 1
    return ("%s/session_test.%d.%d.lua"):format(
        os.getenv("TMPDIR") or "/tmp", os.time(), temp_serial)
end

local function write(path, text)
    local handle = assert(io.open(path, "w"))
    handle:write(text)
    handle:close()
end

local function restorer(options)
    options = options or {}
    local hl, control = fake_hl(options.live_windows, options.live_workspaces)
    local handle = session_restore.new(hl, {
        snapshot_path = options.snapshot_path or temp_path(),
        shells_path = options.shells_path or "/nonexistent-shells.lua",
        shells_command = "hypr-session-shells",
        rename_command = "rename-ws",
        map_path = options.map_path or "/nonexistent-map.conf",
        write_file = options.write_file,
        log = function() end,
    })
    return handle, control
end

do
    -- The boot contract. This is the whole reason restore lives in-process:
    -- hyprland.lua.tmpl only falls back to its normal startup launches when
    -- boot() says false, so every unusable snapshot must say false rather than
    -- raise or half-restore.
    local missing = restorer({ snapshot_path = "/nonexistent/session.lua" })
    equal("a missing snapshot does not claim the boot", missing.boot(), false)

    local cases = {
        { "a truncated snapshot", "return { this is not lua" },
        { "a snapshot that is not a table", "return 42" },
        { "a previous-version snapshot", 'return { ["version"] = 1, ["windows"] = {} }' },
        { "an empty snapshot", 'return { ["version"] = 2, ["windows"] = {}, ["shells"] = {} }' },
    }
    for _, case in ipairs(cases) do
        local path = temp_path()
        write(path, case[2])
        local handle = restorer({ snapshot_path = path })
        equal(case[1] .. " does not claim the boot", handle.boot(), false)
        os.remove(path)
    end
end

local function snapshot_file()
    local path = temp_path()
    write(path, session_model.serialize({
        version = session_model.VERSION,
        workspaces = {
            { id = 1, name = "Base" },
            { id = 2, name = "It's \"quoted\"" },
            { id = 9, name = "9" },
        },
        windows = {
            { class = "google-chrome", workspace = 2, title = "Inbox", provider = "chrome" },
            { class = "obsidian", workspace = 6, title = "Vault", provider = "generic" },
            { class = "google-chrome", workspace = -97, provider = "chrome",
              workspace_name = "special:chrome-drop", title = "Drop",
              floating = true, at = { 100, 200 }, size = { 800, 600 }, pinned = true },
            ghostty_window(3, 1, "❯ repo"),
        },
        shells = { { pid = 1, cwd = "/home/chong/repo", command = "vim", workspace = 3 } },
    }))
    return path
end

do
    local path = snapshot_file()
    local handle, control = restorer({
        snapshot_path = path,
        map_path = "/dev/null",
    })

    equal("a usable snapshot claims the boot", handle.boot(), true)
    equal("and suppression is on while it runs", handle.is_restoring(), true)

    local renames = control.renames()
    equal("only renamed workspaces are renamed", #renames, 2)
    check("the workspace name is shell-quoted, quotes and all",
        renames[2]:find([[rename-ws 2 'It'\''s "quoted"']], 1, true) ~= nil)

    local launches = control.launches()
    local saw_chrome, saw_ghostty = false, false
    for _, command in ipairs(launches) do
        if command:find("--restore-last-session", 1, true) then saw_chrome = true end
        if command:find("ghostty +new-window", 1, true) then saw_ghostty = true end
    end
    check("chrome is asked to restore its own tabs", saw_chrome)
    check("a ghostty window is launched for the saved shell", saw_ghostty)

    -- Windows are placed only after the match delay, so a wezterm window has
    -- time to write its identity into its title.
    control.open({ class = "google-chrome", title = "Inbox", mapped = true })
    equal("nothing is moved in the same frame", #control.dispatches_of("move"), 0)
    control.advance(500)
    local moves = control.dispatches_of("move")
    equal("then the window is moved", #moves, 1)
    equal("to its saved workspace", moves[1].args.workspace, "2")
    equal("without following it", moves[1].args.silent, true)

    -- A drop-down is addressed by workspace name, not by its negative id.
    control.open({ class = "google-chrome", title = "Drop", mapped = true })
    control.advance(500)
    moves = control.dispatches_of("move")
    equal("a special workspace is addressed by name",
        moves[2].args.workspace, "special:chrome-drop")
    equal("a floating window is floated", #control.dispatches_of("float"), 1)
    equal("and sized", control.dispatches_of("resize")[1].args.x, 800)
    equal("and positioned", moves[3].args.x, 100)

    -- Fullscreen and pin have no window-targeted dispatcher — both act on the
    -- focused window — so they must not fire during the silent placement pass,
    -- or they would hit whatever the user is looking at.
    equal("nothing is pinned while windows are being placed",
        #control.dispatches_of("pin"), 0)
    equal("and nothing is fullscreened", #control.dispatches_of("fullscreen"), 0)

    -- An uninvited window mid-restore is left alone rather than shoved onto
    -- someone else's workspace.
    local before = #control.dispatches_of("move")
    control.open({ class = "firefox", title = "unrelated", mapped = true })
    control.advance(500)
    equal("a window nobody asked for is not moved", #control.dispatches_of("move"), before)

    control.advance(60000)  -- past the settle
    equal("suppression is released when the restore ends", handle.is_restoring(), false)
    equal("the pinned window is pinned at the end, once", #control.dispatches_of("pin"), 1)
    local focuses = control.dispatches_of("focus")
    check("pinning focuses its target first", #focuses >= 1)

    equal("a second restore after the first finished is allowed", handle.boot(), true)
    os.remove(path)
end

do
    -- Ghostty windows carry no identity when they open, so they are matched by
    -- order — which means they must be launched in order. Fired in a loop, the
    -- single-instance daemon maps them in whatever sequence it likes and the
    -- terminals land on arbitrary workspaces.
    local path = temp_path()
    write(path, session_model.serialize({
        version = session_model.VERSION,
        workspaces = {},
        windows = {
            { class = "obsidian", workspace = 1, title = "V", provider = "generic" },
            ghostty_window(1, 1, "❯ first"),
            ghostty_window(4, 2, "❯ second"),
            ghostty_window(7, 3, "❯ third"),
        },
        shells = {
            { pid = 1, cwd = "/first", workspace = 1 },
            { pid = 2, cwd = "/second", workspace = 4 },
            { pid = 3, cwd = "/third", workspace = 7 },
        },
    }))
    local handle, control = restorer({ snapshot_path = path, map_path = "/dev/null" })
    handle.boot()

    local function ghostty_launches()
        local found = {}
        for _, command in ipairs(control.launches()) do
            if command:find("ghostty", 1, true) then found[#found + 1] = command end
        end
        return found
    end

    equal("only the first ghostty window is launched up front", #ghostty_launches(), 1)
    check("and it is the first saved shell",
        ghostty_launches()[1]:find("/first", 1, true) ~= nil)

    control.open({ class = session_model.GHOSTTY_CLASS, title = "", mapped = true })
    control.advance(500)
    equal("the next launches once the previous window is claimed", #ghostty_launches(), 2)
    check("in saved order", ghostty_launches()[2]:find("/second", 1, true) ~= nil)
    equal("and the first landed on the first shell's workspace",
        control.dispatches_of("move")[1].args.workspace, "1")

    -- A window that never appears must not stall the rest of the queue.
    control.advance(2000)
    equal("a window that never appears is given up on", #ghostty_launches(), 3)
    check("and the queue continues", ghostty_launches()[3]:find("/third", 1, true) ~= nil)

    -- The claim that arrives late must not double-advance the queue.
    control.open({ class = session_model.GHOSTTY_CLASS, title = "", mapped = true })
    control.advance(500)
    equal("a late claim does not launch a fourth window", #ghostty_launches(), 3)
    os.remove(path)
end

do
    -- A window that opens after the settle belongs to the user, not the
    -- restore, and must not be moved.
    local path = snapshot_file()
    local handle, control = restorer({ snapshot_path = path, map_path = "/dev/null" })
    handle.boot()
    control.advance(60000)
    equal("the restore has ended", handle.is_restoring(), false)
    control.open({ class = "google-chrome", title = "Inbox", mapped = true })
    control.advance(500)
    equal("a late window is left where it opened", #control.dispatches_of("move"), 0)
    os.remove(path)
end

do
    -- Groups are rebuilt once, at the end, so members are not merged into a
    -- group that is still being moved between workspaces.
    local path = temp_path()
    write(path, session_model.serialize({
        version = session_model.VERSION,
        workspaces = {},
        windows = {
            { class = "google-chrome", workspace = 1, title = "a", provider = "chrome",
              group = { id = "g1", index = 0 } },
            { class = "obsidian", workspace = 1, title = "b", provider = "generic",
              group = { id = "g1", index = 1 } },
        },
        shells = {},
    }))
    local handle, control = restorer({ snapshot_path = path, map_path = "/dev/null" })
    handle.boot()
    control.open({ class = "google-chrome", title = "a", mapped = true,
        at = { x = 0, y = 0 }, size = { x = 10, y = 10 } })
    control.open({ class = "obsidian", title = "b", mapped = true,
        at = { x = 20, y = 0 }, size = { x = 10, y = 10 } })
    control.advance(500)

    local function grouped()
        local count = 0
        for _, descriptor in ipairs(control.dispatches_of("move")) do
            if descriptor.args.into_or_create_group then count = count + 1 end
        end
        return count
    end
    equal("no grouping happens while windows are still being placed", grouped(), 0)
    control.advance(60000)
    equal("the group is rebuilt when the restore ends", grouped(), 1)
    os.remove(path)
end

do
    -- A restore that throws while launching must still end. Otherwise
    -- is_restoring() stays true forever: terminal grouping is permanently
    -- suppressed and, worse, the periodic save never runs again, so the next
    -- boot restores an ever-staler snapshot.
    local path = snapshot_file()
    local hl, control = fake_hl({}, {})
    local exploded = false
    hl.exec_cmd = function()
        if not exploded then exploded = true; error("launch refused") end
    end
    local handle = session_restore.new(hl, {
        snapshot_path = path,
        shells_path = "/nonexistent-shells.lua",
        map_path = "/dev/null",
        write_file = function() return true end,
        log = function() end,
    })
    equal("the restore still claims the boot", handle.boot(), true)
    control.advance(60000)
    equal("and a failed launch does not wedge the restore",
        handle.is_restoring(), false)
    os.remove(path)
end

do
    -- Saving reads windows and workspaces from hl, never from hyprctl: a
    -- subprocess asking the compositor a question can only be answered by the
    -- event loop that is blocked waiting for it.
    local written = {}
    local workspace = { id = 6, name = "Notes" }
    local hl, control = fake_hl(
        { { class = "obsidian", title = "Vault", mapped = true, workspace = workspace,
            at = { x = 0, y = 0 }, size = { x = 10, y = 10 } } },
        { workspace })
    local handle = session_restore.new(hl, {
        snapshot_path = temp_path(),
        shells_path = "/nonexistent-shells.lua",
        map_path = "/dev/null",
        write_file = function(_, text) written[#written + 1] = text; return true end,
        log = function() end,
    })
    handle.save()
    equal("a real capture is written", #written, 1)
    local reloaded = assert(load(written[1]))()
    equal("with the workspace name that only the compositor knows",
        reloaded.workspaces[1].name, "Notes")
    equal("and the window", reloaded.windows[1].class, "obsidian")

    for _, command in ipairs(control.executed) do
        check("saving never shells out to hyprctl",
            command:find("hyprctl", 1, true) == nil)
    end

    -- An empty window list means the compositor handed back nothing, which is
    -- far likelier than a genuinely empty desktop.
    local empty_written = {}
    local empty_hl = fake_hl({}, {})
    local empty = session_restore.new(empty_hl, {
        snapshot_path = temp_path(),
        shells_path = "/nonexistent-shells.lua",
        map_path = "/dev/null",
        write_file = function(_, text) empty_written[#empty_written + 1] = text; return true end,
        log = function() end,
    })
    empty.save()
    equal("an empty capture does not overwrite the snapshot", #empty_written, 0)
end

do
    -- The periodic save is armed from hyprland.start, not from new(). Every
    -- other module in this config only registers handlers while the config is
    -- being read; arming a timer there is unproven, and a throw at config load
    -- would take down the whole desktop rather than just this feature.
    --
    -- It also stays shut until the boot restore has settled: firing while
    -- Chrome is still coming up would write a snapshot missing half the
    -- session, and that is what the next boot would read.
    local written = {}
    local workspace = { id = 1, name = "Base" }
    local hl, control = fake_hl(
        { { class = "obsidian", title = "V", mapped = true, workspace = workspace,
            at = { x = 0, y = 0 }, size = { x = 10, y = 10 } } },
        { workspace })
    local path = snapshot_file()
    local handle = session_restore.new(hl, {
        snapshot_path = path,
        shells_path = "/nonexistent-shells.lua",
        map_path = "/dev/null",
        -- Short enough that several ticks land inside the restore's settle
        -- window, which is the case being tested.
        save_interval = 5000,
        write_file = function(_, text) written[#written + 1] = text; return true end,
        log = function() end,
    })
    equal("no timer is armed while the config is loading", #control.timers, 0)
    control.advance(120000)
    equal("and nothing is saved", #written, 0)

    handle.boot()
    control.start()
    control.advance(15000)
    check("the restore is still in flight", handle.is_restoring())
    equal("and no save has landed", #written, 0)

    control.advance(60000)
    check("the first save lands once the restore has settled", #written >= 1)
    local before = #written
    control.advance(6000)
    check("and the timer re-arms itself", #written > before)
    os.remove(path)
end

do
    -- With no snapshot at all, boot() declines and the caller runs its normal
    -- startup set — but saving must still start, or the very first session
    -- after a wipe would never be recorded.
    local written = {}
    local workspace = { id = 1, name = "Base" }
    local hl, control = fake_hl(
        { { class = "obsidian", title = "V", mapped = true, workspace = workspace,
            at = { x = 0, y = 0 }, size = { x = 10, y = 10 } } },
        { workspace })
    local handle = session_restore.new(hl, {
        snapshot_path = "/nonexistent/session.lua",
        shells_path = "/nonexistent-shells.lua",
        map_path = "/dev/null",
        write_file = function(_, text) written[#written + 1] = text; return true end,
        log = function() end,
    })
    equal("boot declines", handle.boot(), false)
    control.start()
    control.advance(31000)
    equal("but the first session is still saved", #written, 1)
end

do
    -- Sightings: a ghostty tab that is visible now is remembered, so that when
    -- it is later backgrounded the snapshot still knows which workspace it
    -- belongs to. Without this, every non-active tab would land on whichever
    -- ghostty window happened to be focused at save time.
    local shells = temp_path()
    write(shells, 'return { { ["pid"] = 4242, ["cwd"] = "/repo", ["command"] = "vim" } }')

    local work = { id = 7, name = "Work" }
    local base = { id = 1, name = "Base" }
    local tagged = { class = session_model.GHOSTTY_CLASS, mapped = true, workspace = work,
        at = { x = 0, y = 0 }, size = { x = 10, y = 10 },
        title = "❯ repo" .. session_model.encode_tag("pid:4242") }

    local written = {}
    local hl, control = fake_hl({ tagged }, { work, base })
    local handle = session_restore.new(hl, {
        snapshot_path = temp_path(),
        shells_path = shells,
        map_path = "/dev/null",
        write_file = function(_, text) written[#written + 1] = text; return true end,
        log = function() end,
    })
    handle.save()
    local first = assert(load(written[1]))()
    equal("a visible tab is attributed exactly", first.shells[1].workspace, 7)
    equal("and recorded as exact", first.shells[1].workspace_source, "title")

    -- Now the same shell is a background tab: no window carries its pid, but
    -- the sighting from the previous save still does.
    control.windows = { { class = session_model.GHOSTTY_CLASS, mapped = true,
        workspace = base, title = "❯ other",
        at = { x = 0, y = 0 }, size = { x = 10, y = 10 } } }
    handle.save()
    local second = assert(load(written[#written]))()
    equal("a backgrounded tab keeps the workspace it was last seen on",
        second.shells[1].workspace, 7)
    equal("and says the answer came from a sighting",
        second.shells[1].workspace_source, "sighting")
    equal("and it can still be addressed, because the name came along",
        second.shells[1].workspace_name, "Work")
    os.remove(shells)
end

local function live_window(class, workspace, title)
    return { class = class, title = title or "W", mapped = true, workspace = workspace,
        at = { x = 0, y = 0 }, size = { x = 10, y = 10 } }
end

do
    -- The periodic save is the only thing keeping the snapshot fresh. A throw
    -- inside one tick has to cost that tick, not every tick after it: the timer
    -- is a oneshot, so a save that dies before re-arming ends the feature for
    -- the rest of the session and the next boot reads an ever-staler snapshot.
    local written = {}
    local workspace = { id = 1, name = "Base" }
    local hl, control = fake_hl({ live_window("obsidian", workspace) }, { workspace })
    local explode = false
    hl.get_windows = function()
        if explode then explode = false; error("the compositor said no") end
        return control.windows
    end
    local handle = session_restore.new(hl, {
        snapshot_path = "/nonexistent/session.lua",
        shells_path = "/nonexistent-shells.lua",
        map_path = "/dev/null",
        save_interval = 5000,
        write_file = function(_, text) written[#written + 1] = text; return true end,
        log = function() end,
    })
    equal("boot declines with no snapshot", handle.boot(), false)
    control.start()

    explode = true
    control.advance(5000)
    equal("a tick that throws writes nothing", #written, 0)
    control.advance(5000)
    equal("and the next tick still saves", #written, 1)
    control.advance(5000)
    equal("and the one after that", #written, 2)
end

do
    -- Claiming the boot makes the caller skip its startup set, so a plan that
    -- launches nothing leaves an empty desktop: a snapshot whose classes are
    -- all absent from session-restore-map.conf plans placements and no
    -- launches, and the windows they wait for are never started.
    local path = temp_path()
    write(path, session_model.serialize({
        version = session_model.VERSION,
        workspaces = {},
        windows = { { class = "mystery", workspace = 1, title = "m", provider = "generic" } },
        shells = {},
    }))
    local handle, control = restorer({ snapshot_path = path, map_path = "/dev/null" })
    equal("a plan with nothing to launch does not claim the boot", handle.boot(), false)
    equal("and starts nothing", #control.launches(), 0)
    check("so suppression stays off", not handle.is_restoring())

    -- The manual re-restore is the opposite case: the windows may be open or
    -- opening already, and placing them is the whole point of the keybind.
    handle.restore()
    check("a manual restore still runs on placements alone", handle.is_restoring())
    os.remove(path)
end

do
    -- Terminals on screen with an empty shell list means the background /proc
    -- walk has not landed yet, not that the terminals are gone. Recording that
    -- would drop every one of them from the next boot.
    local path = temp_path()
    write(path, session_model.serialize({
        version = session_model.VERSION,
        workspaces = {},
        windows = { { class = session_model.GHOSTTY_CLASS, workspace = 3,
            title = "❯ x", provider = "ghostty" } },
        shells = { { pid = 1, cwd = "/repo", command = "vim", workspace = 3 } },
    }))
    local workspace = { id = 3, name = "Work" }

    local written = {}
    local hl = fake_hl({ live_window(session_model.GHOSTTY_CLASS, workspace, "❯ x") },
        { workspace })
    local handle = session_restore.new(hl, {
        snapshot_path = path,
        shells_path = "/nonexistent-shells.lua",
        map_path = "/dev/null",
        write_file = function(_, text) written[#written + 1] = text; return true end,
        log = function() end,
    })
    handle.save()
    local saved = assert(load(written[1]))()
    equal("terminals with no shell list keep the last known shells", #saved.shells, 1)
    equal("with the directory that was recorded", (saved.shells[1] or {}).cwd, "/repo")

    -- No terminals on screen is a different fact: there is nothing to carry.
    local other_written = {}
    local other = session_restore.new(
        fake_hl({ live_window("obsidian", workspace) }, { workspace }), {
            snapshot_path = path,
            shells_path = "/nonexistent-shells.lua",
            map_path = "/dev/null",
            write_file = function(_, text) other_written[#other_written + 1] = text; return true end,
            log = function() end,
        })
    other.save()
    equal("a desktop with no terminals records none",
        #assert(load(other_written[1]))().shells, 0)
    os.remove(path)
end

do
    -- An explicit save while a restore is in flight would capture a half-built
    -- desktop over the snapshot being restored from — the one file that knows
    -- what the session was.
    local path = snapshot_file()
    local written = {}
    local workspace = { id = 1, name = "Base" }
    local hl, control = fake_hl({ live_window("obsidian", workspace) }, { workspace })
    local handle = session_restore.new(hl, {
        snapshot_path = path,
        shells_path = "/nonexistent-shells.lua",
        map_path = "/dev/null",
        write_file = function(_, text) written[#written + 1] = text; return true end,
        log = function() end,
    })
    handle.boot()
    check("the restore is in flight", handle.is_restoring())
    handle.save()
    equal("a save mid-restore writes nothing", #written, 0)

    control.advance(60000)
    handle.save()
    equal("and once the restore has settled it lands", #written, 1)
    os.remove(path)
end

do
    -- Leaving the session: save, then actually leave. The exit has to be
    -- dispatched inside the call — Hyprland invokes a keybind callback with
    -- nresults=0, so a dispatcher merely handed back is discarded and the
    -- desktop saves and then carries on running.
    local workspace = { id = 1, name = "Base" }
    local written, dispatches_at_save = {}, nil
    local hl, control = fake_hl({ live_window("obsidian", workspace) }, { workspace })
    local handle = session_restore.new(hl, {
        snapshot_path = temp_path(),
        shells_path = "/nonexistent-shells.lua",
        map_path = "/dev/null",
        write_file = function(_, text)
            written[#written + 1] = text
            dispatches_at_save = #control.dispatches
            return true
        end,
        log = function() end,
    })
    handle.exit()
    equal("the session is saved on the way out", #written, 1)
    equal("and the compositor is told to exit", #control.dispatches_of("exit"), 1)
    equal("the save comes first", dispatches_at_save, 0)
    check("and it never shells out to do it",
        #control.executed == 0 or not table.concat(control.executed, " "):find("hyprctl"))

    -- A save that throws must not strand the user in a session they asked to
    -- leave; the snapshot is at most one save interval old anyway.
    local broken, broken_control = fake_hl({ live_window("obsidian", workspace) }, { workspace })
    broken.get_windows = function() error("the compositor said no") end
    local leaving = session_restore.new(broken, {
        snapshot_path = temp_path(),
        shells_path = "/nonexistent-shells.lua",
        map_path = "/dev/null",
        write_file = function() return true end,
        log = function() end,
    })
    leaving.exit()
    equal("a save that throws still exits", #broken_control.dispatches_of("exit"), 1)
end

do
    -- The /proc walk must not run while a restore is in flight: it would report
    -- the terminals launched so far as if they were all of them, and a short
    -- but complete-looking list is what every guard downstream trusts.
    local path = snapshot_file()
    local hl, control = fake_hl({}, {})
    local handle = session_restore.new(hl, {
        snapshot_path = path,
        shells_path = "/nonexistent-shells.lua",
        map_path = "/dev/null",
        save_interval = 5000,
        write_file = function() return true end,
        log = function() end,
    })
    handle.boot()
    control.start()

    -- The snapshot and the shell list hold the working directory and full argv
    -- of every foreground process, so the directory they live in is closed to
    -- other users. Taken from the paths in use, not from a fixed one, so a
    -- nested instance protects its own state.
    local secured = false
    for _, command in ipairs(control.executed) do
        if command:find("chmod 700", 1, true)
            and command:find(path:match("^(.*)/[^/]+$"), 1, true)
        then
            secured = true
        end
    end
    check("the state directory is closed to other users at startup", secured)

    control.advance(15000)
    check("the restore is still in flight", handle.is_restoring())
    equal("and no shell walk has been asked for", #control.walks(), 0)

    control.advance(60000)
    check("but it resumes once the restore has settled", #control.walks() >= 1)
    os.remove(path)
end

do
    -- Carrying the previous shell list forward covers a walk that has not
    -- landed yet. It cannot be forever: if hypr-session-shells breaks for good,
    -- an unbounded carry pins the terminals of the last working session into
    -- every snapshot from then on, and the fallback that reopens the ghostty
    -- windows actually in the capture is never reached.
    local path = temp_path()
    write(path, session_model.serialize({
        version = session_model.VERSION,
        workspaces = {},
        windows = { { class = session_model.GHOSTTY_CLASS, workspace = 3,
            title = "❯ x", provider = "ghostty" } },
        shells = { { pid = 1, cwd = "/repo", command = "", workspace = 3 } },
    }))
    local workspace = { id = 3, name = "Work" }
    local hl = fake_hl({ live_window(session_model.GHOSTTY_CLASS, workspace, "❯ x") },
        { workspace })
    -- No write_file: the bound is counted in the snapshot itself, so the file
    -- has to be the one being read back.
    local handle = session_restore.new(hl, {
        snapshot_path = path,
        shells_path = "/nonexistent-shells.lua",
        map_path = "/dev/null",
        log = function() end,
    })
    local function on_disk()
        local handle_in = assert(io.open(path, "r"))
        local text = handle_in:read("a")
        handle_in:close()
        return assert(load(text))()
    end

    for index = 1, 3 do
        handle.save()
        equal(("save %d still carries the shells"):format(index), #on_disk().shells, 1)
    end
    handle.save()
    equal("a walk that never recovers stops pinning them", #on_disk().shells, 0)

    -- And a walk that does recover clears the count rather than counting on.
    local shells = temp_path()
    write(shells, 'return { { ["pid"] = 9, ["cwd"] = "/new", ["command"] = "" } }')
    local recovered = session_restore.new(hl, {
        snapshot_path = path,
        shells_path = shells,
        map_path = "/dev/null",
        log = function() end,
    })
    recovered.save()
    equal("a recovered walk is recorded", #on_disk().shells, 1)
    equal("with the directory it found", on_disk().shells[1].cwd, "/new")
    equal("and no carry count", on_disk().shells_carried, nil)
    os.remove(path)
    os.remove(shells)
end

io.write(("%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
