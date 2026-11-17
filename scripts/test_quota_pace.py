"""Quota pace segment for the Claude Code status line."""

from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import unittest
from zoneinfo import ZoneInfo

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "dot_claude/scripts/executable_quota_pace.py"

spec = importlib.util.spec_from_file_location("quota_pace", SCRIPT)
qp = importlib.util.module_from_spec(spec)
sys.modules["quota_pace"] = qp
spec.loader.exec_module(qp)

HOUR = 3_600
DAY = 86_400
UTC = timezone.utc
# Weekly window resets at a UTC midnight, so window days == calendar days.
RESET = int(datetime(2033, 5, 21, tzinfo=UTC).timestamp())
START = RESET - 7 * DAY
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def at(day, hour=12.0):
    """Epoch inside the given 0-based day of the window."""
    return START + day * DAY + hour * HOUR


def bar(t, week, five=None):
    """The desktop bar recorded an endpoint reading at t."""
    return ("bar", t, week, five)


def ses(t, week, sid="a", five=None, five_reset=None, reset=RESET):
    """Session `sid` rendered the status line at t with this payload."""
    return ("ses", t, week, sid, five, five_reset, reset)


def simulate(events, tz=UTC):
    """Replay bar readings and renders; return (Pace at the last render, state)."""
    state, samples, pace = qp.State(), [], None
    for kind, t, week, *rest in events:
        if kind == "bar":
            samples.append((t, week, rest[0]))
            continue
        sid, five, five_reset, reset = rest
        reading = qp.Reading(
            qp.Window(week, reset), t,
            None if five is None else qp.Window(five, five_reset), sid,
        )
        state = qp.observe(qp.prune(state, t), reading)
        pace = qp.pace_for(reading, state, samples, tz)
    return pace, state


def run(events, tz=UTC):
    return simulate(events, tz)[0]


class WeeklyPace(unittest.TestCase):
    def test_on_track_is_end_of_today_share(self):
        self.assertAlmostEqual(run([ses(at(2), 34)]).on_track, 300 / 7)
        self.assertAlmostEqual(run([ses(at(0), 1)]).on_track, 100 / 7)
        self.assertAlmostEqual(run([ses(at(6), 90)]).on_track, 100)

    def test_last_second_of_window_is_day_seven(self):
        self.assertAlmostEqual(run([ses(RESET - 1, 50)]).on_track, 100)

    def test_on_track_with_reset_mid_day_counts_to_reset(self):
        reset = RESET + 19 * HOUR  # resets at 19:00
        self.assertAlmostEqual(run([ses(reset - 3 * HOUR, 90, reset=reset)]).on_track, 100)
        # Calendar day after the window started at 19:00: 5h + one full day.
        start = reset - 7 * DAY
        self.assertAlmostEqual(
            run([ses(start + 10 * HOUR, 5, reset=reset)]).on_track, (5 + 24) / (7 * 24) * 100
        )

    def test_severity_thresholds(self):
        self.assertEqual(qp.severity(40, 42), "ok")
        self.assertEqual(qp.severity(42, 42), "ok")
        self.assertEqual(qp.severity(43, 42), "over")
        self.assertEqual(qp.severity(63, 42), "way_over")
        self.assertEqual(qp.severity(5, 0), "way_over")
        self.assertEqual(qp.severity(0, 0), "ok")


