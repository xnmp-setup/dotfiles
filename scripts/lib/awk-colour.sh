# Colour arithmetic shared by the theme generators that read Ghostty theme
# files (starship-theme.sh, lig-theme.sh), as awk source in
# $awk_colour_functions. Prepend it to an awk program:
#   awk -v mode=... "$awk_colour_functions"'  ...program...' file
# Plain POSIX awk (no gawk strtonum) so it runs on macOS as well.
#
# Colours are 6-digit lowercase hex without '#'. Functions: norm(v) cleans a
# theme value ("" if invalid), mix(a, b, p) with p the share of a,
# ratio(x, y) is the WCAG contrast ratio, legible(text, block) and
# legible_to(text, block, min) move text toward black or white until it reads.

# shellcheck disable=SC2034  # consumed by the generators that source this
awk_colour_functions='
    function hexdigit(c) { return index("0123456789abcdef", tolower(c)) - 1 }
    function chan(h, i) { return hexdigit(substr(h, i, 1)) * 16 + hexdigit(substr(h, i + 1, 1)) }
    function norm(v) {
      sub(/^#/, "", v)
      if (v !~ /^[0-9A-Fa-f]+$/) return ""
      if (length(v) == 3) v = substr(v,1,1) substr(v,1,1) substr(v,2,1) substr(v,2,1) substr(v,3,1) substr(v,3,1)
      return (length(v) == 6) ? tolower(v) : ""
    }
    function hex(r, g, b) { return sprintf("%02x%02x%02x", int(r + 0.5), int(g + 0.5), int(b + 0.5)) }
    # mix(a, b, p): p is the share of a.
    function mix(a, b, p) {
      return hex(chan(a,1) * p + chan(b,1) * (1 - p), chan(a,3) * p + chan(b,3) * (1 - p), chan(a,5) * p + chan(b,5) * (1 - p))
    }
    function lin(v) { v = v / 255; return (v <= 0.03928) ? v / 12.92 : ((v + 0.055) / 1.055) ^ 2.4 }
    function lum(h) { return 0.2126 * lin(chan(h,1)) + 0.7152 * lin(chan(h,3)) + 0.0722 * lin(chan(h,5)) }
    function ratio(x, y,   a, b, t) {
      a = lum(x); b = lum(y)
      if (a < b) { t = a; a = b; b = t }
      return (a + 0.05) / (b + 0.05)
    }
    # Text on a block, moved toward black or white until it reads at min:1.
    function extreme(block) { return (ratio("000000", block) >= ratio("ffffff", block)) ? "000000" : "ffffff" }
    function legible_to(text, block, min,   end, p, t) {
      if (ratio(text, block) >= min) return text
      end = extreme(block)
      for (p = 0.95; p > 0; p -= 0.05) {
        t = mix(text, end, p)
        if (ratio(t, block) >= min) return t
      }
      return end
    }
    function legible(text, block) { return legible_to(text, block, 4.5) }
'
