#!/usr/bin/env python3
"""Quota pace segment for the Claude Code status line.

Reads the status-line JSON on stdin and prints one coloured segment:

    80/120 today · 34/43% wtd · 12/18 hr

All three x/y pairs compare usage with an allowance. "hr" and "today" share
one unit: 100 = one even day, i.e. 1/7 of the weekly limit.

hr    - usage over the last 60 minutes / the hourly rate that would use up the
        rest of the current 5-hour window just as it resets.
today - usage since local midnight / today's allowance. The allowance spreads
        whatever weekly quota was left at midnight evenly over the time until
        the weekly reset, and takes today's share; frugal days earlier in the
        week raise it above 100, heavy days lower it.
wtd   - week to date: percent of the 7-day limit used / percent an even pace
        would have used by the end of today.

Units: Claude Code reports the 5-hour and weekly limits as separate
percentages with no stated exchange rate, so the script learns one from how
the two move together (weekly %-points per 5-hour %-point), starting from a
prior of 1/8 until it has seen enough usage.

Claude Code only reports current percentages, so the start-of-day figure is
the last reading taken before midnight. That comes from the Quickshell desktop
bar's quota history when present (it samples the same payload continuously),
else from this script's own small state file. With neither (first run
mid-day) today's usage counts from the first reading. If the weekly window
itself rolled over today, "today" starts at the rollover: usage counted
against the previous week is not carried into the new one.

Prints nothing when the payload has no weekly limit (API-key or third-party
model sessions), and omits "hr" when there is no 5-hour data, so the status
line degrades cleanly.
"""
from __future__ import annotations

import json
import math
import os
import sys
import tempfile
import time
from dataclasses import asdict, dataclass
from datetime import datetime, time as dtime, timedelta, tzinfo
from pathlib import Path
from typing import Mapping, Optional, Sequence

HOUR = 3_600
DAY = 86_400
WEEK_DAYS = 7
WEEK = WEEK_DAYS * DAY
FIVE_HOURS = 5 * HOUR
# Display units per weekly %-point: 100 units = one even day = 100/7 %.
UNITS_PER_WEEK_PCT = float(WEEK_DAYS)
# resets_at for one window should be stable, but tolerate small jitter before
# deciding the window has changed (a real reset moves it by hours or days).
SAME_WINDOW_TOLERANCE = 600
# Weekly %-points per 5-hour %-point. The prior is what a Max plan showed in
# practice (one full 5-hour window ~ 1/8 of the week); it is replaced by the
# observed rate as usage accumulates.
PRIOR_RATIO = 0.125
PRIOR_WEIGHT = 10.0     # prior counts as this many 5-hour %-points observed
RATIO_MEMORY = 400.0    # keep roughly the last four full windows of evidence
SAMPLE_SPACING = 60     # seconds between stored hourly samples
OVER_FACTOR = 1.0       # above pace -> orange
WAY_OVER_FACTOR = 1.5   # 50% above pace -> red
STATE_VERSION = 2


# ---------------------------------------------------------------- domain ----

@dataclass(frozen=True)
class Window:
    used: float      # percent of the limit, 0..100
    resets_at: int   # epoch seconds


@dataclass(frozen=True)
class Reading:
    week: Window
    now: float                       # epoch seconds
    five: Optional[Window] = None    # None: no active 5-hour window


@dataclass(frozen=True)
class DayState:
    """What must survive between renders to know today's starting point."""
    resets_at: int
    day_start: int   # epoch where "today" begins (midnight, or window start)
    baseline: float  # weekly used % at day_start
    last: float      # highest weekly used % seen this window


@dataclass(frozen=True)
class HourState:
    """Running 5-hour consumption, for last-hour usage and the unit ratio."""
    five_resets_at: int
    five_peak: float       # highest 5-hour % seen in that window
    week_resets_at: int
    week_peak: float       # highest weekly % seen in that window
    consumed: float        # cumulative 5-hour %-points used, across windows
    samples: tuple         # ((epoch, consumed), ...) oldest first
    ratio_week: float      # weekly %-points observed alongside...
    ratio_five: float      # ...this many 5-hour %-points


@dataclass(frozen=True)
class Pace:
    used: float                         # weekly used %
    on_track: float                     # weekly % an even pace allows by end of today
    day_used: float                     # today's usage, 100 = one even day
    day_quota: float                    # today's allowance, same units
    hour_used: Optional[float] = None   # last hour's usage, same units
    hour_quota: Optional[float] = None  # hourly rate that exactly uses up the 5-hour window


