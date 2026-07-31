-- Modifier-click hyperlinks and local image-path handling.
local wezterm = require 'wezterm'
local act = wezterm.action

local M = {}

local IMAGE_URI_PREFIX = 'wezterm-image:'
local IMAGE_PATH_RULE = {
  -- Defaults claim complete URLs first. This rule then recognizes local paths
  -- such as /tmp/image.png, ./image.webp, ~/image.jpg and images/icon.svg.
  regex = [[(?<![\w:])((?:[A-Za-z]:[\\/]|~?[\\/]|\.{1,2}[\\/])?[^\s"'<>|]+?\.(?:avif|bmp|gif|jpe?g|png|svg|webp))\b]],
  format = IMAGE_URI_PREFIX .. '$1',
}

local function cwd_path(pane)
  local ok, cwd = pcall(function() return pane:get_current_working_dir() end)
  if not ok or cwd == nil then return nil end
  if type(cwd) == 'string' then
    return cwd:match('^file://[^/]*(/.*)$') or cwd
  end

  local got_path, file_path = pcall(function() return cwd.file_path end)
  if got_path and file_path and file_path ~= '' then return file_path end

  local value = tostring(cwd)
  return value:match('^file://[^/]*(/.*)$') or value
end

local function is_absolute(path)
  return path:match('^/') ~= nil
    or path:match('^\\\\') ~= nil
    or path:match('^[A-Za-z]:[\\/]') ~= nil
end

local function path_separator(path)
  return path:match('^[A-Za-z]:') and '\\' or '/'
end

function M.resolve_image_path(path, cwd, home)
  if type(path) ~= 'string' or path == '' then return nil end

  if path == '~' then return home end
  if path:match('^~[\\/]') then
    if not home or home == '' then return nil end
    return home .. path_separator(home) .. path:sub(3)
  end
  if is_absolute(path) then return path end
  if not cwd or cwd == '' then return nil end

  local separator = path_separator(cwd)
  return cwd:gsub('[\\/]+$', '') .. separator .. path
end

local function add_click_binding(bindings, mods, mouse_reporting)
  bindings[#bindings + 1] = {
    event = { Down = { streak = 1, button = 'Left' } },
    mods = mods,
    mouse_reporting = mouse_reporting,
    action = act.Nop,
  }
  bindings[#bindings + 1] = {
    event = { Up = { streak = 1, button = 'Left' } },
    mods = mods,
    mouse_reporting = mouse_reporting,
    action = act.OpenLinkAtMouseCursor,
  }
end

function M.setup(config)
  local rules = wezterm.default_hyperlink_rules()
  rules[#rules + 1] = IMAGE_PATH_RULE
  config.hyperlink_rules = rules

  config.mouse_bindings = config.mouse_bindings or {}
  for _, mods in ipairs { 'CTRL', 'ALT' } do
    add_click_binding(config.mouse_bindings, mods, false)
    -- TUI applications can enable mouse reporting. Match that state too so
    -- modifier-click remains a terminal action instead of reaching the TUI.
    add_click_binding(config.mouse_bindings, mods, true)
  end

  wezterm.on('open-uri', function(window, pane, uri)
    if type(uri) ~= 'string' or uri:sub(1, #IMAGE_URI_PREFIX) ~= IMAGE_URI_PREFIX then
      return
    end

    local path = M.resolve_image_path(
      uri:sub(#IMAGE_URI_PREFIX + 1),
      cwd_path(pane),
      wezterm.home_dir
    )
    if not path then
      window:toast_notification(
        'WezTerm',
        'Could not resolve that image path from this pane.',
        nil,
        4000
      )
      return false
    end

    wezterm.open_with(path)
    return false
  end)
end

return M
