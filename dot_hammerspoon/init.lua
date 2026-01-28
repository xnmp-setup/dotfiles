---@diagnostic disable: undefined-global
hs.window.animationDuration = 0

local helpers = require("helpers")
local windowCycling = require("window_cycling")
local dropdownTerminal = require("dropdown_terminal")

-- ---------- App cycling like your F-keys ----------
hs.hotkey.bind({}, "F9", dropdownTerminal.toggle)
hs.hotkey.bind({}, "F6", function() windowCycling.cycleOrRun("Google Chrome", "Google Chrome") end)
hs.hotkey.bind({}, "F4", function() windowCycling.cycleOrRun("Obsidian", "Obsidian") end)
hs.hotkey.bind({}, "F3", function() windowCycling.cycleOrRun("Code", "Visual Studio Code") end)

hs.hotkey.bind({}, "F8", function() windowCycling.cycleOrRun("Marta", "Marta") end)

-- hs.hotkey.bind({}, "F5", function() windowCycling.cycleOrRun("Google Chrome", "Google Chrome") end)
hs.hotkey.bind({"alt"}, "N", function() windowCycling.cycleOrRun("Sublime Text", "Sublime Text", "top") end)

-- Chained hotkey: Alt+M then E for Marta
-- helpers.bindSequence({"alt"}, {"M", "E"}, 0.5, function()
--   windowCycling.cycleOrRun("Marta", "Marta")
-- end)


-- ---------- Window movement hotkeys ----------
hs.hotkey.bind({"cmd","ctrl"}, "Left", helpers.moveLeft)

hs.hotkey.bind({"cmd", "ctrl"}, "Right", helpers.moveRight)

hs.hotkey.bind({"cmd", "ctrl"}, "Up", helpers.toggleTopCenterMaximize)

-- Store previous frames for unmaximize
local unmaximizeSavedFrames = {}

-- "Ctrl+Cmd+Down": unmaximize if maximized, minimize otherwise
hs.hotkey.bind({"cmd", "ctrl"}, "Down", function()
  local win = hs.window.focusedWindow()
  if not win then return end

  if helpers.isMaximized(win) then
    local winId = win:id()
    if unmaximizeSavedFrames[winId] then
      -- unmaximize if maximized
      win:setFrame(unmaximizeSavedFrames[winId])
      unmaximizeSavedFrames[winId] = nil
    else
      -- If no saved frame, go to top-center
      local centerFrame = helpers.getTopCenterFrame(win)
      if centerFrame then
        win:setFrame(centerFrame)
      end
    end
  -- else
  --   win:minimize()
  end
end)

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
hs.hotkey.bind({"cmd", "ctrl"}, "Home", toggleMaximize)
hs.hotkey.bind({"cmd", "ctrl"}, "O", toggleMaximize)

-- ---------- Desktop switching ----------

hs.hotkey.bind({"cmd"}, "`", helpers.toggleDesktop)

-- ---------- App quit ----------
hs.hotkey.bind({"alt"}, "F4", function()
  local win = hs.window.focusedWindow()
  if win then
    local app = win:application()
    local windows = app:allWindows()

    -- Close window if multiple windows exist, otherwise quit the app
    if #windows > 1 then
      win:close()
    else
      app:kill()
    end
  end
end)