class Today(unittest.TestCase):
    """Without the desktop bar: one session's own readings."""

    def test_even_pace_gives_100_per_day(self):
        pace = run([ses(at(0, 23), 100 / 7), ses(at(1, 23), 200 / 7)])
        self.assertAlmostEqual(pace.day_quota, 100)
        self.assertAlmostEqual(pace.day_used, 100)

    def test_today_starts_at_local_midnight_not_24h_ago(self):
        # 20% by 23:00 yesterday; 25% at 01:00 and 30% at 20:00 today.
        # Today's usage is 10 points, not the 5 that fell in the last 24 hours.
        pace = run([ses(at(1, 23), 20), ses(at(2, 1), 25), ses(at(2, 20), 30)])
        self.assertAlmostEqual(pace.day_used, 10 * 7)

    def test_midnight_follows_the_local_zone(self):
        tz = ZoneInfo("Australia/Sydney")
        local_midnight = datetime(2033, 5, 17, tzinfo=tz).timestamp()
        pace = run(
            [ses(local_midnight - 60, 40), ses(local_midnight + 60, 41), ses(local_midnight + 5 * HOUR, 45)],
            tz=tz,
        )
        self.assertAlmostEqual(pace.day_used, 5 * 7)

    def test_dst_day_spans_its_real_length(self):
        tz = ZoneInfo("Australia/Sydney")  # DST starts 2033-10-02: 23-hour day
        noon = datetime(2033, 10, 2, 12, tzinfo=tz).timestamp()
        start, end = qp.local_day(noon, tz)
        self.assertEqual(end - start, 23 * HOUR)

    def test_frugal_days_raise_todays_allowance(self):
        # 10% used over the first two days; 90% left across 5 days = 18%/day.
        pace = run([ses(at(1, 23), 10), ses(at(2, 1), 10), ses(at(2, 20), 15)])
        self.assertAlmostEqual(pace.day_quota, 90 / 5 * 7)
        self.assertAlmostEqual(pace.day_used, 5 * 7)

    def test_heavy_days_shrink_allowance(self):
        pace = run([ses(at(2, 23), 70), ses(at(3, 1), 71)])
        self.assertLess(pace.day_quota, 100)

    def test_reset_mid_day_gives_proportional_allowance(self):
        # Window resets at 18:00. On the final day 40% remain at midnight and
        # the whole remaining span is today, so the full 40% is allowed.
        reset = RESET + 18 * HOUR
        pace = run([ses(reset - DAY, 60, reset=reset), ses(reset - 12 * HOUR, 61, reset=reset)])
        self.assertAlmostEqual(pace.day_quota, 40 * 7)

    def test_window_that_began_today_counts_from_zero(self):
        reset = RESET + 18 * HOUR
        start = reset - 7 * DAY
        pace = run([ses(start - 10 * HOUR, 80, reset=start), ses(start + HOUR, 3, reset=reset)])
        self.assertAlmostEqual(pace.day_used, 21)
        # 6h of a 168h window remain today.
        self.assertAlmostEqual(pace.day_quota, 100 * 6 / 168 * 7)

    def test_first_ever_reading_mid_week_counts_from_now(self):
        pace = run([ses(at(3), 50)])
        self.assertEqual(pace.day_used, 0)
        self.assertAlmostEqual(pace.day_quota, 50 / 4 * 7)

    def test_idle_sessions_lower_figure_does_not_shrink_usage(self):
        pace = run([ses(at(2, 1), 40), ses(at(2, 2), 45), ses(at(2, 3), 41, sid="idle")])
        self.assertAlmostEqual(pace.day_used, 5 * 7)
        self.assertEqual(pace.used, 45)

    def test_exhausted_limit_has_zero_allowance(self):
        pace = run([ses(at(2, 23), 100), ses(at(3, 1), 100)])
        self.assertEqual(pace.day_quota, 0)


