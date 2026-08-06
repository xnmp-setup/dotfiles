-- Behavioral tests for wezterm_tabbar.lua. Run: lua wezterm_tabbar.test.lua
-- A small WezTerm stub verifies the rendered tab text without a GUI.

package.path = (arg[0]:match('(.*/)') or './') .. '?.lua;' .. package.path

local callbacks = {}
package.preload.wezterm = function()
  return {
    on = function(name, callback) callbacks[name] = callback end,
    column_width = function(value)
      local width = 0
      for _, codepoint in utf8.codes(value) do
        if codepoint ~= 0xfe0e then width = width + 1 end
      end
      return width
    end,
    truncate_right = function(value, width) return value:sub(1, width) end,
    format = function(value) return value end,
  }
end

local agent = {
  now_ms = function() return 1000 end,
  track_animation = function() end,
  status_of = function() return 'done' end,
  of_pane = function(_, user_vars) return (user_vars or {}).agent_kind end,
  window_has_working = function() return false end,
}

require('wezterm_tabbar').setup {
  agent = agent,
  status_update_interval_ms = 200,
}

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    io.write(string.format(
      'FAIL %s\n  got:  [%s]\n  want: [%s]\n',
      name,
      tostring(got),
      tostring(want)
    ))
  end
end

local function render(spec)
  local active_pane = {
    pane_id = 7,
    title = spec.title or '',
    foreground_process_name = spec.process,
    current_working_dir = spec.cwd or 'file://host/work/chezmoi',
    user_vars = spec.user_vars or {},
  }
  local tab = {
    tab_id = spec.tab_id or 1,
    window_id = 1,
    is_active = true,
    active_pane = active_pane,
    panes = { active_pane },
  }
  local runs = callbacks['format-tab-title'](
    tab,
    { tab },
    { active_pane },
    { colors = { tab_bar = {} } },
    false,
    24
  )
  local text = {}
  for _, run in ipairs(runs) do
    if run.Text then text[#text + 1] = run.Text end
  end
  return table.concat(text)
end

eq(
  'codex/renamed thread replaces cwd',
  render {
    title = 'Terminal tab titles',
    process = '/usr/bin/codex',
    user_vars = { agent_kind = 'codex' },
  },
  '  ⬢︎ Terminal tab titles '
)

eq(
  'codex/unnamed thread uses app label',
  render {
    tab_id = 2,
    process = '/usr/bin/codex',
    user_vars = { agent_kind = 'codex' },
  },
  '  ⬢︎ Codex '
)

eq(
  'codex/stale agent identity returns to shell cwd',
  render {
    tab_id = 3,
    title = 'Terminal tab titles',
    process = '/usr/bin/zsh',
    user_vars = { agent_kind = 'codex' },
  },
  '  ⬢︎ chezmoi '
)

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
