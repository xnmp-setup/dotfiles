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

-- Size ratios for resize cycling (ordered from smallest to largest)
local SIZE_RATIOS = { 1/3, 1/2, 2/3 }

-- Tolerance for frame comparisons
local TOLERANCE = 5

-- Check if window is flush against left or right edge of screen
-- Returns "left", "right", or nil if not flush
helpers.getFlushSide = withFocusedWindow(function(win)
  local f = win:frame()
  local sf = win:screen():frame()

  local flushLeft = math.abs(f.x - sf.x) <= TOLERANCE
  local flushRight = math.abs((f.x + f.w) - (sf.x + sf.w)) <= TOLERANCE

  if flushLeft and not flushRight then
    return "left"
  elseif flushRight and not flushLeft then
    return "right"
  end
  return nil
end)

-- Determine which side of the screen a window is on (by center position)
helpers.getWindowSide = withFocusedWindow(function(win)
  local f = win:frame()
  local sf = win:screen():frame()
  local winCenter = f.x + (f.w / 2)
  local screenCenter = sf.x + (sf.w / 2)
  return winCenter < screenCenter and "left" or "right"
end)

-- Get the current size ratio of a window (as fraction of screen width)
helpers.getWindowSizeRatio = withFocusedWindow(function(win)
  local f = win:frame()
  local sf = win:screen():frame()
  return f.w / sf.w
end)

-- Find the closest matching size ratio
local function findClosestSizeIndex(ratio)
  local closest = 1
  local minDiff = math.abs(ratio - SIZE_RATIOS[1])
  for i, r in ipairs(SIZE_RATIOS) do
    local diff = math.abs(ratio - r)
    if diff < minDiff then
      minDiff = diff
      closest = i
    end
  end
  return closest
end

-- Get frame for a given side and size ratio
function helpers.getFrameForSideAndSize(win, side, ratio)
  local sf = win:screen():frame()
  if ratio >= 1 then
    return { x = sf.x, y = sf.y, w = sf.w, h = sf.h }
  end
  local x = (side == "left") and sf.x or (sf.x + sf.w * (1 - ratio))
  return { x = x, y = sf.y, w = sf.w * ratio, h = sf.h }
end

-- Logger for debugging
local log = hs.logger.new('helpers', 'debug')

