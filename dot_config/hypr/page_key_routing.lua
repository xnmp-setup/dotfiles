-- Pure routing policy for PageUp/PageDown. The config adapter executes the
-- returned actions through Hyprland; keeping the policy here makes the exact
-- eight-row Vicinae contract independently testable.

local M = {}

function M.plan(active, title, marker, page_key, vicinae_direction)
    if active and active.class == "vicinae" then
        local actions = {}
        for _ = 1, 8 do
            actions[#actions + 1] = {
                kind = "shortcut", mods = "", key = vicinae_direction,
            }
        end
        return actions
    end

    if active
        and active.class == "com.mitchellh.ghostty"
        and (title or ""):find(marker, 1, true)
    then
        return { { kind = "shortcut", mods = "CTRL_ALT", key = page_key } }
    end

    return { { kind = "pass" } }
end

return M
