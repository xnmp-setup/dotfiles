---@diagnostic disable: undefined-global
local autoHide = {}

-- Track apps that should auto-hide on focus loss
local trackedApps = {}

-- Window filter to watch for focus changes
local windowFilter = hs.window.filter.new()
windowFilter:subscribe(hs.window.filter.windowFocused, function(window)
  -- Check all tracked apps
  for trackedAppName, _ in pairs(trackedApps) do
    local app = hs.application.get(trackedAppName)
    if app and not app:isHidden() then
      -- If the newly focused window is not from this tracked app, hide it
      local focusedApp = window and window:application()
      if not focusedApp or focusedApp:name() ~= trackedAppName then
        app:hide()
        trackedApps[trackedAppName] = nil
      end
    end
  end
end)

-- Enable auto-hide for an app
function autoHide.enable(appName)
  trackedApps[appName] = true
end

-- Disable auto-hide for an app
function autoHide.disable(appName)
  trackedApps[appName] = nil
end

return autoHide
