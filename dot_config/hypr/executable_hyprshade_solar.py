#!/usr/bin/env python3
"""Toggle hyprshade's night-light shader at solar sunset and sunrise.

hyprshade can only schedule fixed wall-clock times (hyprshade.toml holds a
single start_time/end_time pair), so it cannot follow the sun on its own.
This daemon does the scheduling instead: it computes today's sunset and
sunrise for a latitude/longitude, turns the shader on or off accordingly,
and sleeps until the next transition.

The solar math is a deliberate port of wlsunset 0.4.0's color_math.c, down
to its quirks, so that laptops (which run a shader, because a shader applies
before output cloning) and desktops (which run wlsunset) warm their screens
at the same instants. Note wlsunset ramps its temperature between sunset and
dusk; a shader is on or off, so we switch at sunset/sunrise, the start of
wlsunset's evening ramp and the end of its morning one.

Requires: python3, and hyprshade on PATH. Absent hyprshade, this exits
quietly rather than looping on a command that will never work.
"""

from __future__ import annotations

import argparse
import math
import os
import shutil
import subprocess
import sys
import time
from typing import NamedTuple, Optional

# wlsunset's target zeniths, in radians. 90.833 deg is the standard horizon
# (geometric horizon plus refraction and the sun's radius); wlsunset places
# "sunrise"/"sunset" 3 deg above it, and dawn/dusk 6 deg below it.
SOLAR_SUNRISE_SUNSET = math.radians(90.833 - 3.0)

# Cap on a single sleep. time.sleep() is monotonic and so does not advance
# across suspend; waking hourly bounds how stale the shader can get after
# the machine resumes, and re-checks the clock across DST shifts.
MAX_SLEEP_SECONDS = 3600


class Sun(NamedTuple):
    """Epoch seconds of one solar day's transitions.

    ``sunrise`` and ``sunset`` are None under midnight sun or polar night,
    where the sun never crosses the target zenith; ``night`` then describes
    which of the two it is.
    """

    sunrise: Optional[float]
    sunset: Optional[float]
    night: bool


def _days_in_year(year: int) -> int:
    leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0
    return 366 if leap else 365


def _orbit_angle(day_of_year: int, year: int) -> float:
    return 2 * math.pi / _days_in_year(year) * day_of_year


def _equation_of_time(orbit_angle: float) -> float:
    # https://www.esrl.noaa.gov/gmd/grad/solcalc/solareqns.PDF
    a = orbit_angle
    return 4 * (
        0.000075
        + 0.001868 * math.cos(a)
        - 0.032077 * math.sin(a)
        - 0.014615 * math.cos(2 * a)
        - 0.040849 * math.sin(2 * a)
    )


def _sun_declination(orbit_angle: float) -> float:
    # https://www.esrl.noaa.gov/gmd/grad/solcalc/solareqns.PDF
    a = orbit_angle
    return (
        0.006918
        - 0.399912 * math.cos(a)
        + 0.070257 * math.sin(a)
        - 0.006758 * math.cos(2 * a)
        + 0.000907 * math.sin(2 * a)
        - 0.002697 * math.cos(3 * a)
        + 0.00148 * math.sin(3 * a)
    )


def _sun_hour_angle(latitude: float, declination: float, zenith: float) -> float:
    """Half the sun's time above ``zenith``, as an angle in radians.

    NaN when the sun never reaches that zenith (midnight sun / polar night).

    The grouping below mirrors wlsunset's, which reads cos(zenith) / cos(lat)
    * cos(decl) where NOAA's equation divides by the product. Reproducing it
    keeps the two backends in step; the disagreement is under two minutes at
    temperate latitudes, and shrinks towards the equator.
    """
    cos_hour_angle = (
        math.cos(zenith) / math.cos(latitude) * math.cos(declination)
        - math.tan(latitude) * math.tan(declination)
    )
    if not -1.0 <= cos_hour_angle <= 1.0:
        return math.nan
    return math.acos(cos_hour_angle)


def _hour_angle_to_offset(hour_angle: float, equation_of_time: float) -> float:
    """Seconds from the start of the solar day to the given hour angle."""
    # https://www.esrl.noaa.gov/gmd/grad/solcalc/solareqns.PDF
    return math.degrees((4.0 * math.pi - 4 * hour_angle - equation_of_time) * 60)


def solar_day_start(now: float, longitude: float) -> float:
    """Epoch seconds of the local solar midnight at or before ``now``.

    Solar rather than civil midnight, so a day's sunset and the sunrise that
    ends the same night always fall in one interval and never straddle a
    boundary.
    """
    offset = -math.radians(longitude) * 43200 / math.pi
    return now - ((now - offset) % 86400)


