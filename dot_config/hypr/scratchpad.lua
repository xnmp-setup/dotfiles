-- scratchpad.lua — drop-down windows for Hyprland's Lua config.
--
-- A scratchpad is one window parked in a special workspace and toggled over the
-- current workspace, so the same key summons it wherever you are and dismisses
-- it again. Hyprland's special-workspace compositor path blurs and dims
-- everything behind it, and it hides itself the moment focus goes elsewhere.
--
-- This was two bash scripts (toggle-scratchpad.sh, scratchpad-autohide.sh)
-- driving `hyprctl dispatch` and `hyprctl keyword`, tailing the event socket
-- through socat and passing window addresses between them in /tmp files. None of
-- that survives a Lua config: `hyprctl dispatch` now parses Lua, and
-- `hyprctl keyword` is refused outright ("can't work with non-legacy parsers"),
-- so both scripts failed on their first line. In here a window handle is just a
-- value, focus is an event, and the /tmp files have nothing left to carry.

local function new(hl, window_actions)
    local M = {}

    -- name -> { class, cmd, w, h, x, y }
    local pads = {}
    -- name -> address of the window claimed for it
    local live = {}
    -- class -> name, while a launch is in flight and its window has yet to appear
    local pending = {}
    -- name -> true once the summoned window has actually held focus.
    --
    -- Autohide cannot simply be "this is not the active window": between unparking a
    -- scratchpad and focus arriving on it there is a window of exactly that shape,
    -- and hiding then would dismiss it as it appeared. Suppressing on a timer only
    -- moves the race, so instead a scratchpad becomes eligible to autohide by having
    -- been focused — a state it reaches by observation rather than by clock.
    local focused_once = {}
    -- name -> address that held focus immediately before the scratchpad was shown.
    -- Keeping the exact window matters for groups: an arbitrary workspace fallback
    -- may be a hidden member and would switch the visible tab on dismissal.
    local return_focus = {}
    -- name -> ordinary workspace underneath the scratchpad on its latest showing.
    -- Keep this after hiding: a child window can map on the special workspace just
    -- before the focus event dismisses it, then ask for its destination afterwards.
    local host_workspace = {}

    --------------------------------------------------------------------------------
    -- Window handles
    --------------------------------------------------------------------------------

    -- Addresses, not window objects: a handle held across events can outlive the
    -- window it names, and a stale address simply fails to resolve.
    local function window_at(address)
        if not address then return nil end
        for _, w in ipairs(hl.get_windows() or {}) do
            if w.address == address then return w end
        end
        return nil
    end

    local function window_for(name)
        local w = window_at(live[name])
        if not w then live[name] = nil end
        return w
    end

    -- A shown special workspace has the same negative ID on its window and monitor.
    -- Comparing IDs also avoids coupling visibility to a particular workspace name.
    local function is_shown(w)
        local workspace = w and w.workspace
        if not (workspace and workspace.id) then return false end

        for _, m in ipairs(hl.get_monitors() or {}) do
            local special = m.active_special_workspace
            if special and special.id == workspace.id then return true end
        end
        return false
    end

    -- A `hyprctl reload` re-runs this config from scratch, so the table of claimed
    -- windows is gone while the windows themselves are still parked exactly where it
    -- left them. The special workspace is the record: nothing else puts a window
    -- there, so anything sitting in one can be taken back without ambiguity.
    local function reclaim(name)
        for _, w in ipairs(hl.get_windows() or {}) do
            local ws = w.workspace and w.workspace.name
            if ws == "special:" .. name then
                live[name] = w.address
                return w
            end
        end
    end

    local function claimed(address)
        for _, held in pairs(live) do
            if held == address then return true end
        end
        return false
    end

    local function declared_workspace_name(w)
        local workspace_name = w.workspace and w.workspace.name
        local name = workspace_name
            and workspace_name:match("^special:(.+)$")
        return name and pads[name] and name or nil
    end

    local function scratchpad_name(w)
        if not w then return nil end

        for name, address in pairs(live) do
            if address == w.address then return name end
        end

        local name = declared_workspace_name(w)
        local pad = name and pads[name]
        return pad and w.class == pad.class and name or nil
    end

    --------------------------------------------------------------------------------
    -- Showing and hiding
    --------------------------------------------------------------------------------

    -- The ordinary workspace in front of the user. NOT hl.get_active_workspace():
    -- while a scratchpad is up, focus is on a window that came out of a special
    -- workspace, and Hyprland reports that special workspace as the active one — so
    -- asking it where to put things back gives the answer "where they already are".
    -- The monitor tracks the two separately.
    local function visible_workspace()
        local mon = hl.get_active_monitor()
        local ws  = mon and mon.active_workspace
        if ws and ws.id then return ws end
        return hl.get_active_workspace()
    end

    local function workspace_under(name, w)
        local workspace = w and w.workspace
        for _, monitor in ipairs(hl.get_monitors() or {}) do
            local special = monitor.active_special_workspace
            if workspace and special and special.id == workspace.id
                and monitor.active_workspace
            then
                host_workspace[name] = monitor.active_workspace
                return monitor.active_workspace
            end
        end

        return host_workspace[name]
    end

    local function place(name, w)
        local pad = pads[name]

        hl.dispatch(hl.dsp.window.float({ action = "on", window = w }))
        hl.dispatch(hl.dsp.window.resize({ x = pad.w, y = pad.h, window = w }))

        if pad.x and pad.y then
            hl.dispatch(hl.dsp.window.move({ x = pad.x, y = pad.y, window = w }))
        else
            hl.dispatch(hl.dsp.focus({ window = w }))
            hl.dispatch(hl.dsp.window.center())
        end
        hl.dispatch(hl.dsp.focus({ window = w }))
    end

    local function show(name, w)
        focused_once[name] = nil
        host_workspace[name] = visible_workspace()
        hl.dispatch(hl.dsp.window.move({
            workspace = "special:" .. name,
            silent = true,
            window = w,
        }))
        if not is_shown(w) then
            hl.dispatch(hl.dsp.workspace.toggle_special(name))
        end
        place(name, w)
    end

    -- Something on the visible workspace to hand focus to, that is not itself a
    -- scratchpad on its way out.
    local function focus_fallback(leaving)
        local ws = visible_workspace()
        if not (ws and ws.id) then return nil end

        for _, window in ipairs(hl.get_windows() or {}) do
            local candidate = window.group and window.group.current or window
            if candidate.mapped and candidate.address ~= leaving
                and candidate.workspace and candidate.workspace.id == ws.id
                and not claimed(candidate.address)
            then
                return candidate
            end
        end
    end

    local function remember_return(name)
        local active = hl.get_active_window()
        return_focus[name] = active and not claimed(active.address)
            and active.address or nil
    end

    -- `next_focus` is where focus should end up. Parking a window leaves Hyprland's
    -- focus ON it, so without this the keyboard would still be pointed at a terminal
    -- that is no longer on screen — dismissing a scratchpad would swallow whatever
    -- was typed next.
    local function hide(name, w, next_focus)
        focused_once[name] = nil

        local restore = next_focus
            or window_at(return_focus[name])
            or focus_fallback(w.address)
        return_focus[name] = nil

        if is_shown(w) then
            hl.dispatch(hl.dsp.workspace.toggle_special(name))
        end
        window_actions.focus_exact(restore)
    end

    -- A freshly launched window is floated and sized by the exec rules, but it still
    -- has to be positioned, and it is not reliably addressable the instant it opens.
    local function adopt(name, w)
        live[name] = w.address
        hl.timer(function()
            local win = window_for(name)
            if win then
                show(name, win)
            end
        end, { timeout = 80, type = "oneshot" })
    end

    --------------------------------------------------------------------------------
    -- Public API
    --------------------------------------------------------------------------------

    --- Declare a scratchpad. `x`/`y` are optional; without them it is centred.
    --- @param name string   also the special workspace it is parked in
    --- @param spec table    { class, cmd, w, h, x?, y?, isolate? }
    function M.define(name, spec)
        pads[name] = spec
    end

    --- Whether a window belongs to one of the declared scratchpads.
    ---
    --- The workspace check recovers ownership after a config reload, before the
    --- first toggle has had a chance to reclaim the window into `live`.
    function M.is_scratchpad(w)
        return scratchpad_name(w) ~= nil
    end

    -- An isolated scratchpad owns its special workspace outright. Applications
    -- opened from it inherit that workspace from Hyprland, so move any unclaimed
    -- window straight onto the ordinary workspace underneath.
    local function redirect_foreign_window(w)
        if not (w and w.mapped) or claimed(w.address) then return end

        local name = declared_workspace_name(w)
        local pad = name and pads[name]
        if not (pad and pad.isolate) then return end

        local destination = workspace_under(name, w)
        if not (destination and destination.id and destination.id > 0) then
            return
        end

        hl.dispatch(hl.dsp.window.move({
            workspace = tostring(destination.id),
            follow = true,
            window = w,
        }))
    end

    --- Summon the named scratchpad, or dismiss it if it is already up.
    function M.toggle(name)
        local pad = pads[name]
        if not pad then return end

        local w = window_for(name) or reclaim(name)
        if not w then
            -- Nothing to toggle yet. Rules do the floating and sizing so the window
            -- never flashes tiled at its natural size first.
            remember_return(name)
            pending[pad.class] = name
            hl.dispatch(hl.dsp.exec_cmd(pad.cmd, { float = true, size = { pad.w, pad.h } }))
        elseif is_shown(w) then
            hide(name, w)
        else
            remember_return(name)
            show(name, w)
        end
    end

    --------------------------------------------------------------------------------
    -- Events
    --------------------------------------------------------------------------------

    -- Claim a launched window. Both events matter: Electron and Chromium windows map
    -- with a placeholder class and are renamed a frame later, so window.open alone
    -- would miss them and window.class alone would miss everything else.
    local function claim(w)
        if not (w and w.class) then return end
        local name = pending[w.class]
        if not name or claimed(w.address) then return end
        pending[w.class] = nil
        adopt(name, w)
    end

    hl.on("window.open", function(w)
        claim(w)
        redirect_foreign_window(w)
    end)
    hl.on("window.class", claim)

    -- Any scratchpad that is up and is not what the user just focused goes away.
    hl.on("window.active", function()
        local active = hl.get_active_window()
        local address = active and active.address

        for name in pairs(live) do
            local w = window_for(name)
            if w and is_shown(w) then
                if w.address == address then
                    focused_once[name] = true
                elseif focused_once[name] then
                    -- Focus goes back to whatever the user just picked, which is the
                    -- very thing parking would otherwise take it away from.
                    hide(name, w, active)
                end
            end
        end
    end)

    -- Closing a scratchpad releases the name, so the next press launches a new one.
    hl.on("window.close", function(w)
        local address = w and w.address
        if not address then return end
        for name, held in pairs(live) do
            if held == address then
                live[name] = nil
                host_workspace[name] = nil
            end
        end
    end)

    return M
end

return { new = new }
