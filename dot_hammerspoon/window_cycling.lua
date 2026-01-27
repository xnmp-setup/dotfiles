---@diagnostic disable: undefined-global
local windowCycling = {}
local autoHide = require("auto_hide")

-- Track last minimized window per app
local lastMinimized = {}

-- Like your AHK CycleOrRun(exe): if 1 window and active -> minimize, else focus; if many -> cycle
function windowCycling.cycleOrRun(appName, launchName, hideBehaviour)
  launchName = launchName or appName
  hideBehaviour = hideBehaviour or "minimize"

  local app = hs.application.get(appName)

  -- if app not running, launch it
  if not app then
    hs.application.launchOrFocus(launchName)
    -- Enable auto-hide if hideBehaviour is "hide"
    if hideBehaviour == "hide" then
      -- Wait for app to launch and then enable auto-hide
      hs.timer.doAfter(0.5, function()
        autoHide.enable(appName)
      end)
    end
    return
  end

  -- If app is hidden, unhide it and focus
  if app:isHidden() then
    app:unhide()
    app:activate()
    -- Enable auto-hide if hideBehaviour is "hide"
    if hideBehaviour == "hide" then
      autoHide.enable(appName)
    end
    return
  end

  -- Get current space
  local currentSpace = hs.spaces.focusedSpace()

  -- Filter to only standard windows on the current space
  -- Note: app:allWindows() sometimes returns 0 for Chrome, so we use a different approach
  local allWins = {}

  -- Try app:allWindows() first
  local appWins = app:allWindows()

  -- If that returns nothing, try getting all windows and filtering by app
  if #appWins == 0 then
    local allSystemWins = hs.window.allWindows()
    for _, w in ipairs(allSystemWins) do
      local winApp = w:application()
      if winApp then
        local winAppName = winApp:name()
        if winAppName == app:name() then
          table.insert(allWins, w)
        end
      end
    end
  else
    allWins = appWins
  end

  local allWinsOnSpace = {}
  for _, w in ipairs(allWins) do
    if w:isStandard() then
      local winSpaces = hs.spaces.windowSpaces(w)
      -- Check if window is on current space
      for _, spaceId in ipairs(winSpaces) do
        if spaceId == currentSpace then
          table.insert(allWinsOnSpace, w)
          break
        end
      end
    end
  end

  -- Get only unminimized windows
  local wins = {}
  for _, w in ipairs(allWinsOnSpace) do
    if not w:isMinimized() then
      table.insert(wins, w)
    end
  end

  -- Sort windows by ID for consistent cycling order
  table.sort(wins, function(a, b) return a:id() < b:id() end)

  -- If no unminimized windows, unminimize the last one that was minimized
  if #wins == 0 then
    -- Build list of all minimized windows (check allWins, not just allWinsOnSpace)
    -- Note: Don't check isStandard() here because minimized windows report isStandard=false
    local allMinimizedWins = {}
    for _, w in ipairs(allWins) do
      if w:isMinimized() then
        table.insert(allMinimizedWins, w)
      end
    end

    if #allMinimizedWins > 0 then
      local winToRestore = nil

      -- Check if we have a last minimized window ID for this app
      if lastMinimized[appName] then
        for _, w in ipairs(allMinimizedWins) do
          if w:id() == lastMinimized[appName] then
            winToRestore = w
            break
          end
        end
      end

      -- If we didn't find it, just pick the last one by ID
      if not winToRestore then
        table.sort(allMinimizedWins, function(a, b) return a:id() < b:id() end)
        winToRestore = allMinimizedWins[#allMinimizedWins]
      end

      winToRestore:unminimize()
      winToRestore:focus()
      -- Enable auto-hide if hideBehaviour is "hide"
      if hideBehaviour == "hide" then
        autoHide.enable(appName)
      end
      return
    end

    -- No minimized windows found, just activate the app
    app:activate()
    -- Enable auto-hide if hideBehaviour is "hide"
    if hideBehaviour == "hide" then
      autoHide.enable(appName)
    end
    return
  end

  local focused = hs.window.focusedWindow()

  -- If only one unminimized window on current space, toggle hide/minimize
  if #wins == 1 then
    if focused and focused:id() == wins[1]:id() then
      lastMinimized[appName] = wins[1]:id()  -- Track last minimized
      if hideBehaviour == "hide" then
        app:hide()
        -- Disable auto-hide when manually hiding
        autoHide.disable(appName)
      else
        wins[1]:minimize()
      end
    else
      wins[1]:focus()
      -- Enable auto-hide if hideBehaviour is "hide"
      if hideBehaviour == "hide" then
        autoHide.enable(appName)
      end
    end
    return
  end

  -- Cycle: pick the next window after the currently focused one (if it's one of them)
  local idx = 1
  if focused then
    for i, w in ipairs(wins) do
      if w:id() == focused:id() then
        idx = (i % #wins) + 1
        break
      end
    end
  end

  wins[idx]:focus()
  -- Enable auto-hide if hideBehaviour is "hide"
  if hideBehaviour == "hide" then
    autoHide.enable(appName)
  end
end

return windowCycling
