# Colour helpers shared by the generators in set-theme.sh.
#
# Every app that cannot be handed a theme *file* has to be handed a palette
# instead, and the palette always comes from the same place: the tauri-explorer
# stylesheet for the theme. Only the vars that are reliably a solid hex across
# every theme are read from it — background-solid, accent, accent-light,
# text-primary, text-secondary — and everything else is mixed from those.
#
# Mixing rather than hardcoding is what keeps light themes working: "a shade
# lifted off the background" has to darken on a light theme and lighten on a
# dark one, and a fixed colour cannot do both.

# Extract a hex colour for a CSS custom property from a stylesheet.
#   css_var <file> <var-name-without-dashes>
css_var() {
  grep -oP -- "--$2:\s*\K#[0-9a-fA-F]{3,8}" "$1" 2>/dev/null | head -1
}

# Expand #abc to aabbcc so the mixer always has six digits to work with.
# Accepts a leading '#' or not; never prints one.
norm_hex() {
  local h="${1#\#}"
  if (( ${#h} == 3 )); then
    h="${h:0:1}${h:0:1}${h:1:1}${h:1:1}${h:2:1}${h:2:1}"
  fi
  echo "${h:0:6}"
}

# mix <hex-a> <hex-b> <percent-of-b> -> hex
mix() {
  local a b t
  a=$(norm_hex "$1"); b=$(norm_hex "$2"); t="$3"
  printf '%02x%02x%02x' \
    $(( 16#${a:0:2} + (16#${b:0:2} - 16#${a:0:2}) * t / 100 )) \
    $(( 16#${a:2:2} + (16#${b:2:2} - 16#${a:2:2}) * t / 100 )) \
    $(( 16#${a:4:2} + (16#${b:4:2} - 16#${a:4:2}) * t / 100 ))
}

# Of two candidate foregrounds, the one that reads better on a given
# background — WCAG relative luminance, so the choice is measured rather than
# assumed.
#   pick_readable <background> <candidate-a> <candidate-b>
#
# A filled accent button is the case this exists for: the label cannot simply
# be "the page colour", because on a light theme the accent is often mid-toned
# and the page is near-white, and the pair that works on a dark theme inverts
# into the pair that does not.
pick_readable() {
  local bg a b
  bg=$(norm_hex "$1"); a=$(norm_hex "$2"); b=$(norm_hex "$3")
  awk -v bg="$bg" -v a="$a" -v b="$b" '
    function chan(v) { v = v / 255; return (v <= 0.03928) ? v / 12.92 : ((v + 0.055) / 1.055) ^ 2.4 }
    function lum(h) {
      return 0.2126 * chan(strtonum("0x" substr(h, 1, 2))) \
           + 0.7152 * chan(strtonum("0x" substr(h, 3, 2))) \
           + 0.0722 * chan(strtonum("0x" substr(h, 5, 2)))
    }
    function ratio(x, y,   l1, l2, t) {
      l1 = lum(x); l2 = lum(y)
      if (l1 < l2) { t = l1; l1 = l2; l2 = t }
      return (l1 + 0.05) / (l2 + 0.05)
    }
    BEGIN { print (ratio(bg, a) >= ratio(bg, b)) ? a : b }
  '
}

# Decimal "r, g, b" for a hex colour, for consumers whose colour syntax needs
# components rather than a hex literal — CSS rgba(), mainly, which is the only
# way to get a translucent surface out of a palette of opaque hexes.
rgb_triplet() {
  local h
  h=$(norm_hex "$1")
  printf '%d, %d, %d' "$((16#${h:0:2}))" "$((16#${h:2:2}))" "$((16#${h:4:2}))"
}
