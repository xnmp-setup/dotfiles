-- put user settings here
-- this module will be loaded after everything else when the application starts
-- it will be automatically reloaded when saved

local core = require "core"
local keymap = require "core.keymap"
local config = require "core.config"
local style = require "core.style"
local command = require "core.command"

------------------------------ Themes ----------------------------------------

core.reload_module("colors.rapture")

------------------------------ Fonts -----------------------------------------

style.code_font = renderer.font.load(DATADIR .. "/fonts/JetBrainsMono-Regular.ttf", 16 * SCALE)

------------------------------ Hide UI ---------------------------------------

-- Hide toolbar
config.plugins.toolbarview = false

-- Hide treeview (explorer sidebar) on startup
config.plugins.treeview = { size = 0 }
core.add_thread(function()
  local TreeView = require "plugins.treeview"
  TreeView.visible = false
end)

-- Hide status bar
local StatusView = require "core.statusview"
local sv_get_items = StatusView.get_items
function StatusView:update()
  self.size.y = 0
end

--------------------------- Key bindings -------------------------------------

-- VSCode-style keybindings (overwrite defaults)
keymap.add({
  -- File operations
  ["ctrl+shift+p"]    = "core:find-command",
  ["ctrl+p"]          = "core:find-file",
  ["ctrl+shift+n"]    = "core:new-window",
  ["ctrl+n"]          = "core:new-doc",
  ["ctrl+t"]          = "core:new-doc",
  ["ctrl+shift+s"]    = "doc:save-as",
  ["ctrl+s"]          = "doc:save",
  ["ctrl+w"]          = "root:close",
  ["ctrl+shift+w"]    = "core:quit",

  -- Navigation
  ["ctrl+g"]          = "doc:go-to-line",
  ["ctrl+shift+e"]    = "treeview:toggle",
  ["ctrl+b"]          = "treeview:toggle",
  ["ctrl+`"]          = "core:open-log",
  ["ctrl+tab"]        = "root:switch-to-next-tab",
  ["ctrl+shift+tab"]  = "root:switch-to-previous-tab",
  ["ctrl+pageup"]     = "root:switch-to-previous-tab",
  ["ctrl+pagedown"]   = "root:switch-to-next-tab",
  ["alt+1"]           = "root:switch-to-tab-1",
  ["alt+2"]           = "root:switch-to-tab-2",
  ["alt+3"]           = "root:switch-to-tab-3",
  ["alt+4"]           = "root:switch-to-tab-4",
  ["alt+5"]           = "root:switch-to-tab-5",

  -- Editing
  ["ctrl+shift+k"]    = "doc:delete-lines",
  ["ctrl+shift+d"]    = "doc:duplicate-lines",
  ["alt+up"]          = "doc:move-lines-up",
  ["alt+down"]        = "doc:move-lines-down",
  ["ctrl+/"]          = "doc:toggle-line-comments",
  ["ctrl+shift+a"]    = "doc:toggle-block-comments",
  ["ctrl+d"]          = "doc:select-word",
  ["ctrl+l"]          = "doc:select-lines",
  ["ctrl+shift+enter"] = "doc:newline-above",
  ["ctrl+enter"]      = "doc:newline-below",
  ["ctrl+]"]          = "doc:indent",
  ["ctrl+["]          = "doc:unindent",

  -- Search & replace
  ["ctrl+h"]          = "find-replace:open",
  ["ctrl+shift+h"]    = "find-replace:open",
  ["ctrl+f"]          = "find-replace:open-find",
  ["ctrl+shift+f"]    = "project-search:find",

  -- Multi-cursor / selection
  ["ctrl+shift+l"]    = "doc:select-word",

  -- View
  ["ctrl+="]          = "scale:increase",
  ["ctrl+-"]          = "scale:decrease",
  ["ctrl+0"]          = "scale:reset",
}, true)

------------------------------ Plugins ----------------------------------------

-- config.plugins.detectindent = false

---------------------------- Miscellaneous ------------------------------------

-- Hide line numbers
local DocView = require "core.docview"
function DocView:get_gutter_width()
  return style.padding.x, style.padding.x
end
function DocView:draw_line_gutter()
  return self:get_line_height()
end
local original_close = command.map["root:close"].perform
command.map["root:close"].perform = function(...)
  original_close(...)
  local has_docs = false
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if view:is(DocView) then
      has_docs = true
      break
    end
  end
  if not has_docs then
    core.quit()
  end
end
