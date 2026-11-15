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


def run(readings, reset=RESET, tz=UTC):
    """Feed (now, weekly used) readings through the day logic; return last Pace."""
    state = None
    pace = None
    for now, used in readings:
        week = qp.Window(used, reset)
        start, end = qp.today_span(week, now, tz)
        state = qp.advance_day(state, week, start)
        pace = qp.compute_pace(week, state, end)
    return pace


class WeeklyPace(unittest.TestCase):
    def test_on_track_is_end_of_today_share(self):
        self.assertAlmostEqual(run([(at(2), 34)]).on_track, 300 / 7)
        self.assertAlmostEqual(run([(at(0), 1)]).on_track, 100 / 7)
        self.assertAlmostEqual(run([(at(6), 90)]).on_track, 100)

    def test_last_second_of_window_is_day_seven(self):
        self.assertAlmostEqual(run([(RESET - 1, 50)]).on_track, 100)

    def test_on_track_with_reset_mid_day_counts_to_reset(self):
        reset = RESET + 19 * HOUR  # resets at 19:00
        self.assertAlmostEqual(run([(reset - 3 * HOUR, 90)], reset).on_track, 100)
        # Calendar day after the window started at 19:00: 5h + one full day.
        start = reset - 7 * DAY
        self.assertAlmostEqual(
            run([(start + 10 * HOUR, 5)], reset).on_track, (5 + 24) / (7 * 24) * 100
        )

    def test_severity_thresholds(self):
        self.assertEqual(qp.severity(40, 42), "ok")
        self.assertEqual(qp.severity(42, 42), "ok")
        self.assertEqual(qp.severity(43, 42), "over")
        self.assertEqual(qp.severity(63, 42), "way_over")
        self.assertEqual(qp.severity(5, 0), "way_over")
        self.assertEqual(qp.severity(0, 0), "ok")


class Today(unittest.TestCase):
    def test_even_pace_gives_100_per_day(self):
        pace = run([(at(0, 23), 100 / 7), (at(1, 23), 200 / 7)])
        self.assertAlmostEqual(pace.day_quota, 100)
        self.assertAlmostEqual(pace.day_used, 100)

    def test_today_starts_at_local_midnight_not_24h_ago(self):
        # 20% by 23:00 yesterday; 25% at 01:00 and 30% at 20:00 today.
        # Today's usage is 10 points, not the 5 that fell in the last 24 hours.
        pace = run([(at(1, 23), 20), (at(2, 1), 25), (at(2, 20), 30)])
        self.assertAlmostEqual(pace.day_used, 10 * 7)

    def test_midnight_follows_the_local_zone(self):
        tz = ZoneInfo("Australia/Sydney")
        local_midnight = datetime(2033, 5, 17, tzinfo=tz).timestamp()
        pace = run([(local_midnight - 60, 40), (local_midnight + 60, 41), (local_midnight + 5 * HOUR, 45)], tz=tz)
        self.assertAlmostEqual(pace.day_used, 5 * 7)

    def test_dst_day_spans_its_real_length(self):
        tz = ZoneInfo("Australia/Sydney")  # DST starts 2033-10-02: 23-hour day
        noon = datetime(2033, 10, 2, 12, tzinfo=tz).timestamp()
        start, end = qp.local_day(noon, tz)
        self.assertEqual(end - start, 23 * HOUR)

    def test_frugal_days_raise_todays_allowance(self):
        # 10% used over the first two days; 90% left across 5 days = 18%/day.
        pace = run([(at(1, 23), 10), (at(2, 1), 10), (at(2, 20), 15)])
        self.assertAlmostEqual(pace.day_quota, 90 / 5 * 7)
        self.assertAlmostEqual(pace.day_used, 5 * 7)

    def test_heavy_days_shrink_allowance(self):
        pace = run([(at(2, 23), 70), (at(3, 1), 70)])
        self.assertLess(pace.day_quota, 100)

    def test_reset_mid_day_gives_proportional_allowance(self):
        # Window resets at 18:00. On the final day 40% remain at midnight and
        # the whole remaining span is today, so the full 40% is allowed.
        reset = RESET + 18 * HOUR
        pace = run([(reset - DAY, 60), (reset - 12 * HOUR, 61)], reset)
        self.assertAlmostEqual(pace.day_quota, 40 * 7)

    def test_window_that_began_today_counts_from_zero(self):
        reset = RESET + 18 * HOUR
        start = reset - 7 * DAY
        prev = qp.advance_day(None, qp.Window(80, start), start - 10 * HOUR)
        week = qp.Window(3, reset)
        s, e = qp.today_span(week, start + HOUR, UTC)
        state = qp.advance_day(prev, week, s)
        pace = qp.compute_pace(week, state, e)
        self.assertAlmostEqual(pace.day_used, 21)
        # 6h of a 168h window remain today.
        self.assertAlmostEqual(pace.day_quota, 100 * 6 / 168 * 7)

    def test_first_ever_reading_mid_week_counts_from_now(self):
        pace = run([(at(3), 50)])
        self.assertEqual(pace.day_used, 0)
        self.assertAlmostEqual(pace.day_quota, 50 / 4 * 7)

    def test_stale_lower_reading_does_not_shrink_usage(self):
        # Another idle session reports an old, lower figure.
        pace = run([(at(2, 1), 40), (at(2, 2), 45), (at(2, 3), 41)])
        self.assertAlmostEqual(pace.day_used, 5 * 7)
        self.assertEqual(pace.used, 45)

    def test_exhausted_limit_has_zero_allowance(self):
        pace = run([(at(4, 23), 100), (at(5, 1), 100)])
        self.assertEqual(pace.day_quota, 0)
        self.assertEqual(pace.day_used, 0)


