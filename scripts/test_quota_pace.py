"""Weekly-limit pace segment for the Claude Code status line."""

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

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "dot_claude/scripts/executable_quota_pace.py"

spec = importlib.util.spec_from_file_location("quota_pace", SCRIPT)
qp = importlib.util.module_from_spec(spec)
sys.modules["quota_pace"] = qp
spec.loader.exec_module(qp)

DAY = 86_400
RESET = 2_000_000_000
START = RESET - 7 * DAY
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def at(day, hour=12):
    """Epoch inside the given 0-based day of the window."""
    return START + day * DAY + hour * 3600


def run(readings):
    """Feed (now, used) readings through the state machine; return last Pace."""
    state = None
    pace = None
    for now, used in readings:
        r = qp.Reading(used=used, resets_at=RESET, now=now)
        state = qp.advance_state(state, r)
        pace = qp.compute_pace(r, state)
    return pace


class WeeklyPace(unittest.TestCase):
    def test_on_track_is_end_of_today_share(self):
        self.assertAlmostEqual(run([(at(2), 34)]).on_track, 300 / 7)
        self.assertAlmostEqual(run([(at(0), 1)]).on_track, 100 / 7)
        self.assertAlmostEqual(run([(at(6), 90)]).on_track, 100)

    def test_last_second_of_window_is_day_seven(self):
        self.assertAlmostEqual(run([(RESET - 1, 50)]).on_track, 100)

    def test_severity_thresholds(self):
        self.assertEqual(qp.severity(40, 42), "ok")
        self.assertEqual(qp.severity(42, 42), "ok")
        self.assertEqual(qp.severity(43, 42), "over")
        self.assertEqual(qp.severity(63, 42), "way_over")
        self.assertEqual(qp.severity(5, 0), "way_over")
        self.assertEqual(qp.severity(0, 0), "ok")


class DailyAllowance(unittest.TestCase):
    def test_even_pace_gives_100_per_day(self):
        pace = run([(at(0, 23), 100 / 7), (at(1, 23), 200 / 7)])
        self.assertAlmostEqual(pace.day_quota, 100)
        self.assertAlmostEqual(pace.day_used, 100)

    def test_frugal_days_raise_todays_allowance(self):
        # 10% used over the first two days; 90% left across 5 days = 18%/day,
        # which is 126 in even-day units.
        pace = run([(at(1, 23), 10), (at(2, 1), 10), (at(2, 20), 15)])
        self.assertAlmostEqual(pace.day_quota, 90 / 5 * 7)
        self.assertAlmostEqual(pace.day_used, 5 * 7)

    def test_heavy_days_shrink_allowance(self):
        pace = run([(at(2, 23), 70), (at(3, 1), 70)])
        self.assertLess(pace.day_quota, 100)

    def test_baseline_is_last_reading_before_rollover(self):
        # Usage between the last pre-midnight reading and midnight is unknown,
        # so it is attributed to today rather than silently dropped.
        pace = run([(at(1, 20), 20), (at(2, 9), 30)])
        self.assertAlmostEqual(pace.day_used, 10 * 7)

    def test_first_ever_reading_mid_week_counts_from_now(self):
        pace = run([(at(3), 50)])
        self.assertEqual(pace.day_used, 0)
        self.assertAlmostEqual(pace.day_quota, 50 / 4 * 7)

    def test_new_window_on_day_one_starts_from_zero(self):
        state = qp.advance_state(None, qp.Reading(80, RESET - 7 * DAY, RESET - 8 * DAY))
        r = qp.Reading(used=3, resets_at=RESET, now=at(0))
        pace = qp.compute_pace(r, qp.advance_state(state, r))
        self.assertAlmostEqual(pace.day_used, 21)
        self.assertAlmostEqual(pace.day_quota, 100)

    def test_usage_drop_never_goes_negative(self):
        pace = run([(at(2, 1), 40), (at(2, 2), 10)])
        self.assertGreaterEqual(pace.day_used, 0)

    def test_exhausted_limit_has_zero_allowance(self):
        pace = run([(at(4, 23), 100), (at(5, 1), 100)])
        self.assertEqual(pace.day_quota, 0)
        self.assertEqual(pace.day_used, 0)


class HistoryBaseline(unittest.TestCase):
    def reading(self, day, used, hour=12):
        return qp.Reading(used=used, resets_at=RESET, now=at(day, hour))

    def test_uses_last_sample_before_day_start(self):
        samples = [[at(1, 5), 10, None], [at(2, 23), 30, 5], [at(3, 1), 33, None]]
        self.assertEqual(qp.baseline_from_history(samples, self.reading(3, 40)), 30.0)

    def test_ignores_previous_window_and_later_samples(self):
        samples = [[START - 3600, 90, None], [at(3, 1), 33, None]]
        self.assertIsNone(qp.baseline_from_history(samples, self.reading(3, 40)))

    def test_first_day_is_zero_without_samples(self):
        self.assertEqual(qp.baseline_from_history([], self.reading(0, 4)), 0.0)

    def test_skips_malformed_samples(self):
        good = [at(1, 20), 12]
        junk = [None, "x", [], [at(1, 21)], [True, 50], [at(1, 21), "50"], [float("nan"), 1], {"a": 1}]
        self.assertEqual(qp.baseline_from_history(junk + [good], self.reading(2, 20)), 12.0)

    def test_history_overrides_inferred_state(self):
        r = self.reading(6, 65)
        seeded = qp.advance_state(None, r)  # no history: counts from now
        self.assertEqual(qp.compute_pace(r, seeded).day_used, 0)
        fixed = qp.advance_state(seeded, r, history_baseline=63.0)
        pace = qp.compute_pace(r, fixed)
        self.assertAlmostEqual(pace.day_used, 14)
        self.assertAlmostEqual(pace.day_quota, 259)


