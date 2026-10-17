#!/usr/bin/env python3
"""Switch a dark desktop theme to a random installed light theme at sunrise.

Started by Hyprland on desktops and laptops; other platforms do not launch it.
Uses the night light's solar calculation and coordinates. A daytime login
catches a missed sunrise, then manual theme choices last until the next one.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import random
import subprocess
import sys
import time
from pathlib import Path

from hyprshade_solar import (
    calc_sun,
    compositor_gone,
    compositor_socket,
    is_night,
    next_transition,
    solar_day_start,
)

# A monotonic sleep does not advance during suspend. Check at least once a
# minute so resuming after sunrise promptly catches up.
MAX_SLEEP_SECONDS = 60


def switch_to_random_light(theme_cli: Path, state_dir: Path) -> bool:
    """Apply once if dark; return False on failure so the next tick retries."""
    try:
        # Share the Vicinae worker's lock, checking the current mode only after
        # acquiring it. Children must not inherit it (subprocess closes FDs).
        with (state_dir / "apply.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return False

            try:
                state = json.loads((state_dir / "current.json").read_text())
            except (FileNotFoundError, ValueError):
                # An unknown theme is not evidence of a dark theme.
                return True
            if not isinstance(state, dict) or state.get("mode") != "dark":
                return True

            listing = subprocess.run(
                ["bash", str(theme_cli), "--list-light-desktop-themes"],
                capture_output=True,
                text=True,
                check=True,
            )
            themes = listing.stdout.splitlines()
            if not themes:
                print(
                    "desktop_theme_solar: no complete light themes installed",
                    file=sys.stderr,
                )
                return False
            theme = random.choice(themes)
            subprocess.run(["bash", str(theme_cli), theme], check=True)
            return True
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"desktop_theme_solar: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.rstrip(), file=sys.stderr)
        return False


def run_scheduler(lat: float, lon: float, theme_cli: Path, state_dir: Path) -> None:
    socket = compositor_socket()
    handled_sunrise = None
    while not compositor_gone(socket):
        now = time.time()
        day_start = solar_day_start(now, lon)
        sun = calc_sun(day_start, lat)
        night = is_night(now, sun)

        # Consume each sunrise once, even if suspend skips the entire night.
        # Rechecking throughout one day would undo a manual dark-theme choice.
        if not night and sun.sunrise is not None and sun.sunrise != handled_sunrise:
            if switch_to_random_light(theme_cli, state_dir):
                handled_sunrise = sun.sunrise

        deadline = min(next_transition(now, sun, day_start), now + MAX_SLEEP_SECONDS)
        time.sleep(max(1.0, deadline - now))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--lat", type=float, required=True)
    parser.add_argument("--lon", type=float, required=True)
    args = parser.parse_args(argv)

    theme_cli = Path.home() / ".local/share/chezmoi/scripts/set-theme.sh"
    if not theme_cli.is_file():
        print("desktop_theme_solar: set-theme.sh not found, not scheduling", file=sys.stderr)
        return 0

    state_root = os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state"
    state_dir = Path(state_root) / "desktop-theme"
    state_dir.mkdir(parents=True, exist_ok=True)
    # Scope daemon ownership to the compositor. A fast logout/login must not
    # lose its scheduler while the old session's daemon is still waking up.
    socket = compositor_socket()
    lock_dir = Path(socket) if socket else state_dir
    with (lock_dir / "desktop-theme-solar.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        run_scheduler(args.lat, args.lon, theme_cli, state_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
