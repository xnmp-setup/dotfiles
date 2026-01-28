---@diagnostic disable: undefined-global
local helpers = {}

-- Wrapper function that handles window parameter boilerplate
local function withFocusedWindow(fn)
  return function(win)
    win = win or hs.window.focusedWindow()
    if not win then return nil end
    return fn(win)
  end
end

function helpers.framesEqual(frame1, frame2, tolerance)
  tolerance = tolerance or 5
  return (math.abs(frame1.x - frame2.x) <= tolerance and
          math.abs(frame1.y - frame2.y) <= tolerance and
          math.abs(frame1.w - frame2.w) <= tolerance and
          math.abs(frame1.h - frame2.h) <= tolerance)
end

helpers.isMaximized = withFocusedWindow(function(win)
  return helpers.framesEqual(win:frame(), win:screen():frame())
end)

function helpers.snap(win, x, y, w, h)
  if not win then return end
  local sf = win:screen():frame()
  win:setFrame({
    x = sf.x + (sf.w * x),
    y = sf.y + (sf.h * y),
    w = sf.w * w,
    h = sf.h * h
  })
end

helpers.getTopCenterFrame = withFocusedWindow(function(win)
  local sf = win:screen():frame()
  local aspect = sf.w / sf.h
  local targetW = (aspect > 2.0) and 0.50 or 0.75
  local targetX = (1.0 - targetW) / 2.0

  return {
    x = sf.x + (sf.w * targetX),
    y = sf.y,
    w = sf.w * targetW,
    h = sf.h * 0.80
  }
end)

helpers.getLeftHalfFrame = withFocusedWindow(function(win)
  local sf = win:screen():frame()
  return {
    x = sf.x,
    y = sf.y,
    w = sf.w * 0.5,
    h = sf.h
  }
end)

helpers.getRightHalfFrame = withFocusedWindow(function(win)
  local sf = win:screen():frame()
  return {
    x = sf.x + (sf.w * 0.5),
    y = sf.y,
    w = sf.w * 0.5,
    h = sf.h
  }
end)

helpers.getLeftThirdFrame = withFocusedWindow(function(win)
  local sf = win:screen():frame()
  return {
    x = sf.x,
    y = sf.y,
    w = sf.w * (1/3),
    h = sf.h
  }
end)

helpers.getMiddleThirdFrame = withFocusedWindow(function(win)
  local sf = win:screen():frame()
  return {
    x = sf.x + (sf.w * (1/3)),
    y = sf.y,
    w = sf.w * (1/3),
    h = sf.h
  }
end)

helpers.getRightThirdFrame = withFocusedWindow(function(win)
  local sf = win:screen():frame()
  return {
    x = sf.x + (sf.w * (2/3)),
    y = sf.y,
    w = sf.w * (1/3),
    h = sf.h
  }
end)

helpers.getLeftTwoThirdsFrame = withFocusedWindow(function(win)
  local sf = win:screen():frame()
  return {
    x = sf.x,
    y = sf.y,
    w = sf.w * (2/3),
    h = sf.h
  }
end)

helpers.getRightTwoThirdsFrame = withFocusedWindow(function(win)
  local sf = win:screen():frame()
  return {
    x = sf.x + (sf.w * (1/3)),
    y = sf.y,
    w = sf.w * (2/3),
    h = sf.h
  }
end)

-- Detect current window state
helpers.getCurrentState = withFocusedWindow(function(win)
  local f = win:frame()

  if helpers.framesEqual(f, helpers.getLeftThirdFrame(win)) then
    return "left_third"
  elseif helpers.framesEqual(f, helpers.getLeftHalfFrame(win)) then
    return "left_half"
  elseif helpers.framesEqual(f, helpers.getLeftTwoThirdsFrame(win)) then
    return "left_two_thirds"
  elseif helpers.framesEqual(f, helpers.getRightTwoThirdsFrame(win)) then
    return "right_two_thirds"
  elseif helpers.framesEqual(f, helpers.getRightHalfFrame(win)) then
    return "right_half"
  elseif helpers.framesEqual(f, helpers.getRightThirdFrame(win)) then
    return "right_third"
  end

  return nil
end)