class ParseReading(unittest.TestCase):
    NOW = at(2)

    def payload(self, week):
        return {"rate_limits": {"seven_day": week}}

    def test_epoch_and_iso_reset(self):
        r = qp.parse_reading(self.payload({"used_percentage": 34, "resets_at": RESET}), self.NOW)
        self.assertEqual((r.used, r.resets_at), (34.0, RESET))
        iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(RESET))
        r = qp.parse_reading(self.payload({"used_percentage": 34, "resets_at": iso}), self.NOW)
        self.assertEqual(r.resets_at, RESET)

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
        self.assertEqual((hi.used, lo.used), (100.0, 0.0))


class Render(unittest.TestCase):
    def test_text_matches_spec(self):
        pace = qp.Pace(used=34, on_track=300 / 7, day_used=80, day_quota=120)
        self.assertEqual(ANSI.sub("", qp.render(pace)), "wk 34/43%  day 80/120")

    def test_colors_by_severity_per_theme(self):
        for theme, pal in qp.PALETTES.items():
            way = qp.render(qp.Pace(70, 300 / 7, 50, 100), theme)
            self.assertIn(f"38;5;{pal['way_over']}m70/43%", way)
            self.assertIn(f"38;5;{pal['ok']}m50/100", way)
            over = qp.render(qp.Pace(50, 300 / 7, 110, 100), theme)
            self.assertIn(f"38;5;{pal['over']}m50/43%", over)
            self.assertIn(f"38;5;{pal['over']}m110/100", over)


class Cli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = {**os.environ, "XDG_STATE_HOME": self.tmp.name, "XDG_CACHE_HOME": self.tmp.name}

    def tearDown(self):
        self.tmp.cleanup()

    def cli(self, stdin):
        out = subprocess.run(
            [sys.executable, str(SCRIPT), "--theme", "light"],
            input=stdin, capture_output=True, text=True, env=self.env, timeout=10,
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        return ANSI.sub("", out.stdout)

    def test_prints_segment_and_persists_across_renders(self):
        reset = int(time.time()) + 4 * DAY + 3600  # currently day 3 (index 2)
        payload = lambda u: json.dumps({"rate_limits": {"seven_day": {"used_percentage": u, "resets_at": reset}}})
        self.assertEqual(self.cli(payload(30)), "wk 30/43%  day 0/98")
        self.assertEqual(self.cli(payload(32)), "wk 32/43%  day 14/98")

    def test_silent_without_limits_or_on_garbage(self):
        for stdin in ["", "not json", "{}", json.dumps({"rate_limits": {}})]:
            with self.subTest(stdin=stdin):
                self.assertEqual(self.cli(stdin), "")

    def test_reads_start_of_day_from_desktop_bar_history(self):
        now = int(time.time())
        reset = now + 4 * DAY + 3600  # day index 2 began 23h ago
        hist = Path(self.tmp.name) / "statusbar-ai-usage" / "history.json"
        hist.parent.mkdir(parents=True)
        hist.write_text(json.dumps({"version": 1, "providers": {"claude": [
            [now - DAY, 20.0, None], [now - 3 * 3600, 25.0, None]]}}))
        out = self.cli(json.dumps({"rate_limits": {"seven_day": {"used_percentage": 30, "resets_at": reset}}}))
        self.assertEqual(out, "wk 30/43%  day 70/112")

    def test_corrupt_history_falls_back(self):
        hist = Path(self.tmp.name) / "statusbar-ai-usage" / "history.json"
        hist.parent.mkdir(parents=True)
        hist.write_text("[[[")
        reset = int(time.time()) + 4 * DAY + 3600
        out = self.cli(json.dumps({"rate_limits": {"seven_day": {"used_percentage": 30, "resets_at": reset}}}))
        self.assertEqual(out, "wk 30/43%  day 0/98")

    def test_corrupt_state_file_is_ignored(self):
        path = Path(self.tmp.name) / "claude-statusline" / "quota-pace.json"
        path.parent.mkdir(parents=True)
        path.write_text("{corrupt")
        reset = int(time.time()) + 4 * DAY + 3600
        out = self.cli(json.dumps({"rate_limits": {"seven_day": {"used_percentage": 30, "resets_at": reset}}}))
        self.assertTrue(out.startswith("wk 30/43%"))


if __name__ == "__main__":
    unittest.main()
