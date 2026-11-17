#!/usr/bin/env python3
"""Quota pace segment for the Claude Code status line.

Reads the status-line JSON on stdin and prints one coloured segment:

    80/120 today · 34/43% wtd · 40/80% ses

"today" is in even-day units: 100 = one even day, i.e. 1/7 of the weekly
limit. "ses" is on its own 0..100 scale.

today - usage since local midnight / today's allowance. The allowance spreads
        whatever weekly quota was left at midnight evenly over the time until
        the weekly reset, and takes today's share; frugal days earlier in the
        week raise it above 100, heavy days lower it.
wtd   - week to date: percent of the 7-day limit used / percent an even pace
        would have used by the end of today.
ses   - percent of the 5-hour limit used / percent of the session elapsed
        (the usage that would be on track: 80 with an hour to go).

Where the numbers come from
---------------------------
A status-line payload carries the rate limits from that session's last API
response, with no timestamp: an idle session keeps reporting a figure that
may be days old. So a payload is not a reading of *now*, and the highest or
latest payload is not the current usage.

Readings that do carry an observation time:

anchors - the Quickshell desktop bar polls the usage endpoint and records each
          reading with its fetch time (history v2, outside this repo). Within
          one quota window this series is ordered, so a decrease is a reset:
          Anthropic can reset a limit early without moving its reset time.
updates - a session's reading at the moment it changed. A change means the
          session just got a response, so its render time is its observation
          time. An idle session never changes, so it never counts.

Usage within a window only grows between resets, so every reading taken
since the last reset is a lower bound on the current figure. The estimate is
the latest anchor raised by any later update; the next anchor supersedes it,
so an update can be wrong for at most one poll interval.

A session's first reading (and the rendering payload itself) has no known
age, so it may predate a reset no anchor has shown yet. Such untimed
readings are used only when the window has no anchors at all: without the
bar (other platforms, or it is not running) they and the updates are all
there is. That fallback cannot detect an early reset, so its figures carry on
from before one until the window rolls over.

Days and resets: "today" begins at local midnight, or at the window's start
or a detected reset if later; the allowance and the on-track figure are
measured over the window from that point.

Prints nothing when the payload has no weekly limit (API-key or third-party
model sessions), and omits "ses" when there is no open 5-hour window.
"""
from __future__ import annotations

import contextlib
import json
import math
import os
import sys
import tempfile
import time
from dataclasses import dataclass, replace
from datetime import datetime, time as dtime, timedelta, tzinfo
from pathlib import Path
from typing import Iterator, Mapping, Optional, Sequence

try:
    import fcntl
except ImportError:  # pragma: no cover - not on a POSIX system
    fcntl = None

DAY = 86_400
WEEK_DAYS = 7
WEEK = WEEK_DAYS * DAY
FIVE_HOURS = 5 * 3_600
# Display units per weekly %-point: 100 units = one even day = 100/7 %.
UNITS_PER_WEEK_PCT = float(WEEK_DAYS)
OVER_FACTOR = 1.0       # above pace -> orange
WAY_OVER_FACTOR = 1.5   # 50% above pace -> red
SESSION_WARN = 0.75     # share of the 5-hour limit used -> orange
SESSION_CRITICAL = 0.9  # -> red
# Colouring only: judge pace against at least this much of the session (the
# first half hour), so a first message doesn't flag red against ~0% on track.
SESSION_PACE_FLOOR = 10.0
STATE_VERSION = 3
HISTORY_VERSION = 2
# A session whose reading has not changed for this long is forgotten; if it
# renders again it is a first sighting, whose reading has no known age.
SESSION_TTL = DAY
MAX_SESSIONS = 64
MAX_UPDATES = 2_048
MAX_SESSION_ID = 128


# ---------------------------------------------------------------- domain ----

@dataclass(frozen=True)
class Window:
    used: float      # percent of the limit, 0..100
    resets_at: int   # epoch seconds


@dataclass(frozen=True)
class Reading:
    week: Window
    now: float                       # epoch seconds
    five: Optional[Window] = None    # None: no open 5-hour window
    session_id: Optional[str] = None


