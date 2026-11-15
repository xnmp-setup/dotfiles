#!/usr/bin/env python3
"""Tell the Logitech G560 lighting when the night light is on.

Keeps $XDG_RUNTIME_DIR/g560-lighting/phase at "night" or "day" on the night
light's own solar schedule (hyprshade_solar's sunset/sunrise, coordinates
from nightlight.lua), and re-runs g560-lighting (~/.local/bin) whenever it
flips, which warms the speaker's colour at night. g560-lighting also reads
the file itself, so set-theme, login and hotplug apply the same tint.

Started by Hyprland alongside the night light. Exits quietly where
g560-lighting is not installed; a machine without the speaker just keeps the
file current, so a speaker plugged in later comes up with the right tint.
"""

from __future__ import annotations

import argparse
import fcntl
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

from hyprshade_solar import (
    calc_sun,
    compositor_gone,
    compositor_socket,
    is_night,
    next_transition,
    solar_day_start,
)

# A monotonic sleep does not advance during suspend; wake at least once a
# minute so resuming across sunset or sunrise catches up promptly.
MAX_SLEEP_SECONDS = 60
# g560-lighting's "no G560 connected": settled, the hotplug unit applies later.
EXIT_NOT_CONNECTED = 3


def write_phase(path: Path, night: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text("night\n" if night else "day\n")
    temporary.replace(path)


def apply(lighting: str) -> bool:
    """Push the colour; False means retry on the next tick."""
    result = subprocess.run([lighting], capture_output=True, text=True)
    if result.returncode in (0, EXIT_NOT_CONNECTED):
        return True
    print(
        f"g560_nightlight: g560-lighting failed: "
        f"{result.stderr.strip() or result.returncode}",
        file=sys.stderr,
    )
    return False


def run_scheduler(lat: float, lon: float, phase_file: Path, lighting: str) -> None:
    socket = compositor_socket()
    applied: Optional[bool] = None
    while not compositor_gone(socket):
        now = time.time()
        day_start = solar_day_start(now, lon)
        sun = calc_sun(day_start, lat)
        night = is_night(now, sun)
        if night != applied:
            write_phase(phase_file, night)
            if apply(lighting):
                applied = night
        deadline = min(next_transition(now, sun, day_start), now + MAX_SLEEP_SECONDS)
        time.sleep(max(1.0, deadline - now))


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--lat", type=float, required=True)
    parser.add_argument("--lon", type=float, required=True)
    args = parser.parse_args(argv)

    lighting = shutil.which("g560-lighting") or str(Path.home() / ".local/bin/g560-lighting")
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if not os.access(lighting, os.X_OK) or not runtime:
        return 0
    phase_file = Path(runtime) / "g560-lighting" / "phase"

    # One scheduler per compositor, as desktop_theme_solar does.
    socket = compositor_socket()
    lock_dir = Path(socket) if socket else phase_file.parent
    lock_dir.mkdir(parents=True, exist_ok=True)
    with (lock_dir / "g560-nightlight.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        run_scheduler(args.lat, args.lon, phase_file, lighting)
    return 0


if __name__ == "__main__":
    sys.exit(main())