def calc_sun(day_start: float, latitude: float) -> Sun:
    """Sunrise and sunset for the solar day beginning at ``day_start``."""
    utc = time.gmtime(day_start)
    # C's struct tm counts Jan 1 as day 0, Python's as day 1; wlsunset feeds
    # the former into the orbit angle, and a day's offset is a minute's error.
    orbit_angle = _orbit_angle(utc.tm_yday - 1, utc.tm_year)
    declination = _sun_declination(orbit_angle)
    equation_of_time = _equation_of_time(orbit_angle)

    hour_angle = _sun_hour_angle(
        math.radians(latitude), declination, SOLAR_SUNRISE_SUNSET
    )
    if math.isnan(hour_angle):
        # wlsunset's rule: the sun stays up when the hemisphere it leans
        # towards is the one we are standing in, and stays down otherwise.
        leans_towards_us = (latitude >= 0) == (declination >= 0)
        return Sun(sunrise=None, sunset=None, night=not leans_towards_us)

    return Sun(
        sunrise=day_start + _hour_angle_to_offset(abs(hour_angle), equation_of_time),
        sunset=day_start + _hour_angle_to_offset(-abs(hour_angle), equation_of_time),
        night=False,
    )


def is_night(now: float, sun: Sun) -> bool:
    """Whether the night-light shader belongs on at ``now``."""
    if sun.sunrise is None or sun.sunset is None:
        return sun.night
    return now < sun.sunrise or now >= sun.sunset


def next_transition(now: float, sun: Sun, day_start: float) -> float:
    """Epoch seconds of the next change in :func:`is_night`.

    Polar days have no transition; they resolve at the next solar day, when
    fresh times get computed.
    """
    tomorrow = day_start + 86400
    if sun.sunrise is None or sun.sunset is None:
        return tomorrow
    for moment in (sun.sunrise, sun.sunset):
        if now < moment:
            return moment
    return tomorrow


def compositor_socket() -> Optional[str]:
    """Path to the running Hyprland instance's socket directory, if any.

    Absent the environment Hyprland exports to what it launches -- outside a
    Hyprland session, say -- there is nothing to watch, and we return None
    rather than treating it as a dead compositor.
    """
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    signature = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    if not runtime or not signature:
        return None
    return os.path.join(runtime, "hypr", signature)


def compositor_gone(socket: Optional[str]) -> bool:
    """Whether the Hyprland instance we started under has exited."""
    return socket is not None and not os.path.exists(socket)


def apply_shader(hyprshade: str, shader: str, night: bool) -> None:
    command = [hyprshade, "on", shader] if night else [hyprshade, "off"]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        print(
            f"hyprshade_solar: {' '.join(command)} failed: "
            f"{result.stderr.strip() or result.returncode}",
            file=sys.stderr,
        )


def format_local(moment: Optional[float]) -> str:
    if moment is None:
        return "--:--:--"
    return time.strftime("%H:%M:%S", time.localtime(moment))


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--lat", type=float, required=True, help="latitude, degrees")
    parser.add_argument("--lon", type=float, required=True, help="longitude, degrees")
    parser.add_argument(
        "--shader", default="nightlight", help="shader to apply at night"
    )
    parser.add_argument(
        "--print",
        dest="print_only",
        action="store_true",
        help="print today's times and the shader they imply, then exit",
    )
    return parser.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = parse_args(argv)

    if args.print_only:
        now = time.time()
        day_start = solar_day_start(now, args.lon)
        sun = calc_sun(day_start, args.lat)
        print(
            f"sunrise {format_local(sun.sunrise)}  "
            f"sunset {format_local(sun.sunset)}  "
            f"shader {'on' if is_night(now, sun) else 'off'}  "
            f"next {format_local(next_transition(now, sun, day_start))}"
        )
        return 0

    hyprshade = shutil.which("hyprshade")
    if hyprshade is None:
        print("hyprshade_solar: hyprshade not found, not scheduling", file=sys.stderr)
        return 0

    # Outliving our compositor would mean toggling a shader on a dead
    # instance forever, and a second copy at the next login.
    socket = compositor_socket()

    applied: Optional[bool] = None
    while True:
        if compositor_gone(socket):
            return 0
        now = time.time()
        day_start = solar_day_start(now, args.lon)
        sun = calc_sun(day_start, args.lat)
        night = is_night(now, sun)

        # Only act on a change, so a manual `hyprshade off` during the
        # evening stays off until the sun next moves.
        if night != applied:
            apply_shader(hyprshade, args.shader, night)
            applied = night

        deadline = min(next_transition(now, sun, day_start), now + MAX_SLEEP_SECONDS)
        time.sleep(max(1.0, deadline - now))


if __name__ == "__main__":
    sys.exit(main())
