-- Keep WezTerm's GUI responsive when panes saturate the CPU. Pane processes
-- are placed in lower-weight scopes by wezterm_scheduling.lua; this launcher
-- puts the GUI in its own high-weight sibling scope.
local M = {}

local GUI_CPU_WEIGHT = 1000
local GUI_SCOPE = table.concat({
    "systemd-run",
    "--user",
    "--scope",
    "--quiet",
    "--collect",
    "--property=CPUWeight=" .. GUI_CPU_WEIGHT,
    "--",
    "wezterm",
}, " ")

M.launch = GUI_SCOPE
M.new_window = GUI_SCOPE .. " start"

return M