-- Find a window in a specific region (frame)
function helpers.findWindowInRegion(targetFrame, excludeWin)
  excludeWin = excludeWin or hs.window.focusedWindow()
  if not excludeWin then return nil end

  local screen = excludeWin:screen()
  local windows = hs.window.visibleWindows()

  for _, win in ipairs(windows) do
    if win:id() ~= excludeWin:id() and win:screen():id() == screen:id() then
      if helpers.framesEqual(win:frame(), targetFrame) then
        return win
      end
    end
  end

  return nil
end

function helpers.moveFocused(frame)
  withFocusedWindow(function(win) win:setFrame(frame) end)()
end

-- Move window left in the state machine
helpers.moveLeft = withFocusedWindow(function(win)
  local state = helpers.getCurrentState(win)

  if state == "left_third" then
    -- Try to move to the monitor on the left
    local leftScreen = win:screen():toWest()
    if leftScreen then
      local sf = leftScreen:frame()
      win:setFrame({
        x = sf.x + (sf.w * (2/3)),
        y = sf.y,
        w = sf.w * (1/3),
        h = sf.h
      })
    end
    return
  elseif state == "left_half" then
    -- Move to left_third, check for window in right_half to expand to right_two_thirds
    win:setFrame(helpers.getLeftThirdFrame(win))
    local rightHalfWin = helpers.findWindowInRegion(helpers.getRightHalfFrame(win), win)
    if rightHalfWin then
      rightHalfWin:setFrame(helpers.getRightTwoThirdsFrame(rightHalfWin))
    end
  elseif state == "left_two_thirds" then
    -- Move to left_half, check for window in right_third to expand to right_half
    win:setFrame(helpers.getLeftHalfFrame(win))
    local rightThirdWin = helpers.findWindowInRegion(helpers.getRightThirdFrame(win), win)
    if rightThirdWin then
      rightThirdWin:setFrame(helpers.getRightHalfFrame(rightThirdWin))
    end
  elseif state == "right_two_thirds" then
    -- Move to left_two_thirds, check for window in left_third to move to right_third
    win:setFrame(helpers.getLeftTwoThirdsFrame(win))
    local leftThirdWin = helpers.findWindowInRegion(helpers.getLeftThirdFrame(win), win)
    if leftThirdWin then
      leftThirdWin:setFrame(helpers.getRightThirdFrame(leftThirdWin))
    end
  elseif state == "right_half" then
    -- Move to right_two_thirds, check for window in left_half to reduce to left_third
    win:setFrame(helpers.getRightTwoThirdsFrame(win))
    local leftHalfWin = helpers.findWindowInRegion(helpers.getLeftHalfFrame(win), win)
    if leftHalfWin then
      leftHalfWin:setFrame(helpers.getLeftThirdFrame(leftHalfWin))
    end
  elseif state == "right_third" then
    -- Move to right_half, check for window in left_two_thirds to reduce to left_half
    win:setFrame(helpers.getRightHalfFrame(win))
    local leftTwoThirdsWin = helpers.findWindowInRegion(helpers.getLeftTwoThirdsFrame(win), win)
    if leftTwoThirdsWin then
      leftTwoThirdsWin:setFrame(helpers.getLeftHalfFrame(leftTwoThirdsWin))
    end
  else
    -- Not in a known state, move to left_half as default
    win:setFrame(helpers.getLeftHalfFrame(win))
  end
end)