class EarlyReset(unittest.TestCase):
    """The limit is reset early without its reset time moving."""

    BEFORE = [
        bar(at(1, 23), 52),
        ses(at(2, 18), 94), ses(at(2, 18.5), 95),
        bar(at(2, 18.6), 95),
        bar(at(2, 19), 0),    # the reset
        bar(at(2, 19.5), 1),
    ]

    def test_counts_from_the_reset_and_ignores_idle_sessions_stale_figure(self):
        # An idle session last answered before the reset and still says 53.
        pace = run([*self.BEFORE, ses(at(2, 19.6), 53, sid="idle")])
        self.assertEqual(pace.used, 1)
        reset_at, day_end = at(2, 19), at(3, 0)
        self.assertAlmostEqual(pace.on_track, (day_end - reset_at) / (RESET - reset_at) * 100)
        self.assertAlmostEqual(pace.day_used, 7)
        self.assertAlmostEqual(pace.day_quota, 100 * (day_end - reset_at) / (RESET - reset_at) * 7)

    def test_the_session_that_ran_before_the_reset_is_ignored_until_it_answers(self):
        # Session "a" still reports its pre-reset 95: unchanged, so no update.
        self.assertEqual(run([*self.BEFORE, ses(at(2, 19.6), 95)]).used, 1)
        # Once it gets a response its figure changes, and that counts.
        self.assertEqual(run([*self.BEFORE, ses(at(2, 19.6), 95), ses(at(2, 19.7), 3)]).used, 3)

    def test_tomorrow_counts_from_midnight_against_the_fresh_quota(self):
        pace = run([*self.BEFORE, bar(at(2, 23), 10), bar(at(3, 10), 20), ses(at(3, 10.5), 20)])
        self.assertAlmostEqual(pace.day_used, 10 * 7)
        self.assertAlmostEqual(pace.day_quota, 90 / 4 * 7)


class Interpolation(unittest.TestCase):
    def test_session_updates_raise_the_estimate_between_bar_readings(self):
        events = [bar(at(2, 10), 40), ses(at(2, 10.01), 40), ses(at(2, 10.02), 42)]
        self.assertEqual(run(events).used, 42)

    def test_next_bar_reading_supersedes_updates(self):
        events = [
            bar(at(2, 10), 40), ses(at(2, 10.01), 40), ses(at(2, 10.02), 42),
            bar(at(2, 10.1), 41.5), ses(at(2, 10.11), 42),
        ]
        self.assertEqual(run(events).used, 41.5)

    def test_untimed_readings_are_ignored_once_the_bar_has_readings(self):
        # History that begins after an unseen reset: no drop to detect, but
        # an idle session's 53 must still not override the bar.
        self.assertEqual(run([bar(at(2, 10), 1), ses(at(2, 10.1), 53, sid="idle")]).used, 1)

    def test_without_the_bar_the_payload_is_all_there_is(self):
        self.assertEqual(run([ses(at(2), 37)]).used, 37)


class Observe(unittest.TestCase):
    def reading(self, t, week, five=None, sid="a"):
        return qp.Reading(qp.Window(week, RESET), t, None if five is None else qp.Window(five, int(t + HOUR)), sid)

    def test_idle_session_records_only_its_first_sighting(self):
        state = qp.State()
        for i in range(5):
            state = qp.observe(state, qp.Reading(qp.Window(53, RESET), at(2) + 30 * i, None, "idle"))
        self.assertEqual([(u.used, u.timed) for u in state.week], [(53, False)])

    def test_unchanged_rerender_leaves_state_untouched(self):
        def reading(t):
            return qp.Reading(qp.Window(10, RESET), t, qp.Window(5, int(at(2, 4))), "a")

        first = qp.observe(qp.State(), reading(at(2)))
        self.assertEqual(qp.observe(first, reading(at(2, 1))), first)

    def test_changes_are_timed_updates(self):
        state = qp.State()
        for t, week in [(at(2), 10), (at(2, 13), 10), (at(2, 14), 11)]:
            state = qp.observe(state, self.reading(t, week))
        self.assertEqual([(u.at, u.used, u.timed) for u in state.week], [(at(2), 10, False), (at(2, 14), 11, True)])

    def test_five_hour_window_expiring_is_not_a_change(self):
        five = qp.Window(30, int(at(2, 1)))
        state = qp.observe(qp.State(), qp.Reading(qp.Window(53, RESET), at(2), five, "idle"))
        state = qp.observe(state, qp.Reading(qp.Window(53, RESET), at(2, 2), None, "idle"))
        self.assertEqual(len(state.five), 1)
        self.assertEqual(len(state.week), 1)

    def test_without_session_id_nothing_is_recorded(self):
        state = qp.observe(qp.State(), qp.Reading(qp.Window(53, RESET), at(2), None, None))
        self.assertEqual(state, qp.State())

    def test_prune_drops_expired_windows_and_forgotten_sessions(self):
        state = qp.State()
        for sid in ("old", "new"):
            state = qp.observe(state, qp.Reading(qp.Window(5, RESET), at(1) if sid == "old" else at(2), None, sid))
        expired = qp.Update(at(0), 9, int(at(1)))
        state = qp.replace(state, week=(expired, *state.week))
        pruned = qp.prune(state, at(2, 13))
        self.assertEqual([sid for sid, _ in pruned.sessions], ["new"])
        self.assertNotIn(expired, pruned.week)

    def test_prune_bounds_sessions_and_updates(self):
        state = qp.State()
        for i in range(qp.MAX_SESSIONS + 10):
            state = qp.observe(state, qp.Reading(qp.Window(5, RESET), at(3) + i, None, f"s{i}"))
        for i in range(qp.MAX_UPDATES + 10):
            state = qp.observe(state, qp.Reading(qp.Window(i % 100, RESET), at(3) + 100 + i, None, "busy"))
        pruned = qp.prune(state, at(3, 6))
        self.assertEqual(len(pruned.sessions), qp.MAX_SESSIONS)
        self.assertIn("busy", dict(pruned.sessions))
        self.assertEqual(len(pruned.week), qp.MAX_UPDATES)


