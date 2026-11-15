#!/usr/bin/env bash

set -euo pipefail

test_root=$(mktemp -d "${TMPDIR:-/tmp}/g560-theme.XXXXXX")
cleanup() {
  [[ "$test_root" == */g560-theme.* ]] && rm -rf -- "$test_root"
}
trap cleanup EXIT

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/theme-colors.sh
source "$script_dir/lib/theme-colors.sh"
# shellcheck source=lib/g560-theme.sh
source "$script_dir/lib/g560-theme.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_led() {
  local got
  got=$(g560_led_colour "$1") || fail "g560_led_colour $1 failed"
  [[ "$got" == "$2" ]] || fail "g560_led_colour $1: got $got, want $2"
}

# Primaries and white keep their hue at G560_LED_BRIGHTNESS (60%); black
# stays off.
expect_led ff0000 990000
expect_led "#ffffff" 999999
expect_led 000000 000000
# Shorthand hex is accepted.
expect_led "#f00" 990000
# A muted accent keeps its depth: ethereal's #7d82d9 is a dark indigo on the
# LEDs, not a full-brightness blue.
expect_led 7d82d9 1f226a
# Gamma never brightens: every channel is at most its input value.
for c in 88c0d0 da7a6f a7c080 e95678 7aa2f7; do
  led=$(g560_led_colour "$c")
  for i in 0 2 4; do
    (( 16#${led:i:2} <= 16#${c:i:2} )) || fail "$c -> $led brightened a channel"
  done
done
# A pastel keeps its dominant channel dominant rather than washing to white.
led=$(g560_led_colour 88c0d0)
(( 16#${led:4:2} >= 2 * 16#${led:0:2} )) || fail "pastel blue washed out: $led"
# Near-black is lifted to the floor with its hue kept, so the LEDs stay lit.
expect_led 800000 300000
expect_led 808080 303030
led=$(g560_led_colour 465353)
[[ "${led:2:2}" == 30 && "${led:4:2}" == 30 ]] || fail "dark grey-teal not lifted to floor: $led"
(( 16#${led:0:2} < 0x30 )) || fail "dark grey-teal lost its hue: $led"
# Malformed input is rejected, not turned into a colour.
for bad in "" zzzzzz 12345 "#12"; do
  if g560_led_colour "$bad" >/dev/null 2>&1; then
    fail "accepted malformed colour '$bad'"
  fi
done

palette="$test_root/palette.css"
cat >"$palette" <<'CSS'
:root {
  --background-solid: #292e39;
  --accent: #ff0000;
  --accent-light: #ff8080;
}
CSS

# The stored colour is the LED form of the accent (not accent-light), in a
# fresh directory, with no temporary file left behind.
target="$test_root/state/g560-lighting/colour"
g560_write_theme_colour "$palette" "$target" || fail "write failed: $g560_theme_error"
[[ $(cat "$target") == 990000 ]] || fail "stored colour: $(cat "$target")"
[[ $(find "$test_root/state/g560-lighting" -type f | wc -l) -eq 1 ]] \
  || fail "temporary file left behind"

# Failures name the problem and leave the previous colour in place.
if g560_write_theme_colour "$test_root/missing.css" "$target"; then
  fail "missing palette accepted"
fi
[[ "$g560_theme_error" == "palette not found:"* ]] || fail "error: $g560_theme_error"
sed '/--accent:/d' "$palette" >"$test_root/no-accent.css"
if g560_write_theme_colour "$test_root/no-accent.css" "$target"; then
  fail "palette without accent accepted"
fi
[[ "$g560_theme_error" == *"accent"* ]] || fail "error: $g560_theme_error"
[[ $(cat "$target") == 990000 ]] || fail "failed write clobbered stored colour"

# Default location follows XDG_STATE_HOME.
[[ $(XDG_STATE_HOME=/x g560_colour_file) == /x/g560-lighting/colour ]] \
  || fail "colour file ignores XDG_STATE_HOME"

echo "PASS g560-theme"