@dataclass(frozen=True)
class Point:
    """A window's used %, seen at `at`.

    timed: observed at `at`. Otherwise it was only reported then, and may
    have been observed any time earlier.
    """
    at: float
    used: float
    timed: bool = True


@dataclass(frozen=True)
class Update:
    """A session's reading of one window: when it changed (timed), or when
    the session was first seen (untimed)."""
    at: float
    used: float
    resets_at: int
    timed: bool = True


@dataclass(frozen=True)
class Seen:
    """What one session last reported."""
    at: float          # when that reading first appeared
    week: Window
    five: Optional[Window]


@dataclass(frozen=True)
class State:
    sessions: tuple = ()   # ((session id, Seen), ...)
    week: tuple = ()       # (Update, ...) oldest first
    five: tuple = ()


@dataclass(frozen=True)
class Series:
    """Readings of one quota window, each oldest first."""
    start: float               # when the window opened
    anchors: tuple = ()        # (Point, ...) authoritative, ordered
    updates: tuple = ()        # (Point, ...) session readings

    def usable(self) -> tuple:
        """Updates that can be trusted alongside the anchors (see module doc)."""
        return self.updates if not self.anchors else tuple(p for p in self.updates if p.timed)


@dataclass(frozen=True)
class Pace:
    used: float                         # weekly used %
    on_track: float                     # weekly % an even pace allows by end of today
    day_used: float                     # today's usage, 100 = one even day
    day_quota: float                    # today's allowance, same units
    session_used: Optional[float] = None   # % of the 5-hour limit used (0..100)
    session_quota: Optional[float] = None  # % of the session elapsed: usage on track


def local_day(now: float, tz: Optional[tzinfo] = None) -> tuple:
    """(start, end) epochs of the calendar day containing `now`.

    tz=None means the system's local zone. Days around DST changes are 23 or
    25 hours long, which this honours.
    """
    date = datetime.fromtimestamp(now, tz).date()
    start = datetime.combine(date, dtime(), tzinfo=tz)
    end = datetime.combine(date + timedelta(days=1), dtime(), tzinfo=tz)
    return start.timestamp(), end.timestamp()


def _windows(reading: Reading) -> tuple:
    return (("week", reading.week), ("five", reading.five))


def observe(state: State, reading: Reading) -> State:
    """Fold the rendering session's payload into the state.

    A window whose value differs from what the same session last reported is
    a fresh observation, recorded as a timed update at `reading.now`. A
    session's first sighting is recorded untimed: its payload may be
    arbitrarily old. A window that disappears (it expired) is no change.
    """
    sid = reading.session_id
    if not sid:
        return state  # without an id, sessions cannot be told apart
    sessions = dict(state.sessions)
    prev = sessions.get(sid)
    if prev is not None and (prev.week, prev.five) == (reading.week, reading.five):
        return state  # nothing new; idle sessions cost no state writes
    updates = {"week": state.week, "five": state.five}
    for name, window in _windows(reading):
        if window is not None and (prev is None or window != getattr(prev, name)):
            updates[name] += (Update(reading.now, window.used, window.resets_at, prev is not None),)
    sessions[sid] = Seen(reading.now, reading.week, reading.five)
    return replace(
        state,
        sessions=tuple(sessions.items()),
        week=updates["week"],
        five=updates["five"],
    )


def prune(state: State, now: float) -> State:
    """Drop expired windows' updates and sessions unchanged for a long time
    (if one renders again, it is a first sighting); bound the size."""
    def live(updates: tuple) -> tuple:
        return tuple(u for u in updates if u.resets_at > now)[-MAX_UPDATES:]

    recent = sorted(
        ((sid, seen) for sid, seen in state.sessions if now - seen.at <= SESSION_TTL),
        key=lambda item: item[1].at,
    )[-MAX_SESSIONS:]
    return State(sessions=tuple(recent), week=live(state.week), five=live(state.five))


