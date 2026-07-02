-- Tests for tabtitle.compute_tab_title. Run: lua tabtitle.test.lua
-- (from this directory, or `lua dot_config/wezterm/tabtitle.test.lua`).
-- No wezterm needed — width/truncate are injected ASCII stubs.

package.path = (arg[0]:match('(.*/)') or './') .. '?.lua;' .. package.path
local compute = require('tabtitle').compute_tab_title

-- ASCII stubs: 1 col per byte. Good enough for these ASCII test titles and
-- mirrors wezterm.column_width / truncate_right for that case.
local function width(s) return #s end
local function truncate(s, n) return s:sub(1, n) end

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    io.write(string.format('FAIL %s\n  got:  [%s]\n  want: [%s]\n', name, tostring(got), tostring(want)))
  end
end

-- Helper: default marker width 1 (e.g. "❯"), pad 3 → chrome 4.
local function run(t)
  return compute {
    title = t.title,
    marker = t.marker or 'M',          -- width-1 marker stub
    ntabs = t.ntabs or 1,
    window_cols = t.window_cols or 200,
    max_chars = t.max_chars or 24,
    marker_pad = t.marker_pad or 3,
    width = width,
    truncate = truncate,
  }
end

-- 1. Short title, plenty of room: returned unchanged, no ellipsis.
eq('short/roomy', run { title = 'chezmoi', window_cols = 200, ntabs = 1 }, 'chezmoi')

-- 2. Short title "chezmoi" must NOT be truncated even with several tabs, as long
--    as the fair share still fits it. 200/4 = 50 budget → fits.
eq('short/4tabs', run { title = 'chezmoi', window_cols = 200, ntabs = 4 }, 'chezmoi')

-- 3. Long title on a normal window: truncated with an ellipsis. budget =
--    min(24, 200/4=50) = 24; chrome = 1+3 = 4; title_fit = 20; keep 19 + '…'.
--    First 19 chars of "Change WezTerm tab title format" = "Change WezTerm tab ".
eq('long/4tabs',
   run { title = 'Change WezTerm tab title format', window_cols = 200, ntabs = 4 },
   ('Change WezTerm tab title format'):sub(1, 19) .. '…')

-- 4. The ellipsis must always be present when truncation happens (regression:
--    fancy bar hard-clipped and ate the '…'). Assert last char is '…'.
do
  local out = run { title = 'a really quite long tab title here', window_cols = 200, ntabs = 3 }
  eq('ellipsis-present', out:sub(-3), '…')  -- '…' is 3 bytes in UTF-8
end

-- 5. Narrow window shrinks the budget but never below the floor (title_fit >= 3),
--    so we still get >=2 chars + '…', never an empty or 1-char clip.
do
  local out = run { title = 'chezmoi', window_cols = 12, ntabs = 4 }  -- 12/4 = 3 budget
  eq('narrow-floor-nonempty', #out >= 3, true)
end

-- 6. Budget is capped by max_chars even on a very wide/empty bar: a 40-char title
--    with one tab on a huge window still truncates at 24-cap, not window width.
do
  local long = string.rep('x', 40)
  local out = run { title = long, window_cols = 1000, ntabs = 1, max_chars = 24 }
  -- budget = min(24, 1000) = 24; title_fit = 24-4 = 20; keep 19 + '…'.
  eq('maxchars-cap', out, string.rep('x', 19) .. '…')
end

-- 7. Wider marker (e.g. the 2-col claude star) eats more chrome, leaving less
--    title room. marker width 2, pad 3 → chrome 5; budget 24 → title_fit 19.
do
  local out = compute {
    title = 'Change WezTerm tab title format',
    marker = 'MM', ntabs = 1, window_cols = 200, max_chars = 24, marker_pad = 3,
    width = width, truncate = truncate,
  }
  eq('wide-marker', out, ('Change WezTerm tab title format'):sub(1, 18) .. '…')  -- 18 + '…'
end

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
