---@diagnostic disable: undefined-global
local windowCycling = {}
local autoHide = require("auto_hide")

local lastMinimized = {}


local function getAppWindows(app)
  local wins = app:allWindows()
  if #wins > 0 then return wins end

  -- app:allWindows() sometimes returns 0 for Chrome
  local result = {}
  for _, w in ipairs(hs.window.allWindows()) do
    local winApp = w:application()
    if winApp and winApp:name() == app:name() then
      table.insert(result, w)
    end
  end
  return result
end

local function windowsOnSpace(windows, spaceId)
  local result = {}
  for _, w in ipairs(windows) do
    if w:isStandard() then
      for _, sid in ipairs(hs.spaces.windowSpaces(w)) do
        if sid == spaceId then
          table.insert(result, w)
          break
        end
      end
    end
  end
  return result
end

local function filterMinimized(windows, wantMinimized)
  local result = {}
  for _, w in ipairs(windows) do
    if w:isMinimized() == wantMinimized then
      table.insert(result, w)
    end
  end
  return result
end

local function sortById(windows)
  table.sort(windows, function(a, b) return a:id() < b:id() end)
  return windows
end

local function focusWindow(win, appName, hideOnLoseFocus)
  win:focus()
  if hideOnLoseFocus then autoHide.enable(appName) end
end

local function openNewWindow(app, appName, currentSpace, hideOnLoseFocus)
  local existingIds = {}
  for _, w in ipairs(app:allWindows()) do
    existingIds[w:id()] = true
  end

  hs.eventtap.keyStroke({"cmd"}, "n", 0, app)

  hs.timer.doAfter(0.5, function()
    local newWin = nil
    for _, w in ipairs(app:allWindows()) do
      if w:isStandard() and not existingIds[w:id()] then
        newWin = w
        break
      end
    end

    if newWin then
      local winSpaces = hs.spaces.windowSpaces(newWin)
      if winSpaces and #winSpaces > 0 and winSpaces[1] ~= currentSpace then
        hs.spaces.moveWindowToSpace(newWin, currentSpace)
      end
      hs.timer.doAfter(0.1, function()
        newWin:focus()
      end)
    end
    if hideOnLoseFocus then autoHide.enable(appName) end
  end)
end

function windowCycling.cycleOrRun(appName, launchName, opts)
  launchName = launchName or appName
  opts = opts or {}
  local hideBehaviour = opts.hideBehaviour or "hide"
  local hideOnLoseFocus = opts.hideOnLoseFocus or false
  local multiWorkspace = opts.multiWorkspace or false

  local app = hs.application.get(appName)

  if not app then
    hs.application.launchOrFocus(launchName)
    if hideOnLoseFocus then
      hs.timer.doAfter(0.5, function() autoHide.enable(appName) end)
    end
    return
  end

  if app:isHidden() then
    app:unhide()
    app:activate()
    if hideOnLoseFocus then autoHide.enable(appName) end
    return
  end

  local currentSpace = hs.spaces.focusedSpace()
  local allWins = getAppWindows(app)
  local localWins = windowsOnSpace(allWins, currentSpace)
  local localVisible = sortById(filterMinimized(localWins, false))
  local localMinimized = filterMinimized(localWins, true)

  -- 1. Restore a minimized window on this space
  if #localVisible == 0 and #localMinimized > 0 then
    local winToRestore = nil
    if lastMinimized[appName] then
      for _, w in ipairs(localMinimized) do
        if w:id() == lastMinimized[appName] then
          winToRestore = w
          break
        end
      end
    end
    if not winToRestore then
      winToRestore = sortById(localMinimized)[#localMinimized]
    end
    winToRestore:unminimize()
    focusWindow(winToRestore, appName, hideOnLoseFocus)
    return
  end

  -- 2. No windows at all on this space
  if #localVisible == 0 then
    if multiWorkspace then
      openNewWindow(app, appName, currentSpace, hideOnLoseFocus)
    else
      local otherMinimized = filterMinimized(allWins, true)
      if #otherMinimized > 0 then
        local w = otherMinimized[#otherMinimized]
        w:unminimize()
        focusWindow(w, appName, hideOnLoseFocus)
      else
        local otherVisible = filterMinimized(allWins, false)
        if #otherVisible > 0 then
          focusWindow(otherVisible[1], appName, hideOnLoseFocus)
        else
          app:activate()
          if hideOnLoseFocus then autoHide.enable(appName) end
        end
      end
    end
    return
  end

  -- 3. One window on this space: toggle minimize/hide
  local focused = hs.window.focusedWindow()
  if #localVisible == 1 then
    if focused and focused:id() == localVisible[1]:id() then
      lastMinimized[appName] = localVisible[1]:id()
      if hideBehaviour == "hide" then
        app:hide()
        autoHide.disable(appName)
      else
        localVisible[1]:minimize()
      end
    else
      focusWindow(localVisible[1], appName, hideOnLoseFocus)
    end
    return
  end

  -- 4. Multiple windows: cycle
  local idx = 1
  if focused then
    for i, w in ipairs(localVisible) do
      if w:id() == focused:id() then
        idx = (i % #localVisible) + 1
        break
      end
    end
  end
  focusWindow(localVisible[idx], appName, hideOnLoseFocus)
end

return windowCycling
