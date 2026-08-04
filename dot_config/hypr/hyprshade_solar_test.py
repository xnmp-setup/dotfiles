#!/usr/bin/env python3
"""Tests for hyprshade_solar. Run: python3 hyprshade_solar_test.py"""

import importlib.util
import math
import os
import sys
import time

_SPEC = importlib.util.spec_from_file_location(
    "hyprshade_solar",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "hyprshade_solar.py"),
)
solar = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(solar)

SYDNEY = (-33.87, 151.21)
TROMSO = (69.65, 18.96)

failures = []


def check(name, condition):
    print(("ok   " if condition else "FAIL ") + name)
    if not condition:
        failures.append(name)


def utc(year, month, day, hour=0):
    return time.mktime((year, month, day, hour, 0, 0, 0, 0, 0)) - time.timezone


def utc_hhmm(moment):
    return time.strftime("%H:%M", time.gmtime(moment))


def sun_for(coords, moment):
    lat, lon = coords
    return solar.calc_sun(solar.solar_day_start(moment, lon), lat)


# -----------------------------------------------------------------------------
# Solar times
# -----------------------------------------------------------------------------

# The point of the port: identical times to wlsunset. Cross-checked against
# `wlsunset -l -33.87 -L 151.21`, which reported "sunrise 07:01, sunset 17:01"
# in Australia/Sydney on this date -- 21:01 and 07:01 UTC respectively.
observed = sun_for(SYDNEY, utc(2026, 8, 4, 12))
check("sunrise matches wlsunset 0.4.0", utc_hhmm(observed.sunrise) == "21:01")
check("sunset matches wlsunset 0.4.0", utc_hhmm(observed.sunset) == "07:01")

# Sydney, mid-winter and mid-summer. wlsunset's sunrise/sunset sit 3 degrees
# above the true horizon, so they fall ~13 minutes inside the almanac's
# sunrise 07:00 / sunset 16:57 (Jun 21) and 05:42 / 20:09 (Dec 21).
winter = sun_for(SYDNEY, utc(2026, 6, 21, 12))
check("winter sunrise is mid-morning UTC", utc_hhmm(winter.sunrise) == "21:14")
check("winter sunset is late-morning UTC", utc_hhmm(winter.sunset) == "06:38")

summer = sun_for(SYDNEY, utc(2026, 12, 21, 12))
check("summer sunrise is earlier than winter's",
      summer.sunrise - solar.solar_day_start(utc(2026, 12, 21, 12), SYDNEY[1])
      < winter.sunrise - solar.solar_day_start(utc(2026, 6, 21, 12), SYDNEY[1]))
check("summer day is longer than winter's",
      (summer.sunset - summer.sunrise) > (winter.sunset - winter.sunrise))

check("sunset follows sunrise within one solar day", winter.sunrise < winter.sunset)
check("temperate latitudes always see the sun", not math.isnan(winter.sunrise))

# The equator's day length barely moves across the year.
equator_jun = sun_for((0.0, 0.0), utc(2026, 6, 21, 12))
equator_dec = sun_for((0.0, 0.0), utc(2026, 12, 21, 12))
check("equatorial day length is stable year round",
      abs((equator_jun.sunset - equator_jun.sunrise)
          - (equator_dec.sunset - equator_dec.sunrise)) < 300)

# -----------------------------------------------------------------------------
# Polar days
# -----------------------------------------------------------------------------

polar_summer = sun_for(TROMSO, utc(2026, 6, 21, 12))
check("midnight sun has no sunrise", polar_summer.sunrise is None)
check("midnight sun leaves the shader off",
      not solar.is_night(utc(2026, 6, 21, 2), polar_summer))

polar_winter = sun_for(TROMSO, utc(2026, 12, 21, 12))
check("polar night has no sunrise", polar_winter.sunrise is None)
check("polar night leaves the shader on",
      solar.is_night(utc(2026, 12, 21, 12), polar_winter))

check("a polar day resolves at the next solar day",
      solar.next_transition(utc(2026, 12, 21, 12), polar_winter,
                            solar.solar_day_start(utc(2026, 12, 21, 12), TROMSO[1]))
      == solar.solar_day_start(utc(2026, 12, 21, 12), TROMSO[1]) + 86400)

# -----------------------------------------------------------------------------
# Night detection
# -----------------------------------------------------------------------------