class Session(unittest.TestCase):
    T0 = at(3, 9)
    FIVE_RESET = int(T0 + 5 * HOUR)

    def s(self, hours_in, week, five, sid="a"):
        return ses(self.T0 + hours_in * HOUR, week, sid, five, self.FIVE_RESET)

    def test_on_track_is_share_of_session_elapsed(self):
        for hours_in, expected in [(0, 0), (4, 80), (5 - 1 / HOUR, 100)]:
            with self.subTest(hours_in=hours_in):
                self.assertAlmostEqual(run([self.s(hours_in, 50, 0)]).session_quota, expected, delta=0.1)

    def test_usage_is_the_five_hour_figure(self):
        pace = run([self.s(0, 50, 0), self.s(1, 53, 40)])
        self.assertEqual(pace.session_used, 40)

    def test_bar_reading_beats_an_idle_sessions_figure(self):
        pace = run([bar(self.T0 + HOUR, 53, 40), self.s(1.1, 50, 20, sid="idle")])
        self.assertEqual(pace.session_used, 40)

    def test_early_five_hour_reset_counts_from_zero(self):
        events = [bar(self.T0 + HOUR, 60, 90), bar(self.T0 + 2 * HOUR, 60, 2), self.s(2.1, 60, 90, sid="idle")]
        self.assertEqual(run(events).session_used, 2)

    def test_bar_reading_from_before_the_window_is_ignored(self):
        events = [bar(self.T0 - HOUR, 50, 95), self.s(0.1, 50, 3)]
        self.assertEqual(run(events).session_used, 3)

    def test_no_open_window_omits_session(self):
        pace = run([self.s(1, 53, None)])
        self.assertIsNone(pace.session_used)
        self.assertNotIn("ses", ANSI.sub("", qp.render(pace)))

    def test_session_severity_by_share_used(self):
        self.assertEqual(qp.session_severity(50, 100), "ok")
        self.assertEqual(qp.session_severity(75, 100), "over")
        self.assertEqual(qp.session_severity(90, 100), "way_over")
        self.assertEqual(qp.session_severity(5, 0), "ok")