-- Move window right in the state machine
helpers.moveRight = withFocusedWindow(function(win)
  local state = helpers.getCurrentState(win)

  if state == "left_third" then
    -- Move to left_half, check for window in right_two_thirds to reduce to right_half
    win:setFrame(helpers.getLeftHalfFrame(win))
    local rightTwoThirdsWin = helpers.findWindowInRegion(helpers.getRightTwoThirdsFrame(win), win)
    if rightTwoThirdsWin then
      rightTwoThirdsWin:setFrame(helpers.getRightHalfFrame(rightTwoThirdsWin))
    end
  elseif state == "left_half" then
    -- Move to left_two_thirds, check for window in right_half to reduce to right_third
    win:setFrame(helpers.getLeftTwoThirdsFrame(win))
    local rightHalfWin = helpers.findWindowInRegion(helpers.getRightHalfFrame(win), win)
    if rightHalfWin then
      rightHalfWin:setFrame(helpers.getRightThirdFrame(rightHalfWin))
    end
  elseif state == "left_two_thirds" then
    -- Move to right_two_thirds, check for window in right_third to move to left_third
    win:setFrame(helpers.getRightTwoThirdsFrame(win))
    local rightThirdWin = helpers.findWindowInRegion(helpers.getRightThirdFrame(win), win)
    if rightThirdWin then
      rightThirdWin:setFrame(helpers.getLeftThirdFrame(rightThirdWin))
    end
  elseif state == "right_two_thirds" then
    -- Move to right_half, check for window in left_third to expand to left_half
    win:setFrame(helpers.getRightHalfFrame(win))
    local leftThirdWin = helpers.findWindowInRegion(helpers.getLeftThirdFrame(win), win)
    if leftThirdWin then
      leftThirdWin:setFrame(helpers.getLeftHalfFrame(leftThirdWin))
    end
  elseif state == "right_half" then
    -- Move to right_third, check for window in left_half to expand to left_two_thirds
    win:setFrame(helpers.getRightThirdFrame(win))
    local leftHalfWin = helpers.findWindowInRegion(helpers.getLeftHalfFrame(win), win)
    if leftHalfWin then
      leftHalfWin:setFrame(helpers.getLeftTwoThirdsFrame(leftHalfWin))
    end
  elseif state == "right_third" then
    -- Try to move to the monitor on the right
    local rightScreen = win:screen():toEast()
    if rightScreen then
      local sf = rightScreen:frame()
      win:setFrame({
        x = sf.x,
        y = sf.y,
        w = sf.w * (1/3),
        h = sf.h
      })
    end
    return
  else
    -- Not in a known state, move to right_half as default
    win:setFrame(helpers.getRightHalfFrame(win))
  end
end)

-- "Win+Up": toggle between top-center and maximized
helpers.toggleTopCenterMaximize = withFocusedWindow(function(win)
  local centerFrame = helpers.getTopCenterFrame(win)

  -- If maximized, restore to top-center
  if helpers.isMaximized(win) then
    win:setFrame(centerFrame)
    return
  end

  -- Check if already in top-center (within 5 pixels tolerance)
  local f = win:frame()
  local isTopCenter = helpers.framesEqual(f, centerFrame)

  if isTopCenter then
    win:maximize()
  else
    win:setFrame(centerFrame)
  end
end)

function helpers.toggleDesktop()
  local screen = hs.screen.mainScreen():getUUID()
  local spaces = hs.spaces.allSpaces()[screen]

  if not spaces or #spaces < 2 then
    hs.alert.show("Need at least 2 desktops")
    return
  end

  local currentSpace = hs.spaces.focusedSpace()

  -- If on space 1, press Ctrl+2; if on space 2, press Ctrl+1
  if currentSpace == spaces[1] then
    hs.eventtap.keyStroke({"cmd"}, "2")
  elseif currentSpace == spaces[2] then
    hs.eventtap.keyStroke({"cmd"}, "1")
  else
    -- If on any other space, go to space 1
    hs.eventtap.keyStroke({"cmd"}, "1")
  end
end

-- Bind a sequence of keys with timeout
-- Example: helpers.bindSequence({"alt"}, {"M", "E"}, 0.5, function() ... end, function() return true end)
-- condition: optional function that returns true if sequence should be active
function helpers.bindSequence(modifiers, keys, timeout, callback, condition)
  if #keys < 2 then
    error("bindSequence requires at least 2 keys in sequence")
  end

  local modal = nil
  local timer = nil
  local firstKey = keys[1]

  hs.hotkey.bind(modifiers, firstKey, function()
    -- Check condition before activating sequence
    if condition and not condition() then
      -- Pass through the key to the application
      hs.eventtap.keyStroke(modifiers, firstKey, 0)
      return
    end

    -- Cancel existing timer if first key is pressed again
    if timer then
      timer:stop()
      timer = nil
    end

    -- Create modal for subsequent keys
    if not modal then
      modal = hs.hotkey.modal.new()

      -- Bind all subsequent keys in the sequence
      for i = 2, #keys do
        local isLastKey = (i == #keys)
        local key = keys[i]

        modal:bind({}, key, function()
          modal:exit()
          if timer then
            timer:stop()
            timer = nil
          end

          if isLastKey then
            callback()
          end
        end)
      end
    end

    modal:enter()

    -- Set timeout
    timer = hs.timer.doAfter(timeout, function()
      if modal then
        modal:exit()
      end
      timer = nil
    end)
  end)
end

return helpers
