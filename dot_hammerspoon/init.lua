---@diagnostic disable: undefined-global
hs.window.animationDuration = 0
require("hs.ipc").cliInstall()

local helpers = require("helpers")
local windowCycling = require("window_cycling")
local dropdownTerminal = require("dropdown_terminal")

-- ---------- App cycling like your F-keys ----------
hs.hotkey.bind({}, "F9", dropdownTerminal.toggle)
hs.hotkey.bind({}, "F7", function() windowCycling.cycleOrRun("Google Chrome", "Google Chrome") end)
hs.hotkey.bind({}, "F6", function() windowCycling.cycleOrRun("Google Chrome", "Google Chrome") end)
-- hs.hotkey.bind({}, "F5", function() windowCycling.cycleOrRun("Arc", "Arc") end)
hs.hotkey.bind({}, "F4", function() windowCycling.cycleOrRun("Obsidian", "Obsidian") end)
hs.hotkey.bind({}, "F3", function() windowCycling.cycleOrRun("Code", "Visual Studio Code") end)

hs.hotkey.bind({}, "F8", function() windowCycling.cycleOrRun("tauri-explorer", "tauri-explorer") end)
hs.hotkey.bind({}, "F10", function() windowCycling.cycleOrRun("Lite XL", "Lite XL", "hide") end)
hs.hotkey.bind({ "alt" }, "n", function() windowCycling.cycleOrRun("Lite XL", "Lite XL", "hide") end)

-- Chained hotkey: Alt+M then E for Marta
-- helpers.bindSequence({"alt"}, {"M", "E"}, 0.5, function()
--   windowCycling.cycleOrRun("Marta", "Marta")
-- end)


---------- Window movement hotkeys ----------
hs.hotkey.bind({ "cmd", "ctrl" }, "Left", helpers.moveWindowLeft)
hs.hotkey.bind({ "cmd", "ctrl" }, "Right", helpers.moveWindowRight)

---------- Window resize hotkeys ----------
hs.hotkey.bind({ "cmd", "ctrl" }, "-", helpers.shrinkWindow)
hs.hotkey.bind({ "cmd", "ctrl" }, "=", helpers.growWindow)

hs.hotkey.bind({ "cmd", "ctrl" }, "Up", helpers.toggleTopCenterMaximize)

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
