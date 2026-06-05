-- put user settings here
-- this module will be loaded after everything else when the application starts
-- it will be automatically reloaded when saved

local core = require "core"
local keymap = require "core.keymap"
local config = require "core.config"
local style = require "core.style"
local command = require "core.command"

------------------------------ Themes ----------------------------------------

core.reload_module("colors.ayu-mirage")

------------------------------ Fonts -----------------------------------------

style.code_font = renderer.font.load(DATADIR .. "/fonts/JetBrainsMono-Regular.ttf", 18 * SCALE)

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

--------------------------- Custom commands ----------------------------------

local DocView = require "core.docview"

command.add(function()
  if not core.active_view:is(DocView) then return false end
  local l1, c1, l2, c2 = core.active_view.doc:get_selection()
  return l1 ~= l2 or c1 ~= c2
end, {
  ["doc:cursors-to-line-ends"] = function()
    local doc = core.active_view.doc
    local seen = {}
    local lines = {}
    for idx, l1, c1, l2, c2 in doc:get_selections(true) do
      local end_line = (c2 == 1 and l2 > l1) and l2 - 1 or l2
      for line = l1, end_line do
        if not seen[line] then
          seen[line] = true
          lines[#lines + 1] = line
        end
      end
    end
    if #lines == 0 then return end
    doc:set_selection(lines[1], math.huge)
    for i = 2, #lines do
      doc:add_selection(lines[i], math.huge)
    end
    doc:merge_cursors()
  end,
})

--------------------------- Key bindings -------------------------------------

-- VSCode-style keybindings (overwrite defaults)
keymap.add({
  -- File operations
  ["ctrl+shift+p"]     = "core:find-command",
  -- ctrl+p handled by plugins/recent_files.lua
  ["ctrl+shift+n"]     = "core:new-window",
  ["ctrl+n"]           = "core:new-doc",
  ["ctrl+t"]           = "core:new-doc",
  ["ctrl+shift+s"]     = "doc:save-as",
  ["ctrl+s"]           = "doc:save",
  ["ctrl+w"]           = "root:close",
  ["ctrl+shift+w"]     = "core:quit",
  ["ctrl+q"]           = "core:quit",

  -- Navigation
  ["ctrl+g"]           = "doc:go-to-line",
  ["ctrl+shift+e"]     = "treeview:toggle",
  ["ctrl+b"]           = "treeview:toggle",
  ["ctrl+`"]           = "core:open-log",
  ["ctrl+tab"]         = "root:switch-to-next-tab",
  ["ctrl+shift+tab"]   = "root:switch-to-previous-tab",
  ["alt+1"]            = "root:switch-to-tab-1",
  ["alt+2"]            = "root:switch-to-tab-2",
  ["alt+3"]            = "root:switch-to-tab-3",
  ["alt+4"]            = "root:switch-to-tab-4",
  ["alt+5"]            = "root:switch-to-tab-5",

  -- Editing
  ["ctrl+shift+k"]     = "doc:delete-lines",
  ["ctrl+shift+d"]     = "doc:duplicate-lines",
  ["alt+up"]           = "doc:move-lines-up",
  ["alt+down"]         = "doc:move-lines-down",
  ["ctrl+/"]           = "doc:toggle-line-comments",
  ["ctrl+shift+a"]     = "doc:toggle-block-comments",
  ["ctrl+shift+l"]     = "doc:cursors-to-line-ends",
  ["ctrl+shift+enter"] = "doc:newline-above",
  ["ctrl+enter"]       = "doc:newline-below",
  ["ctrl+]"]           = "doc:indent",
  ["ctrl+["]           = "doc:unindent",

  -- Search & replace
  ["ctrl+h"]           = "find-replace:open",
  ["ctrl+shift+h"]     = "find-replace:open",
  ["ctrl+f"]           = "find-replace:find",
  ["ctrl+shift+f"]     = "project-search:find",

  -- Multi-cursor / selection
  ["ctrl+shift+l"]     = "doc:select-word",

  -- View
  ["ctrl+="]           = "scale:increase",
  ["ctrl+-"]           = "scale:decrease",
  ["ctrl+0"]           = "scale:reset",
}, true)

-- Use add_direct to bypass macOS ctrl→cmd auto-conversion
keymap.add_direct {
  ["ctrl+pageup"]  = { "root:switch-to-previous-tab" },
  ["ctrl+pagedown"] = { "root:switch-to-next-tab" },
}

------------------------------ Evergreen (tree-sitter) -------------------------

local ts_lib = USERDIR .. '/libraries/tree_sitter/init.lib'
local ts_parser = USERDIR .. '/plugins/evergreen-python/parser.so'

if system.get_file_info(ts_lib) and system.get_file_info(ts_parser) then
  local evergreenLangs = require 'plugins.evergreen.languages'

  evergreenLangs.addDef {
    name = 'python',
    files = { '%.py$', '%.pyw$', '%.pyi$' },
    path = USERDIR .. '/plugins/evergreen-python',
    soFile = 'parser{SOEXT}',
    queryFiles = {
      highlights = 'queries/highlights.scm',
    },
  }
else
  core.add_thread(function()
    local missing = {}
    if not system.get_file_info(ts_lib) then missing[#missing+1] = ts_lib end
    if not system.get_file_info(ts_parser) then missing[#missing+1] = ts_parser end
    core.warn(
      'Evergreen tree-sitter disabled — missing native binaries:\n  %s\n'
      .. 'See: https://github.com/Evergreen-lxl/lite-xl-tree-sitter/releases',
      table.concat(missing, '\n  ')
    )
  end)
end

------------------------------ Plugins ----------------------------------------

-- config.plugins.detectindent = false

-- Patch emptyview to handle unbound commands without crashing
local EmptyView = require "core.emptyview"
local original_emptyview_draw = EmptyView.draw
function EmptyView:draw()
  local ok, err = pcall(original_emptyview_draw, self)
  if not ok then
    self:draw_background(style.background)
  end
end

------------------------ Hide tab bar for single tab --------------------------

local Node = require "core.node"
local original_draw_tabs = Node.draw_tabs
function Node:draw_tabs()
  if #self.views == 1 then return end
  original_draw_tabs(self)
end

local original_get_tab_rect = Node.get_tab_rect
function Node:get_tab_rect(...)
  local x, y, w, h = original_get_tab_rect(self, ...)
  if #self.views == 1 then
    h = 0
  end
  return x, y, w, h
end

------------------------ Skip unsaved-changes nag -----------------------------

function core.confirm_close_docs(docs, close_fn, ...)
  close_fn(...)
end

---------------------------- Line Wrapping -----------------------------------

config.plugins.linewrapping = {
  mode = "word",
  enable_by_default = true,
  indent = true,
  guide = false,
}

---------------------------- Miscellaneous ------------------------------------

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