day_start = solar.solar_day_start(utc(2026, 6, 21, 12), SYDNEY[1])
sun = solar.calc_sun(day_start, SYDNEY[0])

check("the small hours before sunrise are night", solar.is_night(sun.sunrise - 60, sun))
check("just after sunrise is not night", not solar.is_night(sun.sunrise + 60, sun))
check("midday is not night", not solar.is_night((sun.sunrise + sun.sunset) / 2, sun))
check("sunset itself is night", solar.is_night(sun.sunset, sun))
check("after sunset is night", solar.is_night(sun.sunset + 60, sun))

# -----------------------------------------------------------------------------
# Scheduling
# -----------------------------------------------------------------------------

check("before sunrise, the next transition is sunrise",
      solar.next_transition(sun.sunrise - 3600, sun, day_start) == sun.sunrise)
check("during the day, the next transition is sunset",
      solar.next_transition(sun.sunrise + 3600, sun, day_start) == sun.sunset)
check("after sunset, the next transition is the following solar day",
      solar.next_transition(sun.sunset + 3600, sun, day_start) == day_start + 86400)

# Walking a whole year one hour at a time must never schedule into the past
# and must always agree with is_night on both sides of a transition.
consistent = True
never_backwards = True
for hour in range(0, 24 * 365, 1):
    moment = utc(2026, 1, 1) + hour * 3600
    start = solar.solar_day_start(moment, SYDNEY[1])
    today = solar.calc_sun(start, SYDNEY[0])
    upcoming = solar.next_transition(moment, today, start)
    if upcoming <= moment:
        never_backwards = False
    just_after = upcoming + 1
    after_start = solar.solar_day_start(just_after, SYDNEY[1])
    after = solar.calc_sun(after_start, SYDNEY[0])
    if solar.is_night(moment, today) == solar.is_night(just_after, after):
        # Crossing a solar-day boundary is not itself a change of state.
        if upcoming != start + 86400:
            consistent = False

check("the next transition is always in the future", never_backwards)
check("a scheduled transition always flips the shader", consistent)

# -----------------------------------------------------------------------------
# Solar day boundaries
# -----------------------------------------------------------------------------

check("the solar day starts at or before now",
      solar.solar_day_start(utc(2026, 6, 21, 12), SYDNEY[1]) <= utc(2026, 6, 21, 12))
check("the solar day is at most 24h long",
      utc(2026, 6, 21, 12)
      - solar.solar_day_start(utc(2026, 6, 21, 12), SYDNEY[1]) < 86400)
check("antipodal longitudes start their day 12h apart",
      abs(((solar.solar_day_start(utc(2026, 6, 21, 12), 0.0)
            - solar.solar_day_start(utc(2026, 6, 21, 12), 180.0)) % 86400) - 43200)
      < 1)

# -----------------------------------------------------------------------------
# Compositor lifetime
# -----------------------------------------------------------------------------

os.environ.pop("XDG_RUNTIME_DIR", None)
os.environ.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
check("no Hyprland environment means nothing to watch",
      solar.compositor_socket() is None)
check("an unwatchable compositor is never assumed dead",
      not solar.compositor_gone(None))

os.environ["XDG_RUNTIME_DIR"] = os.path.dirname(os.path.abspath(__file__))
os.environ["HYPRLAND_INSTANCE_SIGNATURE"] = "deadbeef"
check("a signature yields a socket under the runtime dir",
      solar.compositor_socket().endswith(os.path.join("hypr", "deadbeef")))
check("a missing socket means the compositor exited",
      solar.compositor_gone(solar.compositor_socket()))
check("an existing socket means the compositor lives",
      not solar.compositor_gone(os.path.dirname(os.path.abspath(__file__))))

# -----------------------------------------------------------------------------
# Argument handling
# -----------------------------------------------------------------------------

args = solar.parse_args(["--lat", "-33.87", "--lon", "151.21"])
check("coordinates parse as floats", args.lat == -33.87 and args.lon == 151.21)
check("the night shader defaults to nightlight", args.shader == "nightlight")
check("formatting a missing time does not crash",
      solar.format_local(None) == "--:--:--")

print()
if failures:
    print(f"{len(failures)} failure(s): " + ", ".join(failures))
    sys.exit(1)
print("all tests passed")
