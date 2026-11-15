# Logitech G560 speaker lighting from a theme palette.
#
# The speaker's LEDs follow the theme's accent. set-theme stores the LED colour
# in a state file and runs g560-lighting (~/.local/bin) to push it over HID++;
# the g560-lighting user unit re-applies the stored colour at login and on
# hotplug, because the speaker forgets its lighting on power loss. The device
# side (udev rule granting the seat user the HID node) is installed by
# run_onchange_after_install-g560-lighting.sh — see scripts/system/g560.

g560_theme_error=""

g560_colour_file() {
  printf '%s/g560-lighting/colour\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# Screen colour -> LED drive colour (RRGGBB, no '#').
#
# LED PWM is linear in light, so sRGB values sent as-is look washed out
# (pastel accents read as near-white). Decode sRGB to linear light — the gamma
# correction LED controllers such as WLED apply — which keeps the accent's own
# brightness: a muted accent stays a deep colour rather than being driven to
# full. G560_LED_BRIGHTNESS (percent) then dims everything: the G560's LEDs at
# full PWM read much brighter than the same colour on screen. Only a
# near-black result is lifted (hue kept) to G560_LED_FLOOR on its brightest
# channel, so a dark accent still lights the speaker. Black stays black.
G560_LED_BRIGHTNESS=60
G560_LED_FLOOR=48
g560_led_colour() {
  local hex
  hex=$(norm_hex "$1")
  [[ "$hex" =~ ^[[:xdigit:]]{6}$ ]] || return 1
  # Hex parsing in bash: strtonum is gawk-only (mawk, BWK awk lack it).
  awk -v r=$((16#${hex:0:2})) -v g=$((16#${hex:2:2})) -v b=$((16#${hex:4:2})) \
      -v scale="$G560_LED_BRIGHTNESS" -v floor="$G560_LED_FLOOR" '
    function lin(v) { v /= 255; return (v <= 0.04045) ? v / 12.92 : ((v + 0.055) / 1.055) ^ 2.4 }
    BEGIN {
      s = 255 * scale / 100
      r = lin(r) * s; g = lin(g) * s; b = lin(b) * s
      m = r; if (g > m) m = g; if (b > m) m = b
      if (m == 0) { print "000000"; exit }
      k = (m < floor) ? floor / m : 1
      printf "%02x%02x%02x\n", int(r * k + 0.5), int(g * k + 0.5), int(b * k + 0.5)
    }
  '
}

# Derive the LED colour from a palette and store it for g560-lighting.
#   g560_write_theme_colour <palette.css> <destination>
g560_write_theme_colour() {
  local palette_file="$1" destination="$2" accent led temporary

  g560_theme_error=""
  if [[ ! -f "$palette_file" ]]; then
    g560_theme_error="palette not found: $palette_file"
    return 1
  fi
  accent=$(css_var "$palette_file" accent) || true
  if [[ -z "$accent" ]] || ! led=$(g560_led_colour "$accent"); then
    g560_theme_error="palette has no solid accent colour"
    return 1
  fi

  mkdir -p -- "${destination%/*}" || {
    g560_theme_error="cannot create ${destination%/*}"
    return 1
  }
  temporary=$(mktemp "$destination.XXXXXX") || {
    g560_theme_error="cannot create temporary colour file"
    return 1
  }
  if ! printf '%s\n' "$led" >"$temporary" || ! mv -f -- "$temporary" "$destination"; then
    rm -f -- "$temporary"
    g560_theme_error="cannot write $destination"
    return 1
  fi
}