class ParseReading(unittest.TestCase):
    NOW = at(2)

    def payload(self, week, five=None, **extra):
        limits = {"seven_day": week}
        if five is not None:
            limits["five_hour"] = five
        return {"rate_limits": limits, **extra}

    def test_epoch_and_iso_reset(self):
        r = qp.parse_reading(self.payload({"used_percentage": 34, "resets_at": RESET}), self.NOW)
        self.assertEqual((r.week.used, r.week.resets_at, r.five), (34.0, RESET, None))
        iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(RESET))
        r = qp.parse_reading(self.payload({"used_percentage": 34, "resets_at": iso}), self.NOW)
        self.assertEqual(r.week.resets_at, RESET)

    def test_session_id_is_kept_only_when_sane(self):
        week = {"used_percentage": 34, "resets_at": RESET}
        self.assertEqual(qp.parse_reading(self.payload(week, session_id="abc"), self.NOW).session_id, "abc")
        for sid in [None, 7, "", "x" * 500, ["a"]]:
            with self.subTest(sid=sid):
                self.assertIsNone(qp.parse_reading(self.payload(week, session_id=sid), self.NOW).session_id)

    def test_five_hour_window_parsed_and_validated(self):
        week = {"used_percentage": 34, "resets_at": RESET}
        ok = qp.parse_reading(self.payload(week, {"used_percentage": 12, "resets_at": self.NOW + 60}), self.NOW)
        self.assertEqual(ok.five, qp.Window(12.0, int(self.NOW + 60)))
        for five in [{"used_percentage": 0, "resets_at": None}, {"used_percentage": 5, "resets_at": self.NOW - 1}, "x"]:
            with self.subTest(five=five):
                r = qp.parse_reading(self.payload(week, five), self.NOW)
                self.assertIsNotNone(r)
                self.assertIsNone(r.five)

    def test_rejects_missing_or_malformed(self):
        bad = [
            None, [], "x", {}, {"rate_limits": None}, {"rate_limits": {"seven_day": "x"}},
            self.payload({"resets_at": RESET}),
            self.payload({"used_percentage": None, "resets_at": RESET}),
            self.payload({"used_percentage": True, "resets_at": RESET}),
            self.payload({"used_percentage": float("nan"), "resets_at": RESET}),
            self.payload({"used_percentage": 10, "resets_at": "garbage"}),
            self.payload({"used_percentage": 10, "resets_at": "2026-01-01T00:00:00"}),  # naive
            self.payload({"used_percentage": 10, "resets_at": "9" * 500}),
            self.payload({"used_percentage": 10, "resets_at": self.NOW - 1}),  # expired
        ]
        for p in bad:
            with self.subTest(p=p):
                self.assertIsNone(qp.parse_reading(p, self.NOW))

    def test_clamps_out_of_range_percent(self):
        hi = qp.parse_reading(self.payload({"used_percentage": 1e9, "resets_at": RESET}), self.NOW)
        lo = qp.parse_reading(self.payload({"used_percentage": -5, "resets_at": RESET}), self.NOW)
        self.assertEqual((hi.week.used, lo.week.used), (100.0, 0.0))