def _same(a: int, b: int) -> bool:
    return abs(a - b) <= SAME_WINDOW_TOLERANCE


def local_day(now: float, tz: Optional[tzinfo] = None) -> tuple:
    """(start, end) epochs of the calendar day containing `now`.

    tz=None means the system's local zone. Days around DST changes are 23 or
    25 hours long, which this honours.
    """
    date = datetime.fromtimestamp(now, tz).date()
    start = datetime.combine(date, dtime(), tzinfo=tz)
    end = datetime.combine(date + timedelta(days=1), dtime(), tzinfo=tz)
    return start.timestamp(), end.timestamp()


def today_span(week: Window, now: float, tz: Optional[tzinfo] = None) -> tuple:
    """Today's (start, end), clipped to the weekly window."""
    midnight, next_midnight = local_day(now, tz)
    return max(midnight, week.resets_at - WEEK), min(next_midnight, week.resets_at)


def baseline_from_history(samples: Sequence, week: Window, day_start: float) -> Optional[float]:
    """Weekly used % at `day_start`, from (epoch, used%, ...) samples.

    Takes the last sample at or before day_start, provided it falls inside
    this window (an older one belongs to the previous week). None when no such
    sample exists, so the caller falls back to its own state.
    """
    window_start = week.resets_at - WEEK
    if day_start <= window_start:
        return 0.0
    best = None
    for sample in samples:
        if not isinstance(sample, Sequence) or isinstance(sample, (str, bytes)) or len(sample) < 2:
            continue
        at, used = sample[0], sample[1]
        if any(isinstance(v, bool) or not isinstance(v, (int, float)) for v in (at, used)):
            continue
        if not (math.isfinite(at) and math.isfinite(used)):
            continue
        if window_start <= at <= day_start and (best is None or at >= best[0]):
            best = (at, used)
    return None if best is None else float(max(0.0, min(100.0, best[1])))


def advance_day(
    prev: Optional[DayState],
    week: Window,
    day_start: float,
    history_baseline: Optional[float] = None,
) -> DayState:
    """Fold a new weekly reading into the persisted day state.

    `history_baseline`, when known, is an observed start-of-day reading and
    beats anything inferred from `prev`.
    """
    start = int(day_start)
    same_window = prev is not None and _same(prev.resets_at, week.resets_at)
    # Usage in a fixed window never decreases; a lower reading is a stale
    # payload from another session, so track the high-water mark.
    last = max(prev.last, week.used) if same_window else week.used
    if history_baseline is not None:
        baseline = history_baseline
    elif same_window and prev.day_start == start:
        baseline = prev.baseline
    elif same_window and prev.day_start < start:
        # Last reading before midnight is the best start-of-day estimate.
        baseline = prev.last
    elif start <= week.resets_at - WEEK:
        # The window began today, and a fresh window starts empty.
        baseline = 0.0
    else:
        # No usable history: count today from now.
        baseline = week.used
    return DayState(week.resets_at, start, min(baseline, last), last)


def advance_hour(prev: Optional[HourState], reading: Reading) -> Optional[HourState]:
    """Fold a new reading into the 5-hour consumption state."""
    five, week, now = reading.five, reading.week, reading.now
    if five is None:
        return prev
    if prev is None:
        return HourState(
            five.resets_at, five.used, week.resets_at, week.used,
            consumed=0.0, samples=((now, 0.0),), ratio_week=0.0, ratio_five=0.0,
        )
    same_five = _same(prev.five_resets_at, five.resets_at)
    same_week = _same(prev.week_resets_at, week.resets_at)
    # High-water deltas: stale lower readings add nothing; a new window
    # started from zero, so everything it shows is new usage.
    d_five = max(0.0, five.used - prev.five_peak) if same_five else five.used
    d_week = max(0.0, week.used - prev.week_peak) if same_week else week.used
    ratio_week, ratio_five = prev.ratio_week, prev.ratio_five
    if same_five and same_week:
        # Only intervals inside both windows tell us the exchange rate.
        ratio_week, ratio_five = ratio_week + d_week, ratio_five + d_five
        if ratio_five > RATIO_MEMORY:
            scale = RATIO_MEMORY / ratio_five
            ratio_week, ratio_five = ratio_week * scale, ratio_five * scale
    consumed = prev.consumed + d_five
    return HourState(
        five_resets_at=five.resets_at,
        five_peak=max(prev.five_peak, five.used) if same_five else five.used,
        week_resets_at=week.resets_at,
        week_peak=max(prev.week_peak, week.used) if same_week else week.used,
        consumed=consumed,
        samples=_record_sample(prev.samples, now, consumed),
        ratio_week=ratio_week,
        ratio_five=ratio_five,
    )


