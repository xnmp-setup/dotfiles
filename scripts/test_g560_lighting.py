"""G560 night tint and its scheduler, against isolated state and a fake CLI."""

import importlib.machinery
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[1]
LIGHTING = REPO / "dot_local/bin/executable_g560-lighting"
sys.path.insert(0, str(REPO / "dot_config/hypr"))


def load_module(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    loader.exec_module(module)
    return module


solar = load_module("hyprshade_solar", REPO / "dot_config/hypr/executable_hyprshade_solar.py")
lighting = load_module("g560_lighting", LIGHTING)
nightlight = load_module("g560_nightlight", REPO / "dot_config/hypr/executable_g560_nightlight.py")


class WarmTests(unittest.TestCase):
    def test_blue_drops_most_and_red_is_kept(self):
        r, g, b = lighting.warm(bytes.fromhex("1f226a"))
        self.assertEqual(r, 0x1F)
        self.assertLess(g, 0x22)
        self.assertLess(b, 0x6A)
        self.assertLess(b / 0x6A, g / 0x22)

    def test_slight_not_muddy(self):
        # A blue accent stays blue at night, just warmer.
        r, g, b = lighting.warm(bytes.fromhex("1f226a"))
        self.assertGreater(b, max(r, g))

    def test_black_and_clamping(self):
        self.assertEqual(lighting.warm(b"\x00\x00\x00"), b"\x00\x00\x00")
        self.assertEqual(lighting.warm(b"\xff\xff\xff", (2.0, 1.0, -1.0)), b"\xff\xff\x00")


class PhaseFileTests(unittest.TestCase):
    """g560-lighting reads the phase the scheduler writes."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.runtime = Path(temporary.name)
        self.phase = self.runtime / "g560-lighting" / "phase"
        patcher = patch.dict(os.environ, {"XDG_RUNTIME_DIR": str(self.runtime)})
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_round_trip(self):
        self.assertFalse(lighting.night_light_on())  # no file yet
        nightlight.write_phase(self.phase, True)
        self.assertTrue(lighting.night_light_on())
        nightlight.write_phase(self.phase, False)
        self.assertFalse(lighting.night_light_on())
        self.assertEqual([p.name for p in self.phase.parent.iterdir()], ["phase"])

    def test_garbage_or_no_runtime_dir_is_day(self):
        self.phase.parent.mkdir(parents=True)
        self.phase.write_text("NIGHT?\n")
        self.assertFalse(lighting.night_light_on())
        with patch.dict(os.environ, {}, clear=True):
            self.assertFalse(lighting.night_light_on())


class TargetColourTests(unittest.TestCase):
    """The tint applies to the stored theme colour, never an explicit one."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.colour = root / "state/g560-lighting/colour"
        self.phase = root / "run/g560-lighting/phase"
        patcher = patch.dict(os.environ, {
            "XDG_STATE_HOME": str(root / "state"), "XDG_RUNTIME_DIR": str(root / "run")})
        patcher.start()
        self.addCleanup(patcher.stop)

    def store(self, colour):
        self.colour.parent.mkdir(parents=True, exist_ok=True)
        self.colour.write_text(colour + "\n")

    def test_stored_colour_by_day_is_unchanged(self):
        self.store("1f226a")
        nightlight.write_phase(self.phase, False)
        self.assertEqual(lighting.target_colour(), bytes.fromhex("1f226a"))

    def test_stored_colour_at_night_is_warmed(self):
        self.store("1f226a")
        nightlight.write_phase(self.phase, True)
        self.assertEqual(lighting.target_colour(), lighting.warm(bytes.fromhex("1f226a")))
        self.assertNotEqual(lighting.target_colour(), bytes.fromhex("1f226a"))

    def test_explicit_colour_is_exact_even_at_night(self):
        nightlight.write_phase(self.phase, True)
        self.assertEqual(lighting.target_colour("#3439b1"), bytes.fromhex("3439b1"))

    def test_nothing_stored(self):
        self.assertIsNone(lighting.target_colour())

    def test_malformed_colours_exit(self):
        for bad in ("zz", "12345", "ff00ff00", ""):
            with self.subTest(bad=bad), self.assertRaises(SystemExit):
                lighting.target_colour(bad)
        self.store("not-a-colour")
        with self.assertRaises(SystemExit):
            lighting.target_colour()


class SchedulerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.phase = self.root / "g560-lighting" / "phase"
        self.calls = self.root / "calls"
        self.cli = self.root / "fake-g560-lighting"

    def fake_cli(self, status):
        self.cli.write_text(f"#!/bin/sh\necho call >> '{self.calls}'\nexit {status}\n")
        self.cli.chmod(0o755)

    def run_ticks(self, nights):
        """Run the scheduler loop over a sequence of night/day states."""
        ticks = iter(nights)
        alive = iter([False] * len(nights) + [True])
        with patch.object(nightlight, "is_night", side_effect=lambda *a: next(ticks)), \
             patch.object(nightlight, "compositor_gone", side_effect=lambda *a: next(alive)), \
             patch.object(nightlight.time, "sleep"):
            nightlight.run_scheduler(-33.87, 151.21, self.phase, str(self.cli))

    def call_count(self):
        return len(self.calls.read_text().splitlines()) if self.calls.exists() else 0

    def test_applies_once_per_flip(self):
        self.fake_cli(0)
        self.run_ticks([True, True, True, False, False])
        self.assertEqual(self.call_count(), 2)
        self.assertEqual(self.phase.read_text(), "day\n")

    def test_unplugged_speaker_is_settled(self):
        self.fake_cli(3)
        self.run_ticks([True, True])
        self.assertEqual(self.call_count(), 1)
        self.assertEqual(self.phase.read_text(), "night\n")

    def test_failure_retries_next_tick(self):
        self.fake_cli(75)
        with patch("sys.stderr"):
            self.run_ticks([True, True, True])
        self.assertEqual(self.call_count(), 3)

    def test_exits_quietly_without_g560_lighting(self):
        with patch.object(nightlight.shutil, "which", return_value=None), \
             patch.object(nightlight.Path, "home", return_value=self.root / "nohome"), \
             patch.dict(os.environ, {"XDG_RUNTIME_DIR": str(self.root)}):
            self.assertEqual(nightlight.main(["--lat", "0", "--lon", "0"]), 0)
        self.assertFalse(self.phase.exists())


if __name__ == "__main__":
    unittest.main()
