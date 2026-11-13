#!/usr/bin/env python3
"""Weekly-quota pace segment for the Claude Code status line.

Reads the status-line JSON on stdin and prints one coloured segment:

    80/120 today · 34/43% wtd

today - today's usage / today's allowance, in units where 100 = one even day
        (1/7 of the weekly limit). The allowance spreads whatever is left at
        the start of today evenly over the remaining days, so frugal days
        earlier in the week raise it above 100 and heavy days lower it.
wtd   - week to date: percent of the 7-day limit used / percent you would
        have used by the end of today at an even pace (day N of 7 -> N/7).

"Days" are 24h slices of the rate-limit window (aligned to its reset time),
not calendar days, because that is how the limit itself rolls over.

Claude Code only reports the current used percentage, so the start-of-day
figure is the last reading taken before the day rolled over. That comes from
the Quickshell desktop bar's quota history when present (it samples the same
payload continuously), else from this script's own small state file. With
neither (first run mid-day) today's usage counts from the first reading. Prints nothing when the payload has no weekly limit
(API-key or third-party-model sessions), so the status line degrades cleanly.
"""
from __future__ import annotations

import json
import math
import os
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Mapping, Optional, Sequence

DAY = 86_400
WEEK_DAYS = 7
# resets_at for one window should be stable, but tolerate small jitter before
# deciding the window has changed (a real reset moves it by days).
SAME_WINDOW_TOLERANCE = 3_600
OVER_FACTOR = 1.0     # above pace -> orange
WAY_OVER_FACTOR = 1.5  # 50% above pace -> red


# ---------------------------------------------------------------- domain ----

@dataclass(frozen=True)
class Reading:
    used: float      # percent of the weekly limit, 0..100
    resets_at: int   # epoch seconds
    now: float       # epoch seconds


@dataclass(frozen=True)
class DayState:
    """What must survive between renders to know today's starting point."""
    resets_at: int
    day: int
    baseline: float  # used % at the start of `day`
    last: float      # most recent used % seen


@dataclass(frozen=True)
class Pace:
    used: float          # weekly used %
    on_track: float      # weekly % an even pace allows by the end of today
    day_used: float      # today's usage, 100 = one even day
    day_quota: float     # today's allowance, same units


def day_index(reading: Reading) -> int:
    """0-based day of the 7-day window that `reading.now` falls in."""
    start = reading.resets_at - WEEK_DAYS * DAY
    return min(WEEK_DAYS - 1, max(0, int((reading.now - start) // DAY)))


def day_start(reading: Reading, day: int) -> float:
    return reading.resets_at - (WEEK_DAYS - day) * DAY


def baseline_from_history(samples: Sequence, reading: Reading) -> Optional[float]:
    """Used % at the start of today, from (epoch, used%, ...) samples.

    Takes the last sample at or before today's start, provided it falls inside
    this window (an older one belongs to the previous week). None when no such
    sample exists, so the caller falls back to its own state.
    """
    day = day_index(reading)
    start = day_start(reading, day)
    window_start = day_start(reading, 0)
    if day == 0:
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
        if window_start <= at <= start and (best is None or at >= best[0]):
            best = (at, used)
    return None if best is None else float(max(0.0, min(100.0, best[1])))


def advance_state(
    prev: Optional[DayState],
    reading: Reading,
    history_baseline: Optional[float] = None,
) -> DayState:
    """Fold a new reading into the persisted day state.

    `history_baseline`, when known, is an observed start-of-day reading and
    beats anything inferred from `prev`.
    """
    day = day_index(reading)
    same_window = (
        prev is not None
        and abs(prev.resets_at - reading.resets_at) <= SAME_WINDOW_TOLERANCE
    )
    if history_baseline is not None:
        baseline = history_baseline
    elif same_window and prev.day == day:
        baseline = prev.baseline
    elif same_window and prev.day < day:
        # Last reading before the rollover is the best start-of-day estimate.
        baseline = prev.last
    elif day == 0 and not same_window:
        # A fresh window starts empty.
        baseline = 0.0
    else:
        # No usable history: count today from now.
        baseline = reading.used
    # Usage in a fixed window never decreases; clamp so a stale baseline can't
    # produce negative daily usage.
    baseline = min(baseline, reading.used)
    return DayState(reading.resets_at, day, baseline, reading.used)


def compute_pace(reading: Reading, state: DayState) -> Pace:
    days_left = WEEK_DAYS - state.day  # including today, >= 1
    even_day = 100.0 / WEEK_DAYS
    return Pace(
        used=reading.used,
        on_track=(state.day + 1) * even_day,
        day_used=(reading.used - state.baseline) / even_day * 100.0,
        day_quota=max(0.0, 100.0 - state.baseline) / days_left / even_day * 100.0,
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

    wk = seg(
        "wtd",
        f"{round(pace.used)}/{round(pace.on_track)}%",
        severity(pace.used, pace.on_track),
    )
    day = seg(
        "today",
        f"{round(pace.day_used)}/{round(pace.day_quota)}",
        severity(pace.day_used, pace.day_quota),
    )
    sep = f"\x1b[38;5;{p['label']}m · \x1b[0m"
    return f"{day}{sep}{wk}"


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


def parse_reading(payload: object, now: float) -> Optional[Reading]:
    """Weekly reading from the status-line payload, or None if absent/invalid."""
    if not isinstance(payload, Mapping):
        return None
    limits = payload.get("rate_limits")
    week = limits.get("seven_day") if isinstance(limits, Mapping) else None
    if not isinstance(week, Mapping):
        return None
    used = week.get("used_percentage")
    resets_at = _epoch(week.get("resets_at"))
    if isinstance(used, bool) or not isinstance(used, (int, float)) or not math.isfinite(used):
        return None
    if resets_at is None or resets_at <= now:
        return None  # expired window: the reading no longer describes this week
    return Reading(used=float(max(0.0, min(100.0, used))), resets_at=resets_at, now=now)


# ---------------------------------------------------------- persistence -----

def state_path() -> Path:
    root = os.environ.get("XDG_STATE_HOME", "").strip() or os.path.join(
        os.path.expanduser("~"), ".local", "state"
    )
    return Path(root) / "claude-statusline" / "quota-pace.json"


def load_state(path: Path) -> Optional[DayState]:
    try:
        raw = json.loads(path.read_text())
        return DayState(
            resets_at=int(raw["resets_at"]),
            day=int(raw["day"]),
            baseline=float(raw["baseline"]),
            last=float(raw["last"]),
        )
    except (OSError, ValueError, KeyError, TypeError):
        return None


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


def save_state(path: Path, state: DayState) -> None:
    # Several sessions render concurrently; write-then-rename keeps the file
    # whole for readers. Last writer wins, which is fine for monotonic usage.
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".quota-pace.")
        with os.fdopen(fd, "w") as f:
            json.dump(state.__dict__, f)
        os.replace(tmp, path)
    except OSError:
        pass


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
    path = state_path()
    prev = load_state(path)
    state = advance_state(prev, reading, baseline_from_history(load_history(history_path()), reading))
    if state != prev:
        save_state(path, state)
    sys.stdout.write(render(compute_pace(reading, state), theme))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