def _record_sample(samples: tuple, now: float, consumed: float) -> tuple:
    kept = tuple(s for s in samples if s[0] <= now)
    if not kept or now - kept[-1][0] >= SAMPLE_SPACING:
        kept = kept + ((now, consumed),)
    # Keep the last hour plus one older sample to measure it from.
    older = [i for i, s in enumerate(kept) if s[0] <= now - HOUR]
    return kept[older[-1]:] if older else kept


def week_pct_per_five_pct(state: HourState) -> float:
    return (state.ratio_week + PRIOR_RATIO * PRIOR_WEIGHT) / (state.ratio_five + PRIOR_WEIGHT)


def hour_pace(state: Optional[HourState], reading: Reading) -> tuple:
    """(last hour's usage, sustainable hourly rate), in display units."""
    if state is None:
        return None, None
    to_units = week_pct_per_five_pct(state) * UNITS_PER_WEEK_PCT
    before = [c for t, c in state.samples if t <= reading.now - HOUR]
    reference = before[-1] if before else state.samples[0][1]
    used = max(0.0, state.consumed - reference)
    five = reading.five
    if five is None:
        # No window open: the next one starts fresh when usage resumes.
        rate = 100.0 / (FIVE_HOURS / HOUR)
    else:
        hours_left = max(1.0, five.resets_at - reading.now) / HOUR
        rate = max(0.0, 100.0 - state.five_peak) / hours_left
    return used * to_units, rate * to_units


def compute_pace(
    week: Window,
    day: DayState,
    day_end: float,
    hour: tuple = (None, None),
) -> Pace:
    window_start = week.resets_at - WEEK
    remaining_span = max(1.0, week.resets_at - day.day_start)
    today_share = max(0.0, day_end - day.day_start) / remaining_span
    return Pace(
        used=day.last,
        on_track=(day_end - window_start) / WEEK * 100.0,
        day_used=(day.last - day.baseline) * UNITS_PER_WEEK_PCT,
        day_quota=max(0.0, 100.0 - day.baseline) * today_share * UNITS_PER_WEEK_PCT,
        hour_used=hour[0],
        hour_quota=hour[1],
    )


def severity(value: float, allowance: float) -> str:
    """'ok', 'over' (> allowance) or 'way_over' (>= 1.5x allowance)."""
    if allowance <= 0:
        return "way_over" if value > 0 else "ok"
    if value >= allowance * WAY_OVER_FACTOR:
        return "way_over"
    if value > allowance * OVER_FACTOR:
        return "over"
    return "ok"


# ------------------------------------------------------------- rendering ----

PALETTES = {
    "dark": {"label": "245", "ok": "252", "over": "214", "way_over": "203"},
    "light": {"label": "243", "ok": "238", "over": "166", "way_over": "160"},
}


def render(pace: Pace, theme: str = "dark") -> str:
    p = PALETTES.get(theme, PALETTES["dark"])

    def seg(label: str, text: str, level: str) -> str:
        return f"\x1b[38;5;{p[level]}m{text}\x1b[38;5;{p['label']}m {label}\x1b[0m"

    def pair(label: str, used: float, quota: float, suffix: str = "") -> str:
        return seg(label, f"{round(used)}/{round(quota)}{suffix}", severity(used, quota))

    parts = [
        pair("today", pace.day_used, pace.day_quota),
        pair("wtd", pace.used, pace.on_track, "%"),
    ]
    if pace.hour_used is not None and pace.hour_quota is not None:
        parts.append(pair("hr", pace.hour_used, pace.hour_quota))
    sep = f"\x1b[38;5;{p['label']}m · \x1b[0m"
    return sep.join(parts)


# ---------------------------------------------------------------- input -----

def _epoch(raw: object) -> Optional[int]:
    if isinstance(raw, bool):
        return None
    if isinstance(raw, (int, float)) and math.isfinite(raw) and raw > 0:
        return int(raw)
    if isinstance(raw, str) and len(raw) <= 64:
        try:
            parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        except ValueError:
            return None
        if parsed.tzinfo is not None:
            return int(parsed.timestamp())
    return None


def _window(raw: object, now: float) -> Optional[Window]:
    if not isinstance(raw, Mapping):
        return None
    used = raw.get("used_percentage")
    resets_at = _epoch(raw.get("resets_at"))
    if isinstance(used, bool) or not isinstance(used, (int, float)) or not math.isfinite(used):
        return None
    if resets_at is None or resets_at <= now:
        return None  # expired window: the reading no longer describes it
    return Window(used=float(max(0.0, min(100.0, used))), resets_at=resets_at)