class HistoryBaseline(unittest.TestCase):
    WEEK = qp.Window(40, RESET)

    def test_uses_last_sample_before_midnight(self):
        samples = [[at(1, 5), 10, None], [at(2, 23), 30, 5], [at(3, 1), 33, None]]
        self.assertEqual(qp.baseline_from_history(samples, self.WEEK, at(3, 0)), 30.0)

    def test_ignores_previous_window_and_later_samples(self):
        samples = [[START - 3600, 90, None], [at(3, 1), 33, None]]
        self.assertIsNone(qp.baseline_from_history(samples, self.WEEK, at(3, 0)))

    def test_day_starting_at_window_start_is_zero(self):
        self.assertEqual(qp.baseline_from_history([], self.WEEK, START), 0.0)

    def test_skips_malformed_samples(self):
        good = [at(1, 20), 12]
        junk = [None, "x", [], [at(1, 21)], [True, 50], [at(1, 21), "50"], [float("nan"), 1], {"a": 1}]
        self.assertEqual(qp.baseline_from_history(junk + [good], self.WEEK, at(2, 0)), 12.0)

    def test_history_overrides_inferred_state(self):
        week = qp.Window(65, RESET)
        start, end = qp.today_span(week, at(6), UTC)
        seeded = qp.advance_day(None, week, start)  # no history: counts from now
        self.assertEqual(qp.compute_pace(week, seeded, end).day_used, 0)
        fixed = qp.advance_day(seeded, week, start, history_baseline=63.0)
        pace = qp.compute_pace(week, fixed, end)
        self.assertAlmostEqual(pace.day_used, 14)
        self.assertAlmostEqual(pace.day_quota, 259)


def hour_run(readings):
    """Feed (now, weekly used, five used, five reset) readings; return (state, last reading)."""
    state, reading = None, None
    for now, week_used, five_used, five_reset in readings:
        five = None if five_used is None else qp.Window(five_used, five_reset)
        reading = qp.Reading(qp.Window(week_used, RESET), now, five)
        state = qp.advance_hour(state, reading)
    return state, reading


