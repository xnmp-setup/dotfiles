-- Create an event tap for key events
local keyWatcher = hs.eventtap.new(
    { 
        hs.eventtap.event.types.keyDown,
        hs.eventtap.event.types.keyUp,
        hs.eventtap.event.types.flagsChanged 
    }, 
    function(event)
        local eventType = event:getType()
        local flags = event:getFlags()
        local keyCode = event:getKeyCode()
        
        print("KeyTap")
        print(eventType)
        print(hs.eventtap.event.types.keyDown)
        
        -- Skip if we're in VS Code or iTerm2
        local currentApp = hs.application.frontmostApplication()
        if currentApp:name() == "Code" or currentApp:name() == "iTerm2" or currentApp:name() == "Cursor" then
            return false
        end
        
        -- Only process keyDown events for the actual shortcuts
        if eventType == hs.eventtap.event.types.keyDown then
            print("keydown")
            -- Alt (Option) to Ctrl mappings
            if flags.alt and not flags.cmd then
                if keyCode == hs.keycodes.map["c"] then
                    hs.eventtap.keyStroke({"ctrl"}, "c", 0)
                    return true
                end
            end
            
            -- highlight to beginning/end of line
            if flags.shift then
                if keyCode == hs.keycodes.map["home"] then
                    hs.eventtap.keyStroke({"ctrl", "shift"}, "a", 0)
                    return true
                elseif keyCode == hs.keycodes.map["end"] then
                    hs.eventtap.keyStroke({"ctrl", "shift"}, "e", 0)
                    return true
                end
            end
            
            -- Command (CTRL) + All shortcuts
            if flags.cmd then
                if keyCode == hs.keycodes.map["left"] then
                    if flags.shift then
                        hs.eventtap.keyStroke({"alt", "shift"}, "left", 0)
                    else
                        hs.eventtap.keyStroke({"alt"}, "left", 0)
                    end
                    return true
                elseif keyCode == hs.keycodes.map["right"] then
                    if flags.shift then
                        hs.eventtap.keyStroke({"alt", "shift"}, "right", 0)
                    else
                        hs.eventtap.keyStroke({"alt"}, "right", 0)
                    end
                    return true
                elseif keyCode == hs.keycodes.map["delete"] then
                    hs.eventtap.keyStroke({"alt"}, "delete", 0)
                    return true
                elseif keyCode == hs.keycodes.map["forwarddelete"] then
                    hs.eventtap.keyStroke({"alt"}, "forwarddelete", 0)
                    return true
                elseif keyCode == hs.keycodes.map["home"] then
                    if flags.shift then
                        hs.eventtap.keyStroke({"ctrl", "shift"}, "up", 0)
                    end
                    return true
                elseif keyCode == hs.keycodes.map["end"] then
                    if flags.shift then
                        hs.eventtap.keyStroke({"ctrl", "shift"}, "down", 0)
                    end
                    return true
                end
            end
            
            -- go to beginning/end of line
            if keyCode == hs.keycodes.map["home"] then
                hs.eventtap.keyStroke({"ctrl"}, "a", 0)
                return true
            elseif keyCode == hs.keycodes.map["end"] then
                hs.eventtap.keyStroke({"ctrl"}, "e", 0)
                return true
            end
            
        end
        
        return false
    end
)

-- Auto reload configuration when the file changes
function reloadConfig(files)
    for _,file in pairs(files) do
        if file:sub(-4) == ".lua" then
            hs.reload()
            return
        end
    end
end

-- Watch for config file changes
local pathwatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/", reloadConfig):start()

-- Add a manual reload shortcut
hs.hotkey.bind({"cmd", "alt"}, "R", function()
    hs.reload()
end)

-- Add a watchdog timer to ensure eventtap stays active
local function checkEventTap()
    if not keyWatcher:isEnabled() then
        print("EventTap was disabled, restarting...")
        keyWatcher:start()
    end
end

-- Check every 60 seconds if the eventtap is still active
hs.timer.doEvery(60, checkEventTap)

-- Start watching for events
keyWatcher:start()

-- Notification when config is loaded
hs.notify.new({title="Hammerspoon", informativeText="Config loaded"}):send()
