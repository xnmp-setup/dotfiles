-- Behavioral tests for wezterm_tabbar.lua. Run: lua wezterm_tabbar.test.lua
-- A small WezTerm stub verifies the rendered tab text without a GUI.

package.path = (arg[0]:match('(.*/)') or './') .. '?.lua;' .. package.path

local callbacks = {}
local clock_ms = 1000
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
  now_ms = function() return clock_ms end,
  track_animation = function() end,
  status_of = function(_, user_vars) return (user_vars or {}).agent_status or 'done' end,
  of_pane = function(process, user_vars)
    local kind = (user_vars or {}).agent_kind
    if kind == 'claude' or kind == 'codex' then return kind end
    process = (process or ''):lower()
    if process:find('claude') then return 'claude' end
    if process:find('codex') then return 'codex' end
  end,
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

local function rendered(spec)
  local active_pane = {
    pane_id = 7,
    title = spec.title or '',
    foreground_process_name = spec.process,
    current_working_dir = spec.cwd or 'file://host/work/chezmoi',
    user_vars = spec.user_vars or {},
  }
  local tab = {
    tab_id = spec.tab_id or 1,
    window_id = spec.window_id or 1,
    is_active = spec.is_active ~= false,
    active_pane = active_pane,
    panes = { active_pane },
  }
  local runs = callbacks['format-tab-title'](
    tab,
    { tab },
    { active_pane },
    spec.config or { colors = { tab_bar = {} } },
    false,
    24
  )
  local text = {}
  local marker
  local marker_fg
  local title_fg
  local current_fg
  for _, run in ipairs(runs) do
    if run.Foreground then current_fg = run.Foreground.Color end
    if run.Text then
      text[#text + 1] = run.Text
      if not marker then
        marker = run.Text:match('^  (.-) $')
        marker_fg = current_fg
      else
        title_fg = current_fg
      end
    end
  end
  return {
    marker = marker,
    marker_fg = marker_fg,
    title_fg = title_fg,
    text = table.concat(text),
  }
end

local function render(spec)
  return rendered(spec).text
end

-- Fancy-tab backgrounds follow tab selection, not window focus. A selected tab
-- must therefore retain the active foreground when the window loses focus;
-- otherwise light active surfaces such as Nord's become low-contrast grey-on-grey.
local nord_config = {
  colors = {
    tab_bar = {
      active_tab = { bg_color = '#484e59', fg_color = '#d8dee9' },
      inactive_tab = { bg_color = '#2e3440', fg_color = '#9ca3ae' },
    },
  },
}
local unfocused_window = {
  is_focused = function() return false end,
  window_id = function() return 91 end,
  set_right_status = function() end,
}
callbacks['window-focus-changed'](unfocused_window, {})
eq(
  'selected title keeps foreground matched to its active background when window is unfocused',
  rendered { window_id = 91, config = nord_config }.title_fg,
  '#d8dee9'
)
eq(
  'unselected title uses the inactive palette',
  rendered { window_id = 91, is_active = false, config = nord_config }.title_fg,
  '#9ca3ae'
)

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
  'codex/blank unnamed thread uses cwd',
  render {
    tab_id = 2,
    process = '/usr/bin/codex',
    user_vars = { agent_kind = 'codex' },
  },
  '  ⬢︎ chezmoi '
)

eq(
  'codex/startup before first hook uses marker and cwd',
  render {
    tab_id = 3,
    process = '/usr/bin/codex',
  },
  '  ⬢︎ chezmoi '
)

eq(
  'codex/WSL proxy with lifecycle identity uses marker and cwd',
  render {
    tab_id = 31,
    title = 'wslhost.exe',
    process = 'C:\\Windows\\System32\\wslhost.exe',
    cwd = 'file://host/work/my-project/',
    user_vars = { agent_kind = 'codex' },
  },
  '  ⬢︎ my-project '
)

eq(
  'claude/WSL proxy with lifecycle identity uses marker and cwd',
  render {
    tab_id = 32,
    title = 'wslhost.exe',
    process = 'C:\\Windows\\System32\\wslhost.exe',
    cwd = 'file://host/work/my-project/',
    user_vars = { agent_kind = 'claude' },
  },
  '  ❋︎ my-project '
)

local thread_id = '019fd540-6ed7-72a1-8ead-1234567890ab'
eq(
  'codex/default thread id uses cwd',
  render {
    tab_id = 4,
    title = thread_id,
    process = '/usr/bin/codex',
    cwd = 'file://host/work/my-project/',
    user_vars = { agent_kind = 'codex', agent_session_id = thread_id },
  },
  '  ⬢︎ my-project '
)

eq(
  'codex/default thread id before first hook uses cwd',
  render {
    tab_id = 5,
    title = thread_id,
    process = '/usr/bin/codex',
  },
  '  ⬢︎ chezmoi '
)

local next_thread_id = '119fd540-6ed7-72a1-8ead-1234567890ab'
eq(
  'codex/re-entered session ignores stale previous thread id',
  render {
    tab_id = 6,
    title = next_thread_id,
    process = '/usr/bin/codex',
    user_vars = { agent_kind = 'codex', agent_session_id = thread_id },
  },
  '  ⬢︎ chezmoi '
)

clock_ms = 0
local working_codex_first = rendered {
  tab_id = 7,
  title = 'Terminal tab titles',
  process = '/usr/bin/codex',
  user_vars = { agent_kind = 'codex', agent_status = 'working' },
}
clock_ms = 400
local working_codex_second = rendered {
  tab_id = 7,
  title = 'Terminal tab titles',
  process = '/usr/bin/codex',
  user_vars = { agent_kind = 'codex', agent_status = 'working' },
}
eq('codex/working marker animates/first glyph', working_codex_first.marker, '⬩︎')
eq('codex/working marker animates/second glyph', working_codex_second.marker, '⬦︎')
eq('codex/working marker animates/first color', working_codex_first.marker_fg, '#0E8C6E')
eq('codex/working marker animates/second color', working_codex_second.marker_fg, '#1FBF93')

eq(
  'codex/stale agent identity returns to shell caret',
  render {
    tab_id = 8,
    title = 'Terminal tab titles',
    process = '/usr/bin/zsh',
    user_vars = { agent_kind = 'codex' },
  },
  '  ❯ chezmoi '
)

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