def parse_reading(payload: object, now: float) -> Optional[Reading]:
    """Reading from the status-line payload, or None without a weekly limit."""
    if not isinstance(payload, Mapping):
        return None
    limits = payload.get("rate_limits")
    if not isinstance(limits, Mapping):
        return None
    week = _window(limits.get("seven_day"), now)
    if week is None:
        return None
    return Reading(week=week, now=now, five=_window(limits.get("five_hour"), now))


# ---------------------------------------------------------- persistence -----

def state_path() -> Path:
    root = os.environ.get("XDG_STATE_HOME", "").strip() or os.path.join(
        os.path.expanduser("~"), ".local", "state"
    )
    return Path(root) / "claude-statusline" / "quota-pace.json"


def _finite(raw: object) -> float:
    if isinstance(raw, bool) or not isinstance(raw, (int, float)) or not math.isfinite(raw):
        raise ValueError(raw)
    return float(raw)


def _load_day(raw: Mapping) -> DayState:
    return DayState(
        resets_at=int(_finite(raw["resets_at"])),
        day_start=int(_finite(raw["day_start"])),
        baseline=_finite(raw["baseline"]),
        last=_finite(raw["last"]),
    )


def _load_hour(raw: Mapping) -> HourState:
    samples = tuple((_finite(t), _finite(c)) for t, c in raw["samples"][-256:])
    if not samples:
        raise ValueError("no samples")
    return HourState(
        five_resets_at=int(_finite(raw["five_resets_at"])),
        five_peak=_finite(raw["five_peak"]),
        week_resets_at=int(_finite(raw["week_resets_at"])),
        week_peak=_finite(raw["week_peak"]),
        consumed=_finite(raw["consumed"]),
        samples=samples,
        ratio_week=max(0.0, _finite(raw["ratio_week"])),
        ratio_five=max(0.0, _finite(raw["ratio_five"])),
    )


def load_state(path: Path) -> tuple:
    """(DayState | None, HourState | None); each half degrades independently."""
    try:
        raw = json.loads(path.read_text())
    except (OSError, ValueError):
        return None, None
    if not isinstance(raw, Mapping) or raw.get("v") != STATE_VERSION:
        return None, None
    loaded = []
    for key, loader in (("day", _load_day), ("hour", _load_hour)):
        try:
            loaded.append(loader(raw[key]))
        except (ValueError, KeyError, TypeError, IndexError):
            loaded.append(None)
    return tuple(loaded)


def save_state(path: Path, day: DayState, hour: Optional[HourState]) -> None:
    # Several sessions render concurrently; write-then-rename keeps the file
    # whole for readers. Last writer wins: high-water deltas make a lost
    # update cost at most one sample, never double-count.
    payload = {"v": STATE_VERSION, "day": asdict(day), "hour": asdict(hour) if hour else None}
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".quota-pace.")
        with os.fdopen(fd, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, path)
    except OSError:
        pass


def history_path() -> Path:
    # Written by ai-usage-stream (quickshell-statusbar, outside this repo) on
    # each status-line render. Absent on machines without it; then this
    # script relies on its own state file alone.
    root = os.environ.get("XDG_CACHE_HOME", "").strip() or os.path.join(
        os.path.expanduser("~"), ".cache"
    )
    return Path(root) / "statusbar-ai-usage" / "history.json"


def load_history(path: Path) -> list:
    try:
        if path.stat().st_size > 1_048_576:
            return []
        samples = json.loads(path.read_text())["providers"]["claude"]
    except (OSError, ValueError, KeyError, TypeError):
        return []
    return samples if isinstance(samples, list) else []


def main(argv: list) -> int:
    theme = "dark"
    if "--theme" in argv:
        i = argv.index("--theme")
        if i + 1 < len(argv):
            theme = argv[i + 1]
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    reading = parse_reading(payload, time.time())
    if reading is None:
        return 0
    day_start, day_end = today_span(reading.week, reading.now)
    path = state_path()
    prev_day, prev_hour = load_state(path)
    history = baseline_from_history(load_history(history_path()), reading.week, day_start)
    day = advance_day(prev_day, reading.week, day_start, history)
    hour = advance_hour(prev_hour, reading)
    if (day, hour) != (prev_day, prev_hour):
        save_state(path, day, hour)
    pace = compute_pace(reading.week, day, day_end, hour_pace(hour, reading))
    sys.stdout.write(render(pace, theme))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
