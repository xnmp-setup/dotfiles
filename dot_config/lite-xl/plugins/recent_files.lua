-- mod-version:3
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local config = require "core.config"

local MAX_RECENT = 50
local recent = {}
local state_file = USERDIR .. PATHSEP .. "recent_files.lua"

local function save_state()
  local fp = io.open(state_file, "w")
  if not fp then return end
  fp:write("return {\n")
  for i, path in ipairs(recent) do
    if i > MAX_RECENT then break end
    fp:write(string.format("  %q,\n", path))
  end
  fp:write("}\n")
  fp:close()
end

local function load_state()
  local fn = loadfile(state_file)
  if fn then
    local ok, data = pcall(fn)
    if ok and type(data) == "table" then
      recent = data
    end
  end
end

local function push_recent(path)
  if not path then return end
  path = common.normalize_path(path)
  for i, p in ipairs(recent) do
    if p == path then
      table.remove(recent, i)
      break
    end
  end
  table.insert(recent, 1, path)
  if #recent > MAX_RECENT then
    recent[MAX_RECENT + 1] = nil
  end
  save_state()
end

local original_open_doc = core.open_doc
function core.open_doc(filename)
  local doc = original_open_doc(filename)
  if doc and doc.filename then
    push_recent(system.absolute_path(doc.filename))
  end
  return doc
end

local function get_suggestions()
  local items = {}
  local seen = {}
  for _, path in ipairs(recent) do
    if system.get_file_info(path) then
      local rel = common.relative_path(core.project_dir, path)
      items[#items + 1] = rel
      seen[path] = true
    end
  end
  for _, item in ipairs(core.project_files) do
    local abs = core.project_dir .. PATHSEP .. item.filename
    if not item.type or item.type == "file" then
      if not seen[abs] then
        items[#items + 1] = item.filename
      end
    end
  end
  return items
end

command.add(nil, {
  ["core:open-recent-file"] = function()
    core.command_view:enter("Open Recent File", {
      submit = function(text, item)
        local path = common.home_expand(item and item.text or text)
        local info = system.get_file_info(path)
        if info and info.type == "dir" then
          core.command_view:set_text(common.home_encode(path) .. "/")
          return
        end
        core.root_view:open_doc(core.open_doc(path))
      end,
      suggest = function(text)
        if text:match("^[/~%.]") or text:find("/") then
          return common.home_encode_list(common.path_suggest(common.home_expand(text)))
        end
        return common.fuzzy_match(get_suggestions(), text)
      end,
    })
  end,
})

keymap.add({ ["ctrl+p"] = "core:open-recent-file" }, true)

load_state()
