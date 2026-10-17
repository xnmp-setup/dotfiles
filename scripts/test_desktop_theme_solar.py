"""Sunrise theme behavior, with isolated state and a recording theme CLI."""

import fcntl
import importlib.util
import json
import os
from pathlib import Path
import pty
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[1]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


solar = load_module("hyprshade_solar", REPO / "dot_config/hypr/executable_hyprshade_solar.py")
scheduler = load_module("desktop_theme_solar", REPO / "dot_config/hypr/executable_desktop_theme_solar.py")


class SunriseThemeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="sunrise theme ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.state = self.root / "current.json"
        self.log = self.root / "applied"
        self.cli = self.root / "set-theme.sh"
        self.cli.write_text('''#!/usr/bin/env bash
set -eu
cd -- "$(dirname -- "$0")"
if [[ "$1" == --list-light-desktop-themes ]]; then
  [[ ! -e listing-fails ]] || exit 1
  cat available
  exit 0
fi
[[ ! -e apply-fails ]] || exit 1
if [[ -e require-noninteractive-input && -t 0 ]]; then exit 42; fi
printf '%s\\n' "$1" >> applied
printf '{"mode":"light","slug":"%s"}\\n' "$1" > current.json
''')
        (self.root / "available").write_text("mapquest\nayu-light\ncatppuccin-latte\n")
        self.set_mode("dark")
        start = solar.solar_day_start(1782000000, 151.21)
        self.sun = solar.calc_sun(start, -33.87)
        self.tomorrow = solar.calc_sun(start + 86400, -33.87)

    def set_mode(self, mode):
        self.state.write_text(json.dumps({"mode": mode}))

    def applied(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def switch(self):
        return scheduler.switch_to_random_light(self.cli, self.root)

    def run_at(self, moments, after_tick=None):
        with (
            patch.object(scheduler, "compositor_gone", side_effect=[False] * len(moments) + [True]),
            patch.object(scheduler.time, "time", side_effect=moments),
            patch.object(scheduler.time, "sleep", side_effect=after_tick) as sleep,
        ):
            scheduler.run_scheduler(-33.87, 151.21, self.cli, self.root)
        return sleep

    def test_dark_theme_changes_to_an_available_light_theme(self):
        self.assertTrue(self.switch())
        self.assertEqual(len(self.applied()), 1)
        self.assertIn(self.applied()[0], ["mapquest", "ayu-light", "catppuccin-latte"])
        self.assertEqual(json.loads(self.state.read_text())["mode"], "light")

    def test_compositor_terminal_is_not_passed_to_the_theme_command(self):
        (self.root / "require-noninteractive-input").touch()
        master, terminal = pty.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, terminal)
        code = """
from pathlib import Path
import sys
from scripts.test_desktop_theme_solar import scheduler
sys.exit(0 if scheduler.switch_to_random_light(Path(sys.argv[1]), Path(sys.argv[2])) else 1)
"""
        result = subprocess.run(
            [sys.executable, "-c", code, str(self.cli), str(self.root)],
            cwd=REPO,
            stdin=terminal,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.state.read_text())["mode"], "light")

    def test_already_light_and_unknown_states_are_preserved(self):
        for state in [{"mode": "light"}, {}, None, [], "dark", {"mode": None}]:
            with self.subTest(state=state):
                self.state.write_text(json.dumps(state))
                before = self.state.read_bytes()
                self.assertTrue(self.switch())
                self.assertEqual(self.applied(), [])
                self.assertEqual(self.state.read_bytes(), before)

    def test_missing_and_malformed_state_are_preserved(self):
        self.state.unlink()
        self.assertTrue(self.switch())
        for text in ["", "{invalid", "\ufffd"]:
            self.state.write_text(text)
            self.assertTrue(self.switch())
            self.assertEqual(self.state.read_text(), text)
        self.assertEqual(self.applied(), [])

    def test_no_available_theme_keeps_dark_theme_and_allows_retry(self):
        (self.root / "available").write_text("")
        self.assertFalse(self.switch())
        self.assertEqual(json.loads(self.state.read_text())["mode"], "dark")
        self.assertEqual(self.applied(), [])

    def test_cli_failures_allow_retry(self):
        for marker in ["listing-fails", "apply-fails"]:
            with self.subTest(marker=marker):
                path = self.root / marker
                path.touch()
                self.assertFalse(self.switch())
                self.assertEqual(self.applied(), [])
                self.assertEqual(json.loads(self.state.read_text())["mode"], "dark")
                path.unlink()

    def test_active_manual_theme_change_is_not_interrupted(self):
        with (self.root / "apply.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertFalse(self.switch())
            self.assertEqual(self.applied(), [])
        self.assertTrue(self.switch())

    def test_nighttime_does_not_change_the_theme(self):
        self.run_at([self.sun.sunrise - 60, self.sun.sunset, self.sun.sunset + 60])
        self.assertEqual(self.applied(), [])

    def test_sunrise_and_daytime_login_switch_dark_themes(self):
        self.run_at([self.sun.sunrise - 60, self.sun.sunrise, self.sun.sunrise + 60])
        self.assertEqual(len(self.applied()), 1)
        self.set_mode("dark")
        self.run_at([self.sun.sunrise + 3600])
        self.assertEqual(len(self.applied()), 2)

    def test_resume_after_sunrise_catches_up(self):
        sleep = self.run_at([self.sun.sunrise - 3600, self.sun.sunrise + 3600])
        self.assertEqual(len(self.applied()), 1)
        self.assertTrue(all(0 < call.args[0] <= 60 for call in sleep.call_args_list))

    def test_manual_daytime_dark_theme_lasts_until_next_sunrise(self):
        def choose_dark(_):
            self.set_mode("dark")

        self.run_at([
            self.sun.sunrise, self.sun.sunrise + 60,
            self.sun.sunset, self.tomorrow.sunrise,
        ], after_tick=choose_dark)
        self.assertEqual(len(self.applied()), 2)

    def test_suspending_through_the_entire_night_catches_up(self):
        self.set_mode("light")
        self.run_at([self.sun.sunrise + 3600, self.tomorrow.sunrise + 3600],
                    after_tick=lambda _: self.set_mode("dark"))
        self.assertEqual(len(self.applied()), 1)

    def test_light_theme_at_sunrise_is_preserved_all_day(self):
        self.set_mode("light")
        self.run_at([self.sun.sunrise, self.sun.sunrise + 60],
                    after_tick=lambda _: self.set_mode("dark"))
        self.assertEqual(self.applied(), [])

    def test_failed_switch_is_retried_on_the_next_tick(self):
        marker = self.root / "apply-fails"
        marker.touch()
        self.run_at([self.sun.sunrise, self.sun.sunrise + 60],
                    after_tick=lambda _: marker.unlink(missing_ok=True))
        self.assertEqual(len(self.applied()), 1)

    def test_exited_compositor_stops_theme_changes(self):
        self.run_at([])
        self.assertEqual(self.applied(), [])

    def test_a_previous_session_does_not_block_the_new_scheduler(self):
        self.assert_scheduler_lock("old-session", starts=True)

    def test_duplicate_scheduler_in_one_session_does_not_start(self):
        self.assert_scheduler_lock("new-session", starts=False)

    def assert_scheduler_lock(self, locked_session, *, starts):
        runtime = self.root / "runtime"
        for session in ["old-session", "new-session"]:
            (runtime / "hypr" / session).mkdir(parents=True)
        cli = self.root / ".local/share/chezmoi/scripts/set-theme.sh"
        cli.parent.mkdir(parents=True)
        cli.write_bytes(self.cli.read_bytes())
        lock_path = runtime / "hypr" / locked_session / "desktop-theme-solar.lock"
        with (
            lock_path.open("a") as lock,
            patch.dict(os.environ, {
                "XDG_RUNTIME_DIR": str(runtime),
                "HYPRLAND_INSTANCE_SIGNATURE": "new-session",
                "XDG_STATE_HOME": str(self.root / "state"),
            }),
            patch.object(scheduler.Path, "home", return_value=self.root),
            patch.object(scheduler, "run_scheduler") as run,
        ):
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(scheduler.main(["--lat", "-33.87", "--lon", "151.21"]), 0)
            self.assertEqual(run.called, starts)


if __name__ == "__main__":
    unittest.main()
