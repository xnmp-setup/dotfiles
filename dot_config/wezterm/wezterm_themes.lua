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
  -- Injected from wezterm_appearance: name -> scheme table, and scheme table ->
  -- tab bar palette. Switching color_scheme at runtime does NOT recolor the
  -- fancy tab bar (its button colors come from static config.colors.tab_bar),
  -- so we re-derive and override them alongside the scheme.
  local resolve_scheme = assert(opts.resolve_scheme, 'resolve_scheme is required')
  local tab_bar_colors = assert(opts.tab_bar_colors, 'tab_bar_colors is required')

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
                -- Copy the base colors table so unrelated entries (split
                -- divider, …) survive; only tab_bar/background are re-derived.
                local colors = {}
                for k, v in pairs(overrides.colors or config.colors or {}) do
                  colors[k] = v
                end
                colors.tab_bar = tab_bar_colors(resolve_scheme(config, label))
                overrides.colors = colors
                -- window_frame is a separate table and also carries the scheme
                -- background (the strip behind the tab buttons).
                local frame = {}
                for k, v in pairs(overrides.window_frame or config.window_frame or {}) do
                  frame[k] = v
                end
                frame.active_titlebar_bg = colors.tab_bar.background
                frame.inactive_titlebar_bg = colors.tab_bar.background
                overrides.window_frame = frame
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
