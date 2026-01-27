---@diagnostic disable: undefined-global
local dropdownTerminal = {}
local autoHide = require("auto_hide")

local APP_NAME = "Ghostty"
local terminalWindow = nil

-- Get dropdown terminal frame (smaller top-center position)
local function getDropdownFrame()
  local screen = hs.screen.mainScreen():frame()
  local aspect = screen.w / screen.h
  local targetW = (aspect > 2.0) and 0.40 or 0.60  -- Slightly smaller than normal top-center
  local targetX = (1.0 - targetW) / 2.0

  return {
    x = screen.x + (screen.w * targetX),
    y = screen.y,
    w = screen.w * targetW,
    h = screen.h * 0.75  -- Smaller height too (65% instead of 80%)
  }
end

-- Note: To hide Ghostty from dock, add to ~/.config/ghostty/config:
--   macos-hidden = always

function dropdownTerminal.toggle()
  local app = hs.application.find(APP_NAME)

  -- Launch if not running
  if not app then
    hs.application.launchOrFocus(APP_NAME)
    -- Wait for app to launch and then position it
    hs.timer.doAfter(0.5, function()
      dropdownTerminal.toggle()
    end)
    return
  end

  -- Get or find the terminal window
  local wins = app:allWindows()
  if not wins then
    -- App not fully initialized yet, try again
    hs.timer.doAfter(0.2, function()
      dropdownTerminal.toggle()
    end)
    return
  end
  if #wins == 0 then
    -- No windows, create one and wait for it
    app:activate()
    hs.timer.doAfter(0.3, function()
      hs.eventtap.keyStroke({"cmd"}, "n")
      hs.timer.doAfter(0.5, function()
        dropdownTerminal.toggle()
      end)
    end)
    return
  end

  -- Use the first window as the dropdown terminal
  terminalWindow = wins[1]

  -- Get current space
  local currentSpace = hs.spaces.focusedSpace()
  local winSpaces = hs.spaces.windowSpaces(terminalWindow)

  -- Check if window is visible and focused
  local focusedWin = hs.window.focusedWindow()
  local isVisible = not app:isHidden() and not terminalWindow:isMinimized()
  local isFocused = focusedWin and focusedWin:id() == terminalWindow:id()

  if isVisible and isFocused then
    -- Hide the terminal
    app:hide()
    autoHide.disable(APP_NAME)
  else
    -- Show the terminal
    -- Move to current space if not already there
    if winSpaces and #winSpaces > 0 and winSpaces[1] ~= currentSpace then
      hs.spaces.moveWindowToSpace(terminalWindow, currentSpace)
    end

    -- Unhide first if hidden (before positioning)
    if app:isHidden() then
      app:unhide()
    end
    if terminalWindow:isMinimized() then
      terminalWindow:unminimize()
    end

    -- Position at dropdown location (do this after unhiding)
    terminalWindow:setFrame(getDropdownFrame())

    -- Focus
    terminalWindow:focus()

    -- Enable auto-hide on focus loss
    autoHide.enable(APP_NAME)
  end
end

return dropdownTerminal
