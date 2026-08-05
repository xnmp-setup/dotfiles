-- Tab titles, application markers, agent animation and focus-aware repainting.
local wezterm = require 'wezterm'
local compute_tab_title = require('tabtitle').compute_tab_title

local M = {}

function M.setup(deps)
  local agent = deps.agent
  local STATUS_UPDATE_INTERVAL_MS = deps.status_update_interval_ms
  local now_ms = agent.now_ms
  local track_animation = agent.track_animation
  local agent_status_of = agent.status_of
  local agent_of_pane = agent.of_pane

  -- Last rendered title protects overlay panes from blank-title flicker.
  local last_tab_title = {}

  -- Per-window focus state lets active tabs in unfocused windows render inactive.
  local window_focus = {}

  -- ---------- Tab bar styling ----------
  -- Agent session status, set per-pane via the OSC 1337 SetUserVar "agent_status"
  -- escape sequence emitted by ~/.local/bin/wezterm-agent-status. Drives a leading
  -- glyph + tab tint so you can see at a glance which tabs are working vs waiting.
  -- Each state has an emphasized active bg and a dulled inactive bg.
  local STATUS_STYLE = {
    working   = { glyph = '', active_bg = '#4C6B8A', inactive_bg = '#2C3E50' },
    -- stopped / turn finished: claude orange (matches the no-status fallback).
    -- No glyph — the claude icon in the title already marks these tabs.
    done      = { glyph = '', active_bg = '#C0623A', inactive_bg = '#7A3D24' },
    -- vivid saturated red, kept distinct from the muted claude-orange "done"
    attention = { glyph = '', active_bg = '#E5252B', inactive_bg = '#8A1418' },
  }

  -- Per-app tab icons for non-claude tabs. Keyed by the foreground process
  -- basename (what pane:get_foreground_process_name reports, sans path/.exe).
  -- When a running command matches, its Nerd Font glyph replaces the default ❯
  -- prompt marker so you can tell editor/git/file-manager/… tabs apart at a
  -- glance. All glyphs are from Hack Nerd Font (configured in wezterm_appearance);
  -- text-default codepoints so they take our marker_fg tint, not emoji coloring.
  -- App choices seeded from the user's atuin history (micro, keifu/gg, yazi,
  -- zellij, docker, cargo, bun, python/uv, codex, ssh, vim/nvim, top-tools, git).
  -- Glyphs written as \u{} escapes (NOT raw bytes): raw Nerd Font PUA codepoints
  -- get silently stripped when this file is edited through some tooling, leaving
  -- empty strings that render as no marker. All codepoints verified present in
  -- Hack Nerd Font (the window_frame fallback).
  local APP_ICONS = {
    -- editors
    micro = '\u{eae9}',  nano = '\u{eae9}',  vim = '\u{e62b}',  nvim = '\u{e62b}',  vi = '\u{e62b}',
    hx = '\u{f0e7}',  helix = '\u{f0e7}',  emacs = '\u{e632}',
    -- git / version control (keifu is the user's `gg` git TUI)
    keifu = '\u{e725}',  git = '\u{e702}',  lazygit = '\u{e702}',  gitui = '\u{e702}',  tig = '\u{e702}',
    -- file managers
    yazi = '\u{ea83}',  ranger = '\u{ea83}',  nnn = '\u{ea83}',  lf = '\u{ea83}',  broot = '\u{ea83}',
    -- multiplexers / sessions
    zellij = '\u{f489}',  tmux = '\u{ebc7}',  screen = '\u{ebc7}',
    -- containers / infra
    docker = '\u{f308}',  ['docker-compose'] = '\u{f308}',  kubectl = '\u{f10fe}',  k9s = '\u{f10fe}',
    -- languages / runtimes
    cargo = '\u{e7a8}',  rustc = '\u{e7a8}',  bun = '\u{e76f}',  node = '\u{e718}',  deno = '\u{e718}',
    python = '\u{e606}',  python3 = '\u{e606}',  uv = '\u{e606}',  ['python3.12'] = '\u{e606}',
    go = '\u{e626}',  ruby = '\u{e739}',  lua = '\u{e620}',
    -- ai clis
    codex = '\u{f0ea0}',  openclaw = '\u{f0ea0}',
    -- remote / net
    ssh = '\u{f08c0}',  mosh = '\u{f08c0}',  ping = '\u{f0200}',  curl = '\u{f0ee}',  wget = '\u{f0ee}',
    -- monitors
    htop = '\u{f0e4}',  btop = '\u{f0e4}',  top = '\u{f0e4}',  btm = '\u{f0e4}',
    -- misc common
    fzf = '\u{f422}',  rg = '\u{f422}',  make = '\u{e673}',  bat = '\u{f0e7}',  less = '\u{f15c}',
    man = '\u{f02d}',  brew = '\u{f0f4}',  psql = '\u{e76e}',  redis = '\u{e76d}',  sqlite3 = '\u{e7c4}',
  }

  -- Per-agent tab markers. Shape identifies the agent; color identifies whether it
  -- is working, idle or waiting for input. Working markers animate from wall-clock
  -- time; their repaint signal uses only the local animated_panes cache.
  -- Every glyph carries VARIATION SELECTOR-15 (\u{FE0E}) to force TEXT presentation
  -- — bare shapes in these blocks can render as emoji that ignore our color. All of
  -- them come from Adwaita Mono, the third window_frame fallback (Inter and Hack
  -- Nerd Font have none of these codepoints), same as the Claude stars always have.
  --
  -- Adding an agent = one entry here plus one branch in agent_of_pane.
  local function pingpong(ramp)
    local result = {}
    for i = 1, #ramp do result[#result + 1] = ramp[i] end
    for i = #ramp - 1, 2, -1 do result[#result + 1] = ramp[i] end
    return result
  end

  local function frame_at(now, ramp, period_ms)
    return ramp[(math.floor(now / period_ms) % #ramp) + 1]
  end

  local GLYPH_MS = 333
  local COLOR_MS = 250
  local SHIMMER_MS = 60

  local AGENT_MARKERS = {
    claude = {
      idle       = '❋\u{FE0E}',  -- U+274B heavy eight-teardrop asterisk
      idle_fg    = '#C0623A',    -- claude orange (matches STATUS_STYLE.done)
      -- Needs input: a CHUNKIER star than idle — ✹ (U+2739, twelve-pointed filled
      -- black star) is denser than the ❋ outline, so the tab stands out twice over
      -- (shape + red).
      attention  = '✹\u{FE0E}',
      frames = pingpong({
        '✢\u{FE0E}', '✶\u{FE0E}', '✻\u{FE0E}', '✽\u{FE0E}',
      }),
      colors = pingpong({
        '#4a7fd6', '#4aa6c8', '#3fb8a8', '#4fc785', '#63d46b',
      }),
    },
    codex = {
      idle       = '⬢\u{FE0E}',  -- U+2B22 black hexagon — OpenAI's mark is hexagonal
      idle_fg    = '#B23A48',    -- muted crimson
      attention  = '⬣\u{FE0E}',  -- U+2B23 horizontal black hexagon: wider, denser
      frames = pingpong({
        '⬩\u{FE0E}', '⬦\u{FE0E}', '◈\u{FE0E}', '⬥\u{FE0E}',
      }),
      colors = pingpong({
        '#0E8C6E', '#10A37F', '#1FBF93', '#45D6A8', '#6FE8C0',
      }),
    },
  }

  local function shimmer_grey(lo, hi, amount, dither)
    local value = math.floor(lo + (hi - lo) * amount + 0.5)
    return string.format('#%02x%02x%02x', value, value, value - dither)
  end

  local function shimmer_runs(title, phase, is_active)
    local lo, hi = is_active and 0xcc or 0x8e, is_active and 0xff or 0xbe
    local runs = {}
    local index = 0
    for _, codepoint in utf8.codes(title) do
      local wave = (math.cos((index - phase) * 0.5) + 1) / 2
      runs[#runs + 1] = {
        Foreground = {
          Color = shimmer_grey(lo, hi, wave, index % 2),
        },
      }
      runs[#runs + 1] = { Text = utf8.char(codepoint) }
      index = index + 1
    end
    return runs
  end

  wezterm.on('format-tab-title', function(tab, tabs, panes, cfg, hover, max_width)
    local pane_info = tab.active_pane
    local title = pane_info.title or ''
    local proc = pane_info.foreground_process_name or ''

    -- An active tab in an unfocused window should look inactive: fold the window's
    -- focus state into is_active so all the styling below (intensity, underline,
    -- bg tint) dims to match the greyed-out window contents. focus default is nil
    -- (treated as focused) so tabs don't dim before the first focus event.
    local window_focused = window_focus[tab.window_id] ~= false
    local is_active = tab.is_active and window_focused

    -- Overlays (InputSelector, etc.) replace the active pane with one that has no
    -- cwd and no foreground process. Fall back to the last known rendered title.
    if not pane_info.current_working_dir and (proc == '' or proc == nil) then
      local cached = last_tab_title[tostring(tab.tab_id)]
      if cached then
        return cached
      end
    end

    -- Which agent (if any) owns this pane. `agent` drives the status marker for
    -- both Claude and Codex; `is_claude` additionally drives the TITLE source,
    -- because only Claude's pane title is a useful label (its current task).
    -- Codex titles its pane with its own run-state text, which duplicates what our
    -- marker already says, so codex tabs take the normal cwd path below.
    local agent = agent_of_pane(proc, pane_info.user_vars)
    local is_claude = agent == 'claude'

    -- On exit Claude blanks its pane title (renders as a lone "_") for a frame
    -- before the shell repaints. proc still reads "claude" that frame, so the
    -- overlay guard above misses it (it requires no proc) and we'd flash an
    -- orange "_" tab. Treat a blank title while proc is still "claude" as the
    -- teardown frame and render it as a normal shell tab (cwd, black bg) right
    -- away, instead of holding the orange claude styling until the shell repaints.
    if is_claude and (title == '' or title == '_') then
      is_claude = false
      agent = nil
      proc = ''  -- so the branch below takes the plain-cwd path, not "cwd: _"
    end

    -- For non-claude tabs, show "cwd" or "cwd: command" if a process is running
    if not is_claude then
      local cwd = pane_info.current_working_dir
      local basename = ''
      if cwd then
        local path
        if type(cwd) == 'userdata' then
          -- Url object. file_path (already decoded) is nil when the OSC-7 host !=
          -- local host, so fall back to the percent-encoded .path and decode that.
          -- Never call string methods on the userdata, or the handler errors and
          -- wezterm shows the raw full-path title.
          path = cwd.file_path
          if not path or path == '' then
            path = (cwd.path or ''):gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
          end
        else
          -- Legacy string form: "file://host/path"
          path = tostring(cwd):gsub('^file://[^/]*', '')
        end
        path = path:gsub('[/\\]+$', '')
        basename = path:match('[^/\\]+$') or path
      end

      local proc_name = (proc:match('[^/\\]+$') or ''):gsub('%.exe$', '')
      local shells = { bash=1, sh=1, zsh=1, fish=1, nu=1, login=1 }
      if proc_name ~= '' and not shells[proc_name] then
        if APP_ICONS[proc_name] then
          -- Known app: its marker icon (set below) already names the app, so show
          -- just the cwd — no redundant "cwd: micro". Reading an editor's argv to
          -- recover its filename is intentionally avoided in this GUI-thread hook.
          title = basename
        else
          -- Unknown command — show "cwd: command args" from pane title.
          -- pane title is usually set to the running command by the shell.
          local cmd = pane_info.title or proc_name
          title = basename .. ': ' .. cmd
        end
      else
        title = basename
      end
    end

    -- Append pane count if more than one
    local pane_count = #tab.panes
    if pane_count > 1 then
      title = title .. ' (' .. pane_count .. ')'
    end

    -- Fancy tab bar renders each tab as its own rounded button and only fills the
    -- whole button from the static config.colors.tab_bar.* palette — a per-tab
    -- Background here paints just a rectangle behind the text, not the tab. So
    -- instead of tinting the tab bg, we lead with a colored status dot: claude
    -- tabs get an orange dot (or the working/attention status color), plain tabs
    -- get none. Underline marks the active tab; the button bg stays uniform.
    -- Keep intensity CONSTANT across focus. Previously active=Normal / inactive=Half:
    -- bold (Normal) glyphs are wider, so the same title rendered wider when focused,
    -- changing the visible length and clipping the '…' on the active tab. Fixing the
    -- weight makes width focus-independent; active tabs are still distinguished by
    -- underline, brighter fg, and the active_tab bg color.
    local intensity = 'Normal'
    local underline = is_active and 'Single' or 'None'

    -- Claude Code prefixes its pane title with its own animated spinner — a glyph
    -- (star ✳/✻/✽ or braille ⠐⠓⠋…) that lives in the U+2xxx range = 3-byte UTF-8
    -- starting 0xE2 — sometimes preceded by a "N: " tool/step count. We render our
    -- own marker, so strip both, otherwise two spinners compete. Loop so "3: ⠐ x"
    -- collapses to "x" in one pass.
    if is_claude then
      local changed = true
      while changed do
        changed = false
        -- Leading "N: " count prefix.
        local t = title:gsub('^%s*%d+:%s+', '')
        if t ~= title then title = t; changed = true end
        -- Leading 3-byte-glyph spinner token (0xE2 ...) + trailing space.
        t = title:gsub('^%s*\226[\128-\191][\128-\191]%s+', '')
        if t ~= title then title = t; changed = true end
      end
    end

    -- No custom separator glyph: fancy bar draws its own faint divider between
    -- buttons, and any glyph we add lands *inside* the button (a second, offset
    -- bar). Tab separation instead comes from distinct button bg colors set in
    -- config.colors.tab_bar.* (active vs inactive contrast).
    --
    -- Resolve the leading marker glyph + its color for the current state first, so
    -- we know how many cells it consumes before deciding how much title fits.
    -- Title colors come from the effective config's tab bar palette, which
    -- wezterm_appearance derives from the active color scheme. Read them from
    -- `cfg` (not a value captured at setup) so the "Set Theme..." override is
    -- picked up on the next repaint. Hardcoding white/grey here made titles
    -- unreadable under light schemes.
    local palette = (cfg.colors or {}).tab_bar or {}
    local active_title_fg = (palette.active_tab or {}).fg_color or '#ffffff'
    local inactive_title_fg = (palette.inactive_tab or {}).fg_color or '#aaaaaa'

    local marker, marker_fg, title_fg
    local is_working = false
    if agent then
      local m = AGENT_MARKERS[agent]
      local status = agent_status_of(pane_info.pane_id, pane_info.user_vars)
      track_animation(pane_info.pane_id, tab.window_id, status)
      local style = status and STATUS_STYLE[status]
      if status == 'working' then
        is_working = true
        local now = now_ms()
        marker = frame_at(now, m.frames, GLYPH_MS)
        marker_fg = frame_at(now, m.colors, COLOR_MS)
      elseif status == 'attention' then
        -- Needs input: loud red, and a chunkier glyph than idle, so a tab awaiting
        -- input stands out twice over (shape + color).
        marker = m.attention
        marker_fg = '#F26D64'
      else
        -- done / idle: the agent's own glyph in its own color. Note these are all
        -- text-presentation codepoints — an emoji variant would be font-colored
        -- (e.g. ✳ renders green) and would ignore the tint we set here.
        marker = m.idle
        -- STATUS_STYLE.done carries claude's orange, so only claude reads from it;
        -- every other agent uses its own idle color.
        marker_fg = (agent == 'claude' and style and style.active_bg) or m.idle_fg
      end
      -- Attention also reddens the title text (not just the glyph) so the whole
      -- label shouts. Fancy bar blocks per-tab *background* color but per-item
      -- *foreground* is fine, so red text works here.
      if status == 'attention' then
        title_fg = '#F58A82'
      else
        title_fg = is_active and active_title_fg or inactive_title_fg
      end
    else
      -- Non-agent tabs: default to a terminal prompt glyph (❯ U+276F, text-
      -- presentation, needs no Nerd Font), dimmed so it reads as a marker not part
      -- of the name. If a known app is the foreground process, swap in its Nerd
      -- Font icon (see APP_ICONS) — strip any path and a trailing .exe first.
      local pname = (proc:match('[^/\\]+$') or ''):gsub('%.exe$', '')
      marker = APP_ICONS[pname] or '❯'
      -- Focused: rich saturated blue. Unfocused: muted slate (was grey).
      marker_fg = is_active and '#4a90e2' or '#5a7a9a'
      title_fg = is_active and active_title_fg or inactive_title_fg
    end

    -- Truncate via the pure helper. Use a conservative fixed budget rather than
    -- synchronously querying the mux from this GUI-thread callback.
    title = compute_tab_title {
      title = title,
      marker = marker,
      ntabs = #tabs,
      window_cols = 200,
      max_chars = 24,
      marker_pad = 3,  -- '  ' before + ' ' after the marker
      width = wezterm.column_width,
      truncate = wezterm.truncate_right,
    }

    local result = {
      { Attribute = { Intensity = intensity } },
      { Attribute = { Underline = underline } },
      { Foreground = { Color = marker_fg } },
      { Text = '  ' .. marker .. ' ' },
    }
    if is_working then
      local phase = math.floor(now_ms() / SHIMMER_MS)
      for _, run in ipairs(shimmer_runs(title, phase, is_active)) do
        result[#result + 1] = run
      end
      result[#result + 1] = { Text = ' ' }
    else
      result[#result + 1] = { Foreground = { Color = title_fg } }
      result[#result + 1] = { Text = title .. ' ' }
    end

    last_tab_title[tostring(tab.tab_id)] = result
    return result
  end)

  -- ---------- Dim unfocused windows' tab titles ----------
  -- Record per-window focus state so format-tab-title renders an unfocused
  -- window's active tab with the dulled inactive styling (it gates underline /
  -- intensity on `tab.is_active and window_focused`), then force the tab bar to
  -- repaint immediately.
  --
  -- format-tab-title recomputing does not itself repaint the GUI surface, so write
  -- a focus-specific zero-width right status to invalidate the tab bar. This uses
  -- the same cheap path as the agent animation and avoids the measured ~116-135ms
  -- full config reload previously caused by set_config_overrides. Two characters
  -- distinguish focus invalidations from the animation's one-character payload;
  -- all remain zero-width, so the tab-bar layout is unchanged.
  wezterm.on('window-focus-changed', function(window, pane)
    local focused = window:is_focused()
    window_focus[window:window_id()] = focused

    local payload = focused and '\u{200b}\u{200b}' or '\u{feff}\u{feff}'
    window:set_right_status(wezterm.format({ { Text = payload } }))
  end)

  -- Repaint animated titles from local state only. Entries not observed by a tab
  -- render recently are discarded, covering closed panes and hidden windows
  -- without querying the mux from the GUI event loop.
  wezterm.on('update-status', function(window, pane)
    local now = now_ms()
    local window_id = window:window_id()
    local any_working = agent.window_has_working(window_id, 3000, now)

    local payload = '\u{200b}'
    if any_working and math.floor(now / STATUS_UPDATE_INTERVAL_MS) % 2 == 1 then
      payload = '\u{feff}'
    end
    window:set_right_status(wezterm.format({ { Text = payload } }))
  end)
end

return M