def series(window: Window, length: float, anchors: Sequence, updates: Sequence, now: float) -> Series:
    """The readings of `window` (which opened `length` before its reset)."""
    start = window.resets_at - length
    return Series(
        start=start,
        anchors=tuple(sorted((p for p in anchors if start <= p.at <= now), key=lambda p: p.at)),
        updates=tuple(sorted(
            (Point(u.at, u.used, u.timed) for u in updates
             if u.resets_at == window.resets_at and start <= u.at <= now),
            key=lambda p: p.at,
        )),
    )


def epoch_start(s: Series) -> float:
    """Start of the current period: the window's start, or its last reset.

    Usage within a window never decreases, so a lower anchor than the one
    before it means the limit was reset in between.
    """
    start = s.start
    for prev, cur in zip(s.anchors, s.anchors[1:]):
        if cur.used < prev.used:
            start = cur.at
    return start


def value_at(s: Series, epoch: float, t: float) -> Optional[float]:
    """Best estimate of used % at `t`: the last anchor at or before it,
    raised by updates since. None when nothing was observed in (epoch, t]."""
    if t <= epoch:
        return 0.0  # the period starts empty
    anchor = next((p for p in reversed(s.anchors) if epoch <= p.at <= t), None)
    since = anchor.at if anchor else epoch
    values = [p.used for p in s.usable() if since < p.at <= t]
    if anchor is not None:
        values.append(anchor.used)
    return max(values, default=None)


def first_after(s: Series, t: float) -> Optional[float]:
    later = [p for p in (*s.anchors, *s.usable()) if p.at > t]
    return min(later, key=lambda p: p.at).used if later else None


def current_used(s: Series, now: float, reported: float) -> float:
    """Used % now; `reported` is the rendering payload's untimed figure."""
    s = replace(s, updates=s.updates + (Point(now, reported, timed=False),))
    known = value_at(s, epoch_start(s), now)
    # With anchors, the latest one is at or before now, so `known` is set.
    return known if known is not None else reported


def compute_pace(
    reading: Reading,
    week: Series,
    five: Optional[Series] = None,
    tz: Optional[tzinfo] = None,
) -> Pace:
    now, resets_at = reading.now, reading.week.resets_at
    epoch = epoch_start(week)
    used = current_used(week, now, reading.week.used)
    midnight, next_midnight = local_day(now, tz)
    day_start, day_end = max(midnight, epoch), min(next_midnight, resets_at)
    start_value = value_at(week, epoch, day_start)
    if start_value is None:
        # Nothing seen before today: count from the earliest reading today,
        # or, on a first ever run, from now.
        start_value = first_after(week, day_start)
    baseline = min(used, used if start_value is None else start_value)
    today_share = max(0.0, day_end - day_start) / max(1.0, resets_at - day_start)
    session_used = session_quota = None
    if five is not None and reading.five is not None:
        session_used = current_used(five, now, reading.five.used)
        session_quota = min(100.0, max(0.0, (now - five.start) / FIVE_HOURS * 100.0))
    return Pace(
        used=used,
        on_track=(day_end - epoch) / max(1.0, resets_at - epoch) * 100.0,
        day_used=(used - baseline) * UNITS_PER_WEEK_PCT,
        day_quota=max(0.0, 100.0 - baseline) * today_share * UNITS_PER_WEEK_PCT,
        session_used=session_used,
        session_quota=session_quota,
    )


def pace_for(reading: Reading, state: State, samples: Sequence, tz: Optional[tzinfo] = None) -> Pace:
    """Pace from the reading, the persisted updates and the bar's anchors."""
    week_anchors = [Point(at, used) for at, used, _ in samples]
    week = series(reading.week, WEEK, week_anchors, state.week, reading.now)
    five = None
    if reading.five is not None:
        five_anchors = [Point(at, f) for at, _, f in samples if f is not None]
        five = series(reading.five, FIVE_HOURS, five_anchors, state.five, reading.now)
    return compute_pace(reading, week, five, tz)


