-- Keep WezTerm's GUI responsive when panes saturate the CPU. Pane processes
-- are placed in lower-weight scopes by wezterm_scheduling.lua; this launcher
-- puts the GUI in its own high-weight sibling scope.
local M = {}

local HOME = os.getenv("HOME") or ""
local LAUNCHER = HOME .. "/.local/bin/wezterm-hypr-launch"

M.launch = LAUNCHER
M.new_window = LAUNCHER .. " start"
M.restore_window = LAUNCHER .. " --restore-window"

return M