class Hourly(unittest.TestCase):
    T0 = at(3, 9)
    FIVE_RESET = T0 + 5 * HOUR

    def test_fresh_window_quota_uses_prior_ratio(self):
        state, r = hour_run([(self.T0, 50, 0, self.FIVE_RESET)])
        used, quota = qp.hour_pace(state, r)
        self.assertEqual(used, 0)
        # 100% of a 5h window = 12.5 weekly points = 87.5 units over 5 hours.
        self.assertAlmostEqual(quota, 17.5)

    def test_quota_spreads_remaining_window_over_time_left(self):
        state, r = hour_run([(self.T0, 50, 0, self.FIVE_RESET), (self.T0 + 3 * HOUR, 50, 60, self.FIVE_RESET)])
        _, quota = qp.hour_pace(state, r)
        to_units = qp.week_pct_per_five_pct(state) * 7
        self.assertAlmostEqual(quota, 40 / 2 * to_units)

    def test_ratio_is_learned_from_co_movement(self):
        # Weekly moves 1 point per 4 five-hour points: ratio converges to 1/4.
        readings = [(self.T0 + i * 60, 50 + i, 4 * i, self.FIVE_RESET) for i in range(25)]
        state, _ = hour_run(readings)
        ratio = qp.week_pct_per_five_pct(state)
        self.assertAlmostEqual(ratio, (24 + 0.125 * qp.PRIOR_WEIGHT) / (96 + qp.PRIOR_WEIGHT))
        self.assertGreater(ratio, 0.2)

    def test_last_hour_usage_excludes_older_usage(self):
        # 30 five-hour points 90 minutes ago, then 10 in the last hour.
        readings = [
            (self.T0, 50, 0, self.FIVE_RESET),
            (self.T0 + 10 * 60, 54, 30, self.FIVE_RESET),
            (self.T0 + 40 * 60, 54, 30, self.FIVE_RESET),
            (self.T0 + 90 * 60, 55, 40, self.FIVE_RESET),
        ]
        state, r = hour_run(readings)
        used, _ = qp.hour_pace(state, r)
        self.assertAlmostEqual(used, 10 * qp.week_pct_per_five_pct(state) * 7)

    def test_usage_across_a_five_hour_reset_is_kept(self):
        next_reset = self.FIVE_RESET + 5 * HOUR
        readings = [
            (self.FIVE_RESET - 30 * 60, 50, 90, self.FIVE_RESET),
            (self.FIVE_RESET - 10 * 60, 50, 95, self.FIVE_RESET),
            (self.FIVE_RESET + 20 * 60, 51, 8, next_reset),
        ]
        state, r = hour_run(readings)
        used, _ = qp.hour_pace(state, r)
        self.assertAlmostEqual(used, 13 * qp.week_pct_per_five_pct(state) * 7)

    def test_stale_lower_reading_adds_nothing(self):
        readings = [
            (self.T0, 50, 10, self.FIVE_RESET),
            (self.T0 + 120, 50, 20, self.FIVE_RESET),
            (self.T0 + 240, 50, 2, self.FIVE_RESET),   # stale session
            (self.T0 + 360, 50, 20, self.FIVE_RESET),
        ]
        state, r = hour_run(readings)
        used, _ = qp.hour_pace(state, r)
        self.assertAlmostEqual(used, 10 * qp.week_pct_per_five_pct(state) * 7)

    def test_exhausted_window_has_zero_quota(self):
        state, r = hour_run([(self.T0, 50, 100, self.FIVE_RESET)])
        self.assertEqual(qp.hour_pace(state, r)[1], 0)

    def test_quota_stays_finite_right_before_reset(self):
        state, r = hour_run([(self.FIVE_RESET - 1, 50, 10, self.FIVE_RESET)])
        self.assertTrue(qp.math.isfinite(qp.hour_pace(state, r)[1]))

    def test_no_window_open_shows_fresh_window_rate(self):
        state, _ = hour_run([(self.T0, 50, 10, self.FIVE_RESET)])
        idle = qp.Reading(qp.Window(50, RESET), self.FIVE_RESET + HOUR, None)
        state = qp.advance_hour(state, idle)
        used, quota = qp.hour_pace(state, idle)
        self.assertEqual(used, 0)
        self.assertAlmostEqual(quota, 20 * qp.week_pct_per_five_pct(state) * 7)

    def test_no_five_hour_data_ever_omits_hourly(self):
        state, r = hour_run([(self.T0, 50, None, None)])
        self.assertIsNone(state)
        self.assertEqual(qp.hour_pace(state, r), (None, None))

    def test_sample_buffer_stays_bounded(self):
        readings = [(self.T0 + i * 30, 50, min(100, i / 50), self.FIVE_RESET) for i in range(2000)]
        state, _ = hour_run(readings)
        self.assertLessEqual(len(state.samples), HOUR // qp.SAMPLE_SPACING + 2)


class ParseReading(unittest.TestCase):
    NOW = at(2)

    def payload(self, week, five=None):
        limits = {"seven_day": week}
        if five is not None:
            limits["five_hour"] = five
        return {"rate_limits": limits}

    def test_epoch_and_iso_reset(self):
        r = qp.parse_reading(self.payload({"used_percentage": 34, "resets_at": RESET}), self.NOW)
        self.assertEqual((r.week.used, r.week.resets_at, r.five), (34.0, RESET, None))
        iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(RESET))
        r = qp.parse_reading(self.payload({"used_percentage": 34, "resets_at": iso}), self.NOW)
        self.assertEqual(r.week.resets_at, RESET)

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