-- Find complement window on the opposite side
function helpers.findComplementWindow(win)
  if not win then
    log.d("findComplementWindow: no window passed")
    return nil
  end

  local screen = win:screen()
  local side = helpers.getWindowSide(win)
  local oppositeSide = (side == "left") and "right" or "left"

  log.df("findComplementWindow: main window '%s' on %s side, looking for window on %s",
    win:application():name(), side, oppositeSide)

  local windows = hs.window.visibleWindows()
  log.df("findComplementWindow: found %d visible windows", #windows)

  for _, w in ipairs(windows) do
    local wApp = w:application()
    local wAppName = wApp and wApp:name() or "unknown"
    local wScreen = w:screen()

    if w:id() == win:id() then
      log.df("  - skipping '%s' (same as main window)", wAppName)
    elseif not wScreen or wScreen:id() ~= screen:id() then
      log.df("  - skipping '%s' (different screen)", wAppName)
    else
      local wSide = helpers.getWindowSide(w)
      log.df("  - checking '%s': side=%s", wAppName, wSide)
      if wSide == oppositeSide then
        log.df("  -> FOUND complement: '%s'", wAppName)
        return w
      end
    end
  end

  -- log.d("findComplementWindow: no complement found")
  return nil
end

-- Find a fullscreen (or near-fullscreen) window on a given screen, excluding a specific window
function helpers.findFullscreenWindowOnScreen(targetScreen, excludeWin)
  local tsf = targetScreen:frame()
  local windows = hs.window.visibleWindows()

  for _, w in ipairs(windows) do
    if (not excludeWin or w:id() ~= excludeWin:id()) and w:screen():id() == targetScreen:id() then
      local f = w:frame()
      -- Check if window is fullscreen (within tolerance)
      local isFullscreen = math.abs(f.x - tsf.x) <= TOLERANCE and
                           math.abs(f.y - tsf.y) <= TOLERANCE and
                           math.abs(f.w - tsf.w) <= TOLERANCE and
                           math.abs(f.h - tsf.h) <= TOLERANCE
      if isFullscreen then
        log.df("findFullscreenWindowOnScreen: found '%s'", w:application():name())
        return w
      end
    end
  end
  return nil
end

-- Move window to the specified side, flip complement if exists
-- If not flush, snap to target side first
-- If already flush on target side, move to adjacent monitor
function helpers.moveToSide(targetSide)
  return withFocusedWindow(function(win)
    local screen = win:screen()
    local sf = screen:frame()
    local flushSide = helpers.getFlushSide(win)
    local ratio = helpers.getWindowSizeRatio(win)

    -- Find complement BEFORE any changes
    local complement = helpers.findComplementWindow(win)
    local complementRatio = complement and helpers.getWindowSizeRatio(complement) or nil

    log.df("moveToSide: targetSide=%s, flushSide=%s, ratio=%.2f, complement=%s",
      targetSide, flushSide or "nil", ratio, complement and "yes" or "nil")

    -- Calculate all frames BEFORE applying any changes
    local winNewFrame, complementNewFrame
    local invaded, invadedNewFrame  -- for invading fullscreen windows on target monitor

    if not flushSide then
      -- Not flush: snap to target side at half width (default)
      log.d("moveToSide: not flush, snapping to target side")
      local snapRatio = 0.5
      local x = (targetSide == "left") and sf.x or (sf.x + sf.w * (1 - snapRatio))
      winNewFrame = { x = x, y = sf.y, w = sf.w * snapRatio, h = sf.h }
    elseif flushSide == targetSide then
      -- Already flush on target side: try to move to adjacent monitor
      local nextScreen = (targetSide == "left") and screen:toWest() or screen:toEast()
      if nextScreen then
        log.d("moveToSide: moving to adjacent monitor")
        local nsf = nextScreen:frame()
        local oppositeSide = (targetSide == "left") and "right" or "left"
        local x = (oppositeSide == "left") and nsf.x or (nsf.x + nsf.w * (1 - ratio))
        winNewFrame = { x = x, y = nsf.y, w = nsf.w * ratio, h = nsf.h }

        -- Complement on original screen takes full screen since main window left
        if complement then
          complementNewFrame = { x = sf.x, y = sf.y, w = sf.w, h = sf.h }
        end

        -- Check for fullscreen window on target monitor to invade
        invaded = helpers.findFullscreenWindowOnScreen(nextScreen, win)
        if invaded then
          log.df("moveToSide: invading fullscreen window '%s'", invaded:application():name())
          -- Invaded window shrinks to the opposite side (becomes complement on new screen)
          local invadedRatio = 1 - ratio
          local ix = (targetSide == "left") and nsf.x or (nsf.x + nsf.w * (1 - invadedRatio))
          invadedNewFrame = { x = ix, y = nsf.y, w = nsf.w * invadedRatio, h = nsf.h }
        end
      end
    else
      -- Flush on opposite side: swap with complement
      log.d("moveToSide: swapping sides with complement")
      local oppositeSide = (targetSide == "left") and "right" or "left"

      -- Main window frame
      local x = (targetSide == "left") and sf.x or (sf.x + sf.w * (1 - ratio))
      winNewFrame = { x = x, y = sf.y, w = sf.w * ratio, h = sf.h }

      -- Complement window frame (swap to opposite side)
      if complement and complementRatio then
        local cx = (oppositeSide == "left") and sf.x or (sf.x + sf.w * (1 - complementRatio))
        complementNewFrame = { x = cx, y = sf.y, w = sf.w * complementRatio, h = sf.h }
      end
    end

    -- Apply all changes (using references from BEFORE move)
    if winNewFrame then
      win:setFrame(winNewFrame)
    end
    if complementNewFrame and complement then
      complement:setFrame(complementNewFrame)
    end
    if invadedNewFrame and invaded then
      invaded:setFrame(invadedNewFrame)
    end
  end)
end

helpers.moveWindowLeft = helpers.moveToSide("left")
helpers.moveWindowRight = helpers.moveToSide("right")

-- Resize window, cycling through SIZE_RATIOS
-- Only works if window is flush to left or right edge
-- direction: 1 for grow, -1 for shrink
function helpers.resizeWindow(direction)
  return withFocusedWindow(function(win)
    local flushSide = helpers.getFlushSide(win)

    -- Only allow resize if window is flush to an edge
    if not flushSide then
      log.d("resizeWindow: window not flush, ignoring")
      return
    end

    local screen = win:screen()
    local sf = screen:frame()
    local complement = helpers.findComplementWindow(win)

    local currentRatio = helpers.getWindowSizeRatio(win)
    local currentIndex = findClosestSizeIndex(currentRatio)

    log.df("resizeWindow: direction=%d, flushSide=%s, currentRatio=%.2f, currentIndex=%d",
      direction, flushSide, currentRatio, currentIndex)

    local newIndex = currentIndex + direction
    if newIndex < 1 then newIndex = 1 end
    if newIndex > #SIZE_RATIOS then newIndex = #SIZE_RATIOS end

    local newRatio = SIZE_RATIOS[newIndex]
    log.df("resizeWindow: newIndex=%d, newRatio=%.2f", newIndex, newRatio)

    -- Calculate all frames BEFORE applying any changes
    local winNewFrame, complementNewFrame

    -- Main window frame (stays flush to same side)
    local x = (flushSide == "left") and sf.x or (sf.x + sf.w * (1 - newRatio))
    winNewFrame = { x = x, y = sf.y, w = sf.w * newRatio, h = sf.h }

    -- Complement window frame (fills remaining space on opposite side)
    if complement then
      local complementSide = (flushSide == "left") and "right" or "left"
      local complementRatio = 1 - newRatio
      local cx = (complementSide == "left") and sf.x or (sf.x + sf.w * (1 - complementRatio))
      complementNewFrame = { x = cx, y = sf.y, w = sf.w * complementRatio, h = sf.h }
      log.df("resizeWindow: complement will resize to %.2f on %s", complementRatio, complementSide)
    end

    -- Apply all changes
    win:setFrame(winNewFrame)
    if complementNewFrame and complement then
      complement:setFrame(complementNewFrame)
    end
  end)
end

helpers.growWindow = helpers.resizeWindow(1)
helpers.shrinkWindow = helpers.resizeWindow(-1)

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