class Persistence(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_state_round_trips(self):
        _, state = simulate([
            ses(at(2), 10, five=3, five_reset=int(at(2, 4))), ses(at(2, 1), 11, five=5, five_reset=int(at(2, 4))),
            ses(at(2, 2), 53, sid="idle"),
        ])
        path = self.dir / "state.json"
        qp.save_state(path, state)
        self.assertEqual(qp.load_state(path), state)

    def test_corrupt_old_or_partial_state_degrades(self):
        path = self.dir / "state.json"
        for content in ["{corrupt", json.dumps({"v": 2, "day": {}}), json.dumps([1, 2])]:
            with self.subTest(content=content):
                path.write_text(content)
                self.assertEqual(qp.load_state(path), qp.State())
        path.write_text(json.dumps({
            "v": qp.STATE_VERSION,
            "sessions": {"a": {"at": 1, "week": [5, RESET], "five": None}, "b": {"at": "x"}, "c": None},
            "week": [[1, 5, RESET, False], [1, 5, RESET, "yes"], [1, "nan", RESET, True], "junk", [2, 6, RESET, True]],
            "five": None,
        }))
        state = qp.load_state(path)
        self.assertEqual([sid for sid, _ in state.sessions], ["a"])
        self.assertEqual([(u.used, u.timed) for u in state.week], [(5, False), (6, True)])
        self.assertEqual(state.five, ())

    def test_history_is_read_only_at_version_2(self):
        path = self.dir / "history.json"
        rows = [[1, 20.0, None], [2, 25.5, 3.0], "junk", [None, 1], [3, True], [4, 400, None]]
        path.write_text(json.dumps({"version": 1, "providers": {"claude": rows}}))
        self.assertEqual(qp.load_history(path), [])
        path.write_text(json.dumps({"version": 2, "providers": {"claude": rows}}))
        self.assertEqual(qp.load_history(path), [(1, 20.0, None), (2, 25.5, 3.0), (4, 100.0, None)])
        for content in ["[[[", json.dumps({"version": 2}), json.dumps([]), json.dumps({"version": 2, "providers": {"claude": "x"}})]:
            with self.subTest(content=content):
                path.write_text(content)
                self.assertEqual(qp.load_history(path), [])


class Render(unittest.TestCase):
    def test_text_matches_spec(self):
        pace = qp.Pace(used=34, on_track=300 / 7, day_used=80, day_quota=120, session_used=40.4, session_quota=80)
        self.assertEqual(ANSI.sub("", qp.render(pace)), "80/120 today · 34/43% wtd · 40/80% ses")

    def test_session_omitted_without_data(self):
        pace = qp.Pace(used=34, on_track=300 / 7, day_used=80, day_quota=120)
        self.assertEqual(ANSI.sub("", qp.render(pace)), "80/120 today · 34/43% wtd")

    def test_colors_by_severity_per_theme(self):
        for theme, pal in qp.PALETTES.items():
            way = qp.render(qp.Pace(70, 300 / 7, 50, 100, 90, 60), theme)
            self.assertIn(f"38;5;{pal['way_over']}m70/43%", way)
            self.assertIn(f"38;5;{pal['ok']}m50/100", way)
            self.assertIn(f"38;5;{pal['way_over']}m90/60%", way)
            over = qp.render(qp.Pace(50, 300 / 7, 110, 100, 75, 60), theme)
            self.assertIn(f"38;5;{pal['over']}m50/43%", over)
            self.assertIn(f"38;5;{pal['over']}m110/100", over)
            self.assertIn(f"38;5;{pal['over']}m75/60%", over)
            ok = qp.render(qp.Pace(50, 300 / 7, 110, 100, 30, 60), theme)
            self.assertIn(f"38;5;{pal['ok']}m30/60%", ok)


class SessionColor(unittest.TestCase):
    def test_colour_follows_pace_and_absolute_use(self):
        pal = qp.PALETTES["dark"]
        for used, track, level in [(30, 8, "way_over"), (12, 8, "over"), (8, 10, "ok"), (92, 99, "way_over"), (4, 0, "ok"), (4, 2, "ok"), (16, 2, "way_over")]:
            with self.subTest(used=used, track=track):
                out = qp.render(qp.Pace(10, 50, 1, 100, used, track))
                self.assertIn(f"38;5;{pal[level]}m{used}/{track}%", out)


class Cli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = {**os.environ, "XDG_STATE_HOME": self.tmp.name, "XDG_CACHE_HOME": self.tmp.name, "TZ": "UTC"}
        now = time.time()
        self.now = now
        self.midnight = now - now % DAY
        # Weekly reset at UTC midnight 5 days out: today is day 3 of 7.
        self.reset = int(self.midnight + 5 * DAY)
        self.five_reset = int(now + 5 * HOUR)

    def tearDown(self):
        self.tmp.cleanup()

    def payload(self, week_used, five_used=None, sid="a"):
        limits = {"seven_day": {"used_percentage": week_used, "resets_at": self.reset}}
        if five_used is not None:
            limits["five_hour"] = {"used_percentage": five_used, "resets_at": self.five_reset}
        return json.dumps({"session_id": sid, "rate_limits": limits})

    def history(self, rows, version=2):
        hist = Path(self.tmp.name) / "statusbar-ai-usage" / "history.json"
        hist.parent.mkdir(parents=True, exist_ok=True)
        hist.write_text(json.dumps({"version": version, "providers": {"claude": rows}}))

    def cli(self, stdin):
        out = subprocess.run(
            [sys.executable, str(SCRIPT), "--theme", "light"],
            input=stdin, capture_output=True, text=True, env=self.env, timeout=10,
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        return ANSI.sub("", out.stdout)

    def test_prints_segment_and_persists_across_renders(self):
        # 70% left over 5 days -> 14%/day -> 98 units.
        self.assertEqual(self.cli(self.payload(30)), "0/98 today · 30/43% wtd")
        self.assertEqual(self.cli(self.payload(32)), "14/98 today · 32/43% wtd")

    def test_session_segment_tracks_the_session(self):
        self.assertEqual(self.cli(self.payload(30, 0)), "0/98 today · 30/43% wtd · 0/0% ses")
        self.assertEqual(self.cli(self.payload(31, 10)), "7/98 today · 31/43% wtd · 10/0% ses")

    def test_silent_without_limits_or_on_garbage(self):
        for stdin in ["", "not json", "{}", json.dumps({"rate_limits": {}})]:
            with self.subTest(stdin=stdin):
                self.assertEqual(self.cli(stdin), "")

    def test_reads_start_of_day_from_desktop_bar_history(self):
        self.history([[self.midnight - 5 * HOUR, 20.0, None], [self.now - 60, 30.0, None]])
        # 80% left over 5 days -> 16%/day -> 112 units; 10 points today -> 70.
        self.assertEqual(self.cli(self.payload(30)), "70/112 today · 30/43% wtd")

    def test_early_reset_in_bar_history_overrides_stale_sessions(self):
        reset_at = self.now - 300
        self.history([[self.midnight - 5 * HOUR, 20.0, None], [self.now - 600, 95.0, None], [reset_at, 0.0, None]])
        out = self.cli(self.payload(53, sid="idle"))
        self.assertRegex(out, r"^\d+/\d+ today · \d+/\d+% wtd$")
        share = (self.midnight + DAY - reset_at) / (self.reset - reset_at)
        used, quota, wtd_used, on_track = map(int, re.findall(r"\d+", out))
        self.assertEqual((used, wtd_used), (0, 0))
        self.assertAlmostEqual(quota, 100 * share * 7, delta=1)
        self.assertAlmostEqual(on_track, 100 * share, delta=1)

    def test_old_or_corrupt_history_falls_back(self):
        self.history([[self.midnight - 5 * HOUR, 20.0, None]], version=1)
        self.assertEqual(self.cli(self.payload(30)), "0/98 today · 30/43% wtd")
        (Path(self.tmp.name) / "statusbar-ai-usage" / "history.json").write_text("[[[")
        self.assertEqual(self.cli(self.payload(30)), "0/98 today · 30/43% wtd")

    def test_corrupt_or_old_state_file_is_ignored(self):
        path = Path(self.tmp.name) / "claude-statusline" / "quota-pace.json"
        path.parent.mkdir(parents=True)
        for content in [
            "{corrupt",
            json.dumps({"v": 2, "day": {"resets_at": 1, "day_start": 1, "baseline": 13.0, "last": 99.0}, "session": None}),
            json.dumps({"v": 3, "sessions": "x", "week": {"a": 1}, "five": [[1]]}),
        ]:
            with self.subTest(content=content):
                path.write_text(content)
                self.assertEqual(self.cli(self.payload(30, 5)).rsplit(" · ", 1)[0], "0/98 today · 30/43% wtd")


if __name__ == "__main__":
    unittest.main()
