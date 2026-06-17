---@diagnostic disable: undefined-global
hs.window.animationDuration = 0
require("hs.ipc").cliInstall()

local helpers = require("helpers")
local windowCycling = require("window_cycling")
-- ---------- App cycling like your F-keys ----------
hs.hotkey.bind({}, "F9", function() windowCycling.cycleOrRun("WezTerm", "WezTerm") end)
hs.hotkey.bind({}, "F7", function() windowCycling.cycleOrRun("Google Chrome", "Google Chrome", { multiWorkspace = true }) end)
hs.hotkey.bind({}, "F6", function() windowCycling.cycleOrRun("Google Chrome", "Google Chrome", { multiWorkspace = true }) end)
-- hs.hotkey.bind({}, "F5", function() windowCycling.cycleOrRun("Arc", "Arc") end)
hs.hotkey.bind({}, "F4", function() windowCycling.cycleOrRun("Obsidian", "Obsidian") end)
hs.hotkey.bind({}, "F3", function() windowCycling.cycleOrRun("Zed", "Zed") end)
--hs.hotkey.bind({}, "F3", function() windowCycling.cycleOrRun("Code", "Visual Studio Code") end)

hs.hotkey.bind({}, "F8", function() windowCycling.cycleOrRun("tauri-explorer", "tauri-explorer", { focusAll = true }) end)
hs.hotkey.bind({}, "F12", function() windowCycling.cycleOrRun("Microsoft Teams", "Microsoft Teams") end)
hs.hotkey.bind({}, "F10", function() windowCycling.cycleOrRun("Lite XL", "Lite XL") end)
hs.hotkey.bind({ "alt" }, "n", function() windowCycling.cycleOrRun("Lite XL", "Lite XL") end)

-- Chained hotkey: Alt+M then E for Marta
-- helpers.bindSequence({"alt"}, {"M", "E"}, 0.5, function()
--   windowCycling.cycleOrRun("Marta", "Marta")
-- end)


---------- Window movement hotkeys (with quadrant chords) ----------
-- Pressing two arrows within 100ms snaps to a quadrant:
--   Up+Left = top-left, Up+Right = top-right
--   Down+Left = bottom-left, Down+Right = bottom-right
-- A single arrow (no second press within 100ms) does its original action.

local arrowChord = { pending = nil, timer = nil }
local CHORD_TIMEOUT = 0.1  -- 100ms

local quadrantActions = {
  ["Up+Left"]    = function() helpers.snap(hs.window.focusedWindow(), 0,   0,   0.5, 0.5) end,
  ["Up+Right"]   = function() helpers.snap(hs.window.focusedWindow(), 0.5, 0,   0.5, 0.5) end,
  ["Down+Left"]  = function() helpers.snap(hs.window.focusedWindow(), 0,   0.5, 0.5, 0.5) end,
  ["Down+Right"] = function() helpers.snap(hs.window.focusedWindow(), 0.5, 0.5, 0.5, 0.5) end,
}

local singleArrowActions = {
  Up    = helpers.toggleTopCenterMaximize,
  Down  = function() end,  -- no single-Down action
  Left  = helpers.moveWindowLeft,
  Right = helpers.moveWindowRight,
}

local function handleArrow(direction)
  if arrowChord.pending then
    -- Second arrow within the timeout — snap to quadrant (overrides first action)
    local first = arrowChord.pending
    arrowChord.timer:stop()
    arrowChord.pending = nil
    arrowChord.timer = nil

    -- Normalize key pair order (vertical+horizontal)
    local vertical = (first == "Up" or first == "Down") and first or direction
    local horizontal = (first == "Left" or first == "Right") and first or direction

    local key = vertical .. "+" .. horizontal
    local action = quadrantActions[key]
    if action then
      action()
    else
      -- Both same axis (e.g. Up+Down) — just fire the second one
      local fn = singleArrowActions[direction]
      if fn then fn() end
    end
  else
    -- First arrow — fire immediately, but stay open for a chord
    local fn = singleArrowActions[direction]
    if fn then fn() end

    arrowChord.pending = direction
    arrowChord.timer = hs.timer.doAfter(CHORD_TIMEOUT, function()
      arrowChord.pending = nil
      arrowChord.timer = nil
    end)
  end