class Render(unittest.TestCase):
    def test_text_matches_spec(self):
        pace = qp.Pace(used=34, on_track=300 / 7, day_used=80, day_quota=120, hour_used=12, hour_quota=17.5)
        self.assertEqual(ANSI.sub("", qp.render(pace)), "80/120 today · 34/43% wtd · 12/18 hr")

    def test_hour_omitted_without_data(self):
        pace = qp.Pace(used=34, on_track=300 / 7, day_used=80, day_quota=120)
        self.assertEqual(ANSI.sub("", qp.render(pace)), "80/120 today · 34/43% wtd")

    def test_colors_by_severity_per_theme(self):
        for theme, pal in qp.PALETTES.items():
            way = qp.render(qp.Pace(70, 300 / 7, 50, 100, 30, 18), theme)
            self.assertIn(f"38;5;{pal['way_over']}m70/43%", way)
            self.assertIn(f"38;5;{pal['ok']}m50/100", way)
            self.assertIn(f"38;5;{pal['way_over']}m30/18", way)
            over = qp.render(qp.Pace(50, 300 / 7, 110, 100, 20, 18), theme)
            self.assertIn(f"38;5;{pal['over']}m50/43%", over)
            self.assertIn(f"38;5;{pal['over']}m110/100", over)
            self.assertIn(f"38;5;{pal['over']}m20/18", over)


class Cli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = {**os.environ, "XDG_STATE_HOME": self.tmp.name, "XDG_CACHE_HOME": self.tmp.name, "TZ": "UTC"}
        now = time.time()
        self.midnight = now - now % DAY
        # Weekly reset at UTC midnight 5 days out: today is day 3 of 7.
        self.reset = int(self.midnight + 5 * DAY)
        self.five_reset = int(now + 5 * HOUR)

    def tearDown(self):
        self.tmp.cleanup()

    def payload(self, week_used, five_used=None):
        limits = {"seven_day": {"used_percentage": week_used, "resets_at": self.reset}}
        if five_used is not None:
            limits["five_hour"] = {"used_percentage": five_used, "resets_at": self.five_reset}
        return json.dumps({"rate_limits": limits})

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

    def test_hourly_segment_accumulates(self):
        first = self.cli(self.payload(30, 0))
        self.assertTrue(first.endswith(" · 0/17 hr") or first.endswith(" · 0/18 hr"), first)
        # 8 five-hour points with 1 weekly point: learned ratio rises a bit.
        second = self.cli(self.payload(31, 8))
        used = int(second.rsplit(" · ", 1)[1].split("/")[0])
        self.assertGreater(used, 0)
        self.assertTrue(second.startswith("7/98 today · "), second)

    def test_silent_without_limits_or_on_garbage(self):
        for stdin in ["", "not json", "{}", json.dumps({"rate_limits": {}})]:
            with self.subTest(stdin=stdin):
                self.assertEqual(self.cli(stdin), "")

    def test_reads_start_of_day_from_desktop_bar_history(self):
        hist = Path(self.tmp.name) / "statusbar-ai-usage" / "history.json"
        hist.parent.mkdir(parents=True)
        hist.write_text(json.dumps({"version": 1, "providers": {"claude": [
            [self.midnight - 5 * HOUR, 20.0, None], [self.midnight + 60, 25.0, None]]}}))
        # 80% left over 5 days -> 16%/day -> 112 units; 10 points today -> 70.
        self.assertEqual(self.cli(self.payload(30)), "70/112 today · 30/43% wtd")

    def test_corrupt_history_falls_back(self):
        hist = Path(self.tmp.name) / "statusbar-ai-usage" / "history.json"
        hist.parent.mkdir(parents=True)
        hist.write_text("[[[")
        self.assertEqual(self.cli(self.payload(30)), "0/98 today · 30/43% wtd")

    def test_corrupt_or_old_state_file_is_ignored(self):
        path = Path(self.tmp.name) / "claude-statusline" / "quota-pace.json"
        path.parent.mkdir(parents=True)
        for content in [
            "{corrupt",
            json.dumps({"resets_at": self.reset, "day": 1, "baseline": 13.0, "last": 13.0}),  # v1
            json.dumps({"v": 2, "day": {"resets_at": "x"}, "hour": {"samples": []}}),
            json.dumps({"v": 2, "day": None, "hour": {"samples": [[1, "nan"]]}}),
        ]:
            with self.subTest(content=content):
                path.write_text(content)
                self.assertEqual(self.cli(self.payload(30, 5)).rsplit(" · ", 1)[0], "0/98 today · 30/43% wtd")


if __name__ == "__main__":
    unittest.main()