def severity(value: float, allowance: float) -> str:
    """'ok', 'over' (> allowance) or 'way_over' (>= 1.5x allowance)."""
    if allowance <= 0:
        return "way_over" if value > 0 else "ok"
    if value >= allowance * WAY_OVER_FACTOR:
        return "way_over"
    if value > allowance * OVER_FACTOR:
        return "over"
    return "ok"


def session_severity(used: float, limit: float) -> str:
    """Session usage can't exceed its limit, so colour by how close it is."""
    if limit <= 0:
        return "ok"
    share = used / limit
    return "way_over" if share >= SESSION_CRITICAL else "over" if share >= SESSION_WARN else "ok"


# ------------------------------------------------------------- rendering ----

PALETTES = {
    "dark": {"label": "245", "ok": "252", "over": "214", "way_over": "203"},
    "light": {"label": "243", "ok": "238", "over": "166", "way_over": "160"},
}


def render(pace: Pace, theme: str = "dark") -> str:
    p = PALETTES.get(theme, PALETTES["dark"])

    def seg(label: str, text: str, level: str) -> str:
        return f"\x1b[38;5;{p[level]}m{text}\x1b[38;5;{p['label']}m {label}\x1b[0m"

    def pair(label: str, used: float, quota: float, suffix: str = "", level: str = "") -> str:
        return seg(label, f"{round(used)}/{round(quota)}{suffix}", level or severity(used, quota))

    parts = [
        pair("today", pace.day_used, pace.day_quota),
        pair("wtd", pace.used, pace.on_track, "%"),
    ]
    if pace.session_used is not None and pace.session_quota is not None:
        # Worse of: ahead of the on-track pace, or nearly out of session.
        levels = ("ok", "over", "way_over")
        level = max(
            severity(pace.session_used, max(pace.session_quota, SESSION_PACE_FLOOR)),
            session_severity(pace.session_used, 100.0),
            key=levels.index,
        )
        parts.append(pair("ses", pace.session_used, pace.session_quota, "%", level=level))
    sep = f"\x1b[38;5;{p['label']}m · \x1b[0m"
    return sep.join(parts)


# ---------------------------------------------------------------- input -----

def _num(raw: object) -> bool:
    return not isinstance(raw, bool) and isinstance(raw, (int, float)) and math.isfinite(raw)


def _epoch(raw: object) -> Optional[int]:
    if _num(raw) and raw > 0:
        return int(raw)
    if isinstance(raw, str) and len(raw) <= 64:
        try:
            parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        except ValueError:
            return None
        if parsed.tzinfo is not None:
            return int(parsed.timestamp())
    return None


def _pct(value: float) -> float:
    return float(max(0.0, min(100.0, value)))


def _window(raw: object, now: float) -> Optional[Window]:
    if not isinstance(raw, Mapping):
        return None
    used = raw.get("used_percentage")
    resets_at = _epoch(raw.get("resets_at"))
    if not _num(used):
        return None
    if resets_at is None or resets_at <= now:
        return None  # expired window: the reading no longer describes it
    return Window(used=_pct(used), resets_at=resets_at)


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
    sid = payload.get("session_id")
    return Reading(
        week=week,
        now=now,
        five=_window(limits.get("five_hour"), now),
        session_id=sid if isinstance(sid, str) and 0 < len(sid) <= MAX_SESSION_ID else None,
    )


def clean_samples(samples: object) -> list:
    """(epoch, weekly %, 5-hour % or None) for each well-formed history sample."""
    if not isinstance(samples, Sequence) or isinstance(samples, (str, bytes)):
        return []
    out = []
    for sample in samples:
        if not isinstance(sample, Sequence) or isinstance(sample, (str, bytes)) or len(sample) < 2:
            continue
        at, used = sample[0], sample[1]
        if not (_num(at) and _num(used)):
            continue
        five = sample[2] if len(sample) > 2 and _num(sample[2]) else None
        out.append((float(at), _pct(used), None if five is None else _pct(five)))
    return out


# ---------------------------------------------------------- persistence -----

