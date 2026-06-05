---@diagnostic disable: undefined-global
local windowCycling = {}
local autoHide = require("auto_hide")

-- Track last minimized window per app
local lastMinimized = {}

-- When true, prefer opening a new window on the current workspace rather than
-- switching to a minimized window on another workspace.
windowCycling.multiWorkspace = true

-- Like your AHK CycleOrRun(exe): if 1 window and active -> minimize, else focus; if many -> cycle
function windowCycling.cycleOrRun(appName, launchName, hideBehaviour, hideOnLoseFocus)
  launchName = launchName or appName
  hideBehaviour = hideBehaviour or "minimize"
  if hideOnLoseFocus == nil then hideOnLoseFocus = (hideBehaviour == "hide") end

  local app = hs.application.get(appName)

  -- if app not running, launch it
  if not app then
    hs.application.launchOrFocus(launchName)
    if hideOnLoseFocus then
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
    if hideOnLoseFocus then
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

  -- If no unminimized windows, unminimize the last one that was minimized on this space
  if #wins == 0 then
    local allMinimizedWins = {}
    for _, w in ipairs(allWins) do
      if w:isMinimized() then
        local winSpaces = hs.spaces.windowSpaces(w)
        for _, spaceId in ipairs(winSpaces) do
          if spaceId == currentSpace then
            table.insert(allMinimizedWins, w)
            break
          end
        end
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
      if hideOnLoseFocus then
        autoHide.enable(appName)
      end
      return
    end

    if windowCycling.multiWorkspace then
      -- Open a new window on the current space
      app:activate()
      hs.timer.doAfter(0.1, function()
        hs.eventtap.keyStroke({"cmd"}, "n")
      end)
      if hideOnLoseFocus then
        autoHide.enable(appName)
      end
      return
    end

    -- Non-multiWorkspace: try to unminimize a window on another space
    local otherSpaceMinimized = {}
    for _, w in ipairs(allWins) do
      if w:isMinimized() then
        table.insert(otherSpaceMinimized, w)
      end
    end

    if #otherSpaceMinimized > 0 then
      local winToRestore = otherSpaceMinimized[#otherSpaceMinimized]
      winToRestore:unminimize()
      winToRestore:focus()
      if hideOnLoseFocus then
        autoHide.enable(appName)
      end
      return
    end

    -- Fallback: just activate (switches to other space's open window)
    app:activate()
    if hideOnLoseFocus then
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
        autoHide.disable(appName)
      else
        wins[1]:minimize()
      end
    else
      wins[1]:focus()
      if hideOnLoseFocus then
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
  if hideOnLoseFocus then
    autoHide.enable(appName)
  end
end

return windowCycling
