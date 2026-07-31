-- Interactive color-scheme selection and persistence.
local wezterm = require 'wezterm'
local act = wezterm.action

local M = {}

function M.replace_color_scheme(content, name)
  return content:gsub(
    "(config%.color_scheme%s*=%s*)('[^']*')",
    "%1'" .. name:gsub("'", "\\'") .. "'"
  )
end

function M.setup(config, opts)
  local persist_path = assert(opts.persist_path, 'theme persistence path is required')

  -- ---------- Command palette: Set Theme ----------
  local function persist_color_scheme(name)
    local fh = io.open(persist_path, 'r')
    if not fh then return end
    local content = fh:read('*a')
    fh:close()
    local updated = M.replace_color_scheme(content, name)
    local out = io.open(persist_path, 'w')
    if out then
      out:write(updated)
      out:close()
    end
  end

  wezterm.on('augment-command-palette', function(window, pane)
    return {
      {
        brief = 'Set Theme...',
        icon = 'md_palette',
        action = wezterm.action_callback(function(win, p)
          local schemes = wezterm.get_builtin_color_schemes()
          for name, _ in pairs(config.color_schemes or {}) do
            schemes[name] = true
          end
          local choices = {}
          for name, _ in pairs(schemes) do
            table.insert(choices, { label = name })
          end
          table.sort(choices, function(a, b) return a.label < b.label end)

          win:perform_action(act.InputSelector {
            title = 'Set Theme',
            choices = choices,
            fuzzy = true,
            action = wezterm.action_callback(function(w, _, _, label)
              if label then
                local overrides = w:get_config_overrides() or {}
                overrides.color_scheme = label
                w:set_config_overrides(overrides)
                persist_color_scheme(label)
              end
            end),
          }, p)
        end),
      },
    }
  end)
end

return M