def state_path() -> Path:
    root = os.environ.get("XDG_STATE_HOME", "").strip() or os.path.join(
        os.path.expanduser("~"), ".local", "state"
    )
    return Path(root) / "claude-statusline" / "quota-pace.json"


def _finite(raw: object) -> float:
    if not _num(raw):
        raise ValueError(raw)
    return float(raw)


def _load_window(raw: object) -> Optional[Window]:
    if raw is None:
        return None
    used, resets_at = raw
    return Window(_pct(_finite(used)), int(_finite(resets_at)))


def _dump_window(window: Optional[Window]) -> Optional[list]:
    return None if window is None else [window.used, window.resets_at]


def _load_updates(raw: object) -> tuple:
    out = []
    for item in raw if isinstance(raw, list) else []:
        try:
            at, used, resets_at, timed = item
            if not isinstance(timed, bool):
                continue
            out.append(Update(_finite(at), _pct(_finite(used)), int(_finite(resets_at)), timed))
        except (ValueError, TypeError):
            continue
    return tuple(out)


def _load_sessions(raw: object) -> tuple:
    out = []
    for sid, seen in (raw.items() if isinstance(raw, Mapping) else ()):
        try:
            week = _load_window(seen["week"])
            if week is None or not isinstance(sid, str):
                continue
            out.append((sid, Seen(_finite(seen["at"]), week, _load_window(seen.get("five")))))
        except (ValueError, TypeError, KeyError):
            continue
    return tuple(out)


def load_state(path: Path) -> State:
    """Persisted state; anything unreadable or from another version is empty."""
    try:
        raw = json.loads(path.read_text())
    except (OSError, ValueError):
        return State()
    if not isinstance(raw, Mapping) or raw.get("v") != STATE_VERSION:
        return State()
    return State(
        sessions=_load_sessions(raw.get("sessions")),
        week=_load_updates(raw.get("week")),
        five=_load_updates(raw.get("five")),
    )


def save_state(path: Path, state: State) -> None:
    payload = {
        "v": STATE_VERSION,
        "sessions": {
            sid: {"at": seen.at, "week": _dump_window(seen.week), "five": _dump_window(seen.five)}
            for sid, seen in state.sessions
        },
        "week": [[u.at, u.used, u.resets_at, u.timed] for u in state.week],
        "five": [[u.at, u.used, u.resets_at, u.timed] for u in state.five],
    }
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".quota-pace.")
        with os.fdopen(fd, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, path)
    except OSError:
        pass


@contextlib.contextmanager
def locked(path: Path) -> Iterator[None]:
    """Serialise read-modify-write of the state across concurrent renders.

    Every open session renders on its own timer; without the lock two renders
    can each record an update and one would be lost. Best effort: without
    fcntl or a writable directory it runs unlocked.
    """
    handle = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        handle = open(path.with_suffix(".lock"), "a")
        if fcntl is not None:
            fcntl.flock(handle, fcntl.LOCK_EX)
    except OSError:
        pass
    try:
        yield
    finally:
        if handle is not None:
            handle.close()  # releases the lock


def history_path() -> Path:
    # Written by ai-usage-stream (quickshell-statusbar, outside this repo):
    # usage-endpoint readings dated when fetched. Absent on machines without
    # it; then this script relies on its own session updates alone.
    root = os.environ.get("XDG_CACHE_HOME", "").strip() or os.path.join(
        os.path.expanduser("~"), ".cache"
    )
    return Path(root) / "statusbar-ai-usage" / "history.json"


def load_history(path: Path) -> list:
    """The bar's Claude samples; only v2 histories hold endpoint readings alone."""
    try:
        if path.stat().st_size > 1_048_576:
            return []
        raw = json.loads(path.read_text())
        if raw.get("version") != HISTORY_VERSION:
            return []
        return clean_samples(raw["providers"]["claude"])
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return []


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
    with locked(path):
        prev = load_state(path)
        state = observe(prune(prev, reading.now), reading)
        if state != prev:
            save_state(path, state)
    pace = pace_for(reading, state, load_history(history_path()))
    sys.stdout.write(render(pace, theme))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
