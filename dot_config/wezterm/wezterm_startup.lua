-- Persistent startup evidence for the gap between the mux and GUI layers.
-- The launcher redirects WezTerm's INFO stream to ~/.local/state/wezterm; the
-- existing structured log is a second, compact record that survives reboot.
local wezterm = require 'wezterm'
local mux = wezterm.mux

local M = {}

local function command_summary(cmd)
  if not cmd then return 'default' end
  return table.concat(cmd.args or {}, ' ')
end

function M.setup(opts)
  opts = opts or {}
  local log = opts.log or function() end
  local ready = {}

  wezterm.on('gui-startup', function(cmd)
    log('startup.gui_startup', { command = command_summary(cmd) })
  end)

  wezterm.on('gui-attached', function(domain)
    local windows = mux.all_windows()
    local gui_windows = 0
    for _, window in ipairs(windows) do
      local ok, gui = pcall(function() return window:gui_window() end)
      if ok and gui then gui_windows = gui_windows + 1 end
    end
    log('startup.gui_attached', {
      domain = tostring(domain),
      gui_windows = gui_windows,
      mux_windows = #windows,
      workspace = mux.get_active_workspace(),
    })
  end)

  -- This event requires a GUI-layer Window object. It does not prove that
  -- Hyprland received a surface; the launcher's delayed client snapshots are
  -- the compositor-side half of that distinction.
  wezterm.on('update-status', function(window, pane)
    local id = window:window_id()
    if ready[id] then return end
    ready[id] = true
    log('startup.window_ready', {
      pane_id = pane and pane:pane_id() or -1,
      window_id = id,
      workspace = window:active_workspace(),
    })
  end)
end

return M
