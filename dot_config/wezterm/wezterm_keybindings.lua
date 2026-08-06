-- User input bindings. Higher-level actions are injected by their owning modules.
local wezterm = require 'wezterm'
local act = wezterm.action
local clipboard = require 'wezterm_clipboard'

local M = {}

function M.apply(config, deps)
  local spawn_tab_next = deps.navigation.spawn_tab_next
  local tab_nav_across_windows = deps.navigation.tab_nav_across_windows
  local move_tab_to_window = deps.windowing.move_tab_to_window
  local spawn_bg_tab = deps.background.spawn_tab
  local detach_bg_tab = deps.background.detach_tab
  local reattach_bg_tab = deps.background.reattach_tab
  local page_keys_scroll_terminal = deps.agent.page_keys_scroll_terminal
  local activate_utility_chord = deps.utilities.activate_chord
  local close_pane = deps.close.close_pane
  local close_tab = deps.close.close_tab
  local confirmation_active = deps.close.confirmation_active
  local copy_previous_command = deps.output.copy_previous_command
  local reopen_tab = deps.recent_tabs.reopen_tab

  -- ---------- Keybinds ----------
  config.keys = {
    -- config / palette
    { key = ',', mods = 'CTRL|SHIFT', action = act.ReloadConfiguration },
    { key = 'p', mods = 'CTRL|SHIFT', action = act.ActivateCommandPalette },
    -- One-shot utility chord: alt+m, then e=yazi, g=keifu, t=terminal, d=dev server.
    { key = 'm', mods = 'ALT', action = activate_utility_chord },

    -- tabs / windows / panes
    -- Process-aware close actions: idle shells close immediately; attached jobs
    -- get the centered confirmation overlay. Tab close sees hidden persistent
    -- panes too.
    { key = 'w', mods = 'CTRL', action = close_pane() },
    { key = 'w', mods = 'SUPER', action = close_tab() },
    -- Enter: the close-confirmation overlay natively accepts only y/n; while
    -- it is up, translate Enter to y so Enter confirms too. Every other Enter
    -- is forwarded as a real Enter keypress (same pattern as Esc below).
    { key = 'Enter', mods = 'NONE', action = wezterm.action_callback(function(window, pane)
      if confirmation_active(window, pane) then
        window:perform_action(act.SendKey { key = 'y' }, pane)
      else
        window:perform_action(act.SendKey { key = 'Enter' }, pane)
      end
    end) },
    -- Esc: interrupt handling. A user interrupt (Esc mid-response) fires no hook in
    -- either agent, so the agent_status var stays stuck on 'working' and the tab
    -- keeps spinning. Intercept Esc here: if the pane is running an agent, mark it
    -- 'done' in pane_status (the tab bar's source of truth) so it drops to idle
    -- immediately. This intentionally includes non-interrupt uses such as dismissing
    -- a /btw overlay. Always forward the Esc to the app afterwards, so the agent
    -- still receives it. A fresh prompt's 'working' var write overrides 'done'.
    { key = 'Escape', mods = 'NONE', action = wezterm.action_callback(function(window, pane)
      deps.agent.mark_done(pane)
      window:perform_action(act.SendKey { key = 'Escape' }, pane)
    end) },
    { key = 't', mods = 'CTRL', action = spawn_tab_next('CurrentPaneDomain') },
    -- Browser-style LIFO restore: layout/cwds always, recognized coding agents
    -- via their explicit resume commands. See wezterm_recent_tabs.lua.
    { key = 't', mods = 'CTRL|SHIFT', action = reopen_tab() },
    { key = 'n', mods = 'CTRL', action = act.SpawnWindow },
    -- ctrl+shift+n: pop the current tab out into its own new window.
    { key = 'n', mods = 'CTRL|SHIFT', action = wezterm.action_callback(function(win, pane)
      local _, new_window = pane:move_to_new_window()
      local gui = new_window:gui_window()
      if gui then gui:focus() end
    end) },
    -- ctrl+shift+m: move the current tab into an existing window (pick from a list).
    { key = 'm', mods = 'CTRL|SHIFT', action = move_tab_to_window() },
    -- Background tabs: ctrl+alt+t opens one (unix-domain, survives GUI close),
    -- ctrl+shift+w detaches the current bg tab, ctrl+shift+e reattaches one. The
    -- callbacks no-op with a toast on non-macOS/Linux (BG_ENABLED). See the
    -- See wezterm_background.lua for the full rationale.
    { key = 't', mods = 'CTRL|ALT', action = spawn_bg_tab() },
    { key = 'w', mods = 'CTRL|SHIFT', action = detach_bg_tab() },
    { key = 'e', mods = 'CTRL|SHIFT', action = reattach_bg_tab() },
    { key = 'PageUp', mods = 'CTRL', action = tab_nav_across_windows(-1) },
    { key = 'PageDown', mods = 'CTRL', action = tab_nav_across_windows(1) },

    -- Text is pasted by WezTerm. For an image clipboard, forward ^V so TUI
    -- applications such as Claude Code and Codex can attach the image directly.
    { key = 'v', mods = 'CTRL', action = clipboard.paste_action() },
    { key = 'Insert', mods = 'SHIFT', action = act.PasteFrom 'Clipboard' },
    -- performable ctrl+c: copy if there's a selection, else send SIGINT (^C)
    {
      key = 'c',
      mods = 'CTRL',
      action = wezterm.action_callback(function(window, pane)
        local sel = window:get_selection_text_for_pane(pane)
        if sel and sel ~= '' then
          window:perform_action(act.CopyTo 'Clipboard', pane)
        else
          window:perform_action(act.SendKey { key = 'c', mods = 'CTRL' }, pane)
        end
      end),
    },
    { key = 'c', mods = 'CTRL|ALT', action = copy_previous_command },

    -- unbind ghostty's ctrl+shift+left/right
    { key = 'LeftArrow', mods = 'CTRL|SHIFT', action = act.DisableDefaultAssignment },
    { key = 'RightArrow', mods = 'CTRL|SHIFT', action = act.DisableDefaultAssignment },

    -- scrolling
    { key = 'PageUp', mods = 'SHIFT', action = act.ScrollByPage(-1) },
    { key = 'PageDown', mods = 'SHIFT', action = act.ScrollByPage(1) },
    { key = 'PageUp', mods = 'NONE', action = wezterm.action_callback(function(window, pane)
      if page_keys_scroll_terminal(pane) then
        window:perform_action(act.ScrollByPage(-0.5), pane)
      else
        window:perform_action(act.SendKey { key = 'PageUp' }, pane)
      end
    end) },
    { key = 'PageDown', mods = 'NONE', action = wezterm.action_callback(function(window, pane)
      if page_keys_scroll_terminal(pane) then
        window:perform_action(act.ScrollByPage(0.5), pane)
      else
        window:perform_action(act.SendKey { key = 'PageDown' }, pane)
      end
    end) },

    -- panes: create (alt+super) and navigate (super). The letter navigation
    -- avoids super+arrow, which Hyprland consumes before WezTerm sees it.
    { key = "'", mods = 'ALT|SUPER', action = act.SplitPane { direction = 'Right' } },
    { key = 't', mods = 'CTRL|SHIFT|ALT|SUPER', action = act.SplitPane { direction = 'Right' } },
    { key = 'h', mods = 'CTRL', action = act.SplitPane { direction = 'Right' } },
    { key = 'l', mods = 'ALT|SUPER', action = act.SplitPane { direction = 'Left' } },
    { key = 'p', mods = 'ALT|SUPER', action = act.SplitPane { direction = 'Up' } },
    { key = ';', mods = 'ALT|SUPER', action = act.SplitPane { direction = 'Down' } },
    { key = 'o', mods = 'ALT', action = act.TogglePaneZoomState },
    { key = 'l', mods = 'SUPER', action = act.ActivatePaneDirection 'Left' },
    { key = 'p', mods = 'SUPER', action = act.ActivatePaneDirection 'Up' },
    { key = ';', mods = 'SUPER', action = act.ActivatePaneDirection 'Down' },
    { key = "'", mods = 'SUPER', action = act.ActivatePaneDirection 'Right' },

    -- raw escape / CSI-u sequences
    { key = '/', mods = 'SUPER', action = act.SendString '\x1f' },
    { key = 'Enter', mods = 'CTRL', action = act.SendString '\x1b[13;5u' },
    { key = 'Enter', mods = 'SHIFT', action = act.SendString '\x1b[13;2u' },
    { key = 'Backspace', mods = 'ALT', action = act.SendString '\x1b\x7f' },
    { key = 'Backspace', mods = 'CTRL', action = act.SendString '\x17' },
    { key = 'Delete', mods = 'ALT', action = act.SendString '\x1bd' },
    { key = 'Delete', mods = 'CTRL', action = act.SendString '\x1bd' },
    -- Word nav: karabiner rewrites ctrl+left/right => alt(option)+left/right,
    -- so the terminal sees Alt+Arrow. Emit the real ctrl+arrow CSI sequences
    -- (zsh binds these to backward-word/forward-word; TUIs read them too).
    { key = 'LeftArrow', mods = 'ALT', action = act.SendString '\x1b[1;5D' },
    { key = 'RightArrow', mods = 'ALT', action = act.SendString '\x1b[1;5C' },
    { key = 'k', mods = 'CTRL|SHIFT', action = act.SendString '\x0b' },
    { key = 'Home', mods = 'SHIFT', action = act.SendString '\x1b[1;2H' },
    { key = 'End', mods = 'SHIFT', action = act.SendString '\x1b[1;2F' },
  }
end

return M
