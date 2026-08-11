-- Pure, unit-tested tab-title truncation for the wezterm config.
-- No wezterm dependency: width/truncate are injected so this loads under plain
-- `lua` for testing (see tabtitle.test.lua). Required from wezterm.lua.

local M = {}

-- Compute the visible title for a tab, truncating with an ellipsis when it can't
-- fit its fair share of the tab bar.
--
--   budget    = min(max_chars, floor(window_cols / ntabs)) — a tab's even share,
--               capped so titles don't sprawl on a wide/near-empty bar.
--   title_fit = budget - chrome, chrome = width(marker) + marker_pad — the room
--               left for the title after the fixed leading glyph + its spaces.
--   If width(title) > title_fit, keep (title_fit - 1) columns + '…'.
--
-- Reads ONLY stable inputs (window_cols, ntabs) — never the content-driven
-- max_width wezterm passes to format-tab-title, which feeds back on itself and
-- spirals short titles down to "che…".
--
-- opts: { title, marker, ntabs, window_cols, max_chars, marker_pad,
--         width = fn(s)->cols, truncate = fn(s, n)->string }
function M.compute_tab_title(opts)
  local title       = opts.title
  local marker      = opts.marker or ''
  local ntabs       = math.max(1, opts.ntabs or 1)
  local window_cols = opts.window_cols or 200
  local max_chars   = opts.max_chars or 24
  local marker_pad  = opts.marker_pad or 3
  local width       = opts.width
  local truncate    = opts.truncate

  local budget = math.min(max_chars, math.floor(window_cols / ntabs))
  local chrome = width(marker) + marker_pad
  local title_fit = math.max(3, budget - chrome)

  if width(title) > title_fit then
    title = truncate(title, title_fit - 1) .. '…'
  end
  return title
end

-- Resolve the foreground command for tab styling. Under WSL,
-- foreground_process_name only ever sees the wslhost.exe proxy, never the real
-- process, so prefer the WEZTERM_PROG user var the zsh hooks publish from inside
-- WSL (precmd sets it to "zsh" at the prompt, preexec to the running command
-- line). Fall back to the OS process name for panes without the hook. The sole
-- exception is an explicitly identified Claude/Codex pane behind wslhost.exe:
-- old WSL shells may predate the hook, but their lifecycle user variable still
-- gives an authoritative foreground agent. Returns the command's first word;
-- callers basename it and strip any trailing .exe.
function M.resolve_foreground(user_vars, foreground_process_name)
  user_vars = user_vars or {}
  local prog = user_vars.WEZTERM_PROG
  if prog and prog ~= '' then
    return prog:match('^%S+') or prog
  end
  local foreground = foreground_process_name or ''
  local basename = (foreground:match('[^/\\]+$') or foreground):lower()
  local agent = user_vars.agent_kind
  if basename == 'wslhost.exe' and (agent == 'claude' or agent == 'codex') then
    return agent
  end
  return foreground
end

-- Body of a non-agent ("plain") tab title. `proc_name` is the resolved
-- foreground process, already basenamed with any trailing .exe stripped.
--   - shell / empty proc          → bare cwd basename
--   - idle PowerShell (Windows)    → "pwsh: cwd" (distinct from bare-cwd WSL
--                                    shells; only reachable when proc_name is
--                                    pwsh/powershell, i.e. never on macOS/Linux)
--   - known app (in app_icons)     → bare cwd (its marker glyph already names it)
--   - any other command            → "cwd: command" (from the raw pane title)
function M.plain_tab_title(proc_name, basename, pane_title, app_icons)
  local shells = { bash=1, sh=1, zsh=1, fish=1, nu=1, login=1 }
  if proc_name == 'pwsh' or proc_name == 'powershell' then
    return basename ~= '' and ('pwsh: ' .. basename) or 'pwsh'
  end
  if proc_name ~= '' and not shells[proc_name] then
    if app_icons[proc_name] then
      return basename
    end
    return basename .. ': ' .. (pane_title or proc_name)
  end
  return basename
end

return M
