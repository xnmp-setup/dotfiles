-- Clipboard routing for terminal applications.
--
-- Terminals can paste text themselves, but doing so consumes Ctrl+V before a
-- TUI can inspect an image clipboard. Route image clipboards to the child as
-- ^V; keep ordinary text paste in WezTerm.
local wezterm = require 'wezterm'
local act = wezterm.action

local M = {}

function M.has_image_mime(types)
  if type(types) ~= 'string' then return false end

  for mime in types:gmatch('[^\r\n]+') do
    if mime:lower():match('^%s*image/') then return true end
  end

  return false
end

function M.clipboard_type_command(target_triple)
  target_triple = (target_triple or ''):lower()

  if target_triple:find('linux', 1, true) then
    -- The probe runs synchronously on the GUI thread before every paste, and
    -- wl-paste blocks indefinitely when the clipboard owner is dead or busy —
    -- a common Wayland state that would otherwise wedge the whole window.
    -- A timed-out probe exits non-zero and falls back to plain text paste.
    -- GNU coreutils `timeout` is present on every Linux target (incl. WSL);
    -- macOS ships no `timeout`, so the other branches stay unwrapped.
    return { 'timeout', '0.2', 'wl-paste', '--list-types' }
  end

  if target_triple:find('darwin', 1, true) then
    return {
      '/usr/bin/osascript',
      '-e',
      'try',
      '-e',
      'the clipboard as «class PNGf»',
      '-e',
      'return "image/png"',
      '-e',
      'on error',
      '-e',
      'try',
      '-e',
      'the clipboard as TIFF picture',
      '-e',
      'return "image/tiff"',
      '-e',
      'end try',
      '-e',
      'end try',
    }
  end

  if target_triple:find('windows', 1, true) then
    return {
      'powershell.exe',
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "if (Get-Clipboard -Format Image -ErrorAction SilentlyContinue) { 'image/png' }",
    }
  end

  return nil
end

function M.clipboard_has_image(run_child_process, target_triple)
  local command = M.clipboard_type_command(target_triple)
  if not command then return false end

  local ok, success, stdout = pcall(run_child_process, command)
  return ok and success and M.has_image_mime(stdout)
end

function M.paste_action(options)
  options = options or {}
  local run_child_process = options.run_child_process or wezterm.run_child_process
  local target_triple = options.target_triple or wezterm.target_triple

  return wezterm.action_callback(function(window, pane)
    if M.clipboard_has_image(run_child_process, target_triple) then
      window:perform_action(act.SendKey { key = 'v', mods = 'CTRL' }, pane)
    else
      window:perform_action(act.PasteFrom 'Clipboard', pane)
    end
  end)
end

return M
