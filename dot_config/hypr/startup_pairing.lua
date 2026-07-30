-- One-shot startup pairing for applications that should share a tab strip.

local window_model = require("window_model")

local M = {}

function M.new(hl, options)
    options = options or {}
    local browser_class = assert(options.browser_class, "browser_class is required")
    local notes_class = assert(options.notes_class, "notes_class is required")
    local notes_command = options.notes_command or notes_class
    local workspace = tostring(options.workspace or 1)
    local merge_delay = options.merge_delay or 120
    local direction_towards = options.direction_towards or window_model.direction_towards
    local state

    local function find_window(class)
        for _, candidate in ipairs(hl.get_windows() or {}) do
            if candidate.class == class and candidate.mapped then return candidate end
        end
    end

    local function merge(notes)
        local browser = find_window(browser_class)
        if not (browser and notes.mapped and notes.at and notes.size
            and browser.at and browser.size)
        then
            return false
        end

        hl.dispatch(hl.dsp.window.move({
            window = notes,
            into_or_create_group = direction_towards(notes, browser),
        }))
        return true
    end

    hl.on("window.open", function(opened)
        if not (state and opened) then return end

        if state == "waiting-browser" and opened.class == browser_class then
            state = "waiting-notes"
            hl.exec_cmd(notes_command, { workspace = workspace })
        elseif state == "waiting-notes" and opened.class == notes_class then
            state = nil
            hl.timer(function() merge(opened) end, {
                timeout = merge_delay,
                type = "oneshot",
            })
        end
    end)

    return {
        start = function() state = "waiting-browser" end,
        is_waiting = function() return state ~= nil end,
    }
end

return M