end

hs.hotkey.bind({ "cmd", "ctrl" }, "Up",    function() handleArrow("Up") end)
hs.hotkey.bind({ "cmd", "ctrl" }, "Down",  function() handleArrow("Down") end)
hs.hotkey.bind({ "cmd", "ctrl" }, "Left",  function() handleArrow("Left") end)
hs.hotkey.bind({ "cmd", "ctrl" }, "Right", function() handleArrow("Right") end)

---------- Window resize hotkeys ----------
hs.hotkey.bind({ "cmd", "ctrl" }, "-", helpers.shrinkWindow)
hs.hotkey.bind({ "cmd", "ctrl" }, "=", helpers.growWindow)

-- Store previous frames for unmaximize
local unmaximizeSavedFrames = {}

-- "Ctrl+Cmd+Down": unmaximize if maximized, minimize otherwise
-- hs.hotkey.bind({"cmd", "ctrl"}, "Down", function()
--   local win = hs.window.focusedWindow()
--   if not win then return end

--   if helpers.isMaximized(win) then
--     local winId = win:id()
--     if unmaximizeSavedFrames[winId] then
--       -- unmaximize if maximized
--       win:setFrame(unmaximizeSavedFrames[winId])
--       unmaximizeSavedFrames[winId] = nil
--     else
--       -- If no saved frame, go to top-center
--       local centerFrame = helpers.getTopCenterFrame(win)
--       if centerFrame then
--         win:setFrame(centerFrame)
--       end
--     end
--   -- else
--   --   win:minimize()
--   end
-- end)

local function toggleMaximize()
  local win = hs.window.focusedWindow()
  if not win then return end

  local winId = win:id()

  if helpers.isMaximized(win) and unmaximizeSavedFrames[winId] then
    -- Restore previous frame
    win:setFrame(unmaximizeSavedFrames[winId])
    unmaximizeSavedFrames[winId] = nil
  else
    -- Save current frame and maximize
    unmaximizeSavedFrames[winId] = win:frame()
    win:maximize()
  end
end

-- "Win+Home": maximize/restore toggle
hs.hotkey.bind({ "cmd", "ctrl" }, "Home", toggleMaximize)
hs.hotkey.bind({ "cmd", "ctrl" }, "O", toggleMaximize)

-- ---------- Desktop switching ----------

hs.hotkey.bind({ "cmd" }, "`", helpers.toggleDesktop)

-- ---------- App quit ----------
hs.hotkey.bind({ "alt" }, "F4", helpers.quitOrCloseApp)
hs.hotkey.bind({ "cmd" }, "escape", helpers.quitOrCloseApp)

-- ---------- Screenshot ----------
-- Shift+Cmd+S: open the built-in Screenshot app (macOS)
hs.hotkey.bind({ "shift", "cmd" }, "S", function()
  local ok = hs.application.launchOrFocus("Screenshot")
  if not ok then
    hs.application.launchOrFocusByBundleID("com.apple.screenshot")
  end
end)

-- ---------- Smart paste (image -> file path) ----------

local function imageClipboardToTempPath()
  local image = hs.pasteboard.readImage()
  if not image then return nil end

  local tmpPath = string.format("/tmp/clipboard-%s.png", os.date("%Y%m%d-%H%M%S"))

  -- hs.image:saveToFile returns boolean
  local ok = image:saveToFile(tmpPath)
  if not ok then return nil end

  return tmpPath
end

local function typeText(text)
  hs.eventtap.keyStrokes(text)
end

local function pasteClipboardPathOrNormalPaste()
  local tmpPath = imageClipboardToTempPath()

  if tmpPath then
    typeText(tmpPath)
  else
    -- Fallback to normal paste
    hs.eventtap.keyStroke({ "cmd" }, "v")
  end
end

-- Ctrl+Shift+V: if clipboard has an image, save to /tmp and paste the path; otherwise normal paste.
hs.hotkey.bind({ "ctrl", "shift" }, "v", pasteClipboardPathOrNormalPaste)
