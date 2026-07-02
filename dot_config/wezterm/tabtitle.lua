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

return M
