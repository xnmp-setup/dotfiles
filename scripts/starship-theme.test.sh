#!/usr/bin/env bash
# Contract tests for lib/starship-theme.sh: every generated text colour reads
# on its block, light themes get pale blocks and dark themes visible ones, and
# bad input fails without touching an existing palette.

set -euo pipefail

test_root=$(mktemp -d "${TMPDIR:-/tmp}/starship-theme.XXXXXX")
cleanup() {
  [[ "$test_root" == */starship-theme.* ]] && rm -rf -- "$test_root"
}
trap cleanup EXIT

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(dirname -- "$script_dir")
# shellcheck source=lib/starship-theme.sh
source "$script_dir/lib/starship-theme.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Independent WCAG oracle: contrast ratio of two #rrggbb colours, and the
# relative luminance of one.
contrast() {
  python3 -I -c '
import sys
def lum(h):
    h = h.lstrip("#"); out = 0
    for w, i in ((0.2126, 0), (0.7152, 2), (0.0722, 4)):
        v = int(h[i:i+2], 16) / 255
        out += w * (v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4)
    return out
a, b = lum(sys.argv[1]), lum(sys.argv[2])
print(f"{(max(a, b) + 0.05) / (min(a, b) + 0.05):.2f}")
' "$1" "$2"
}
luminance() {
  python3 -I -c '
import sys
h = sys.argv[1].lstrip("#"); out = 0
for w, i in ((0.2126, 0), (0.7152, 2), (0.0722, 4)):
    v = int(h[i:i+2], 16) / 255
    out += w * (v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4)
print(f"{out:.4f}")
' "$1"
}
value() { sed -n "s/^$2 = \"\\(#[0-9a-f]\\{6\\}\\)\"$/\\1/p" "$1"; }
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }

roles=(dir branch sync lang err dur)

check_palette() {
  local file="$1" mode="$2" bg="$3" name="$4" role block text ratio
  grep -qx '\[palettes.theme\]' "$file" || fail "$name: no [palettes.theme] table"
  for role in "${roles[@]}"; do
    block=$(value "$file" "${role}_bg"); text=$(value "$file" "${role}_fg")
    [[ -n "$block" && -n "$text" ]] || fail "$name: missing ${role}_bg/${role}_fg"
    ratio=$(contrast "$text" "$block")
    ge "$ratio" 4.5 || fail "$name ($mode): ${role} text $text on $block is $ratio:1"
    if [[ "$mode" == light ]]; then
      ge "$(luminance "$block")" 0.45 || fail "$name: light block ${role}_bg $block is not pale"
    else
      ratio=$(contrast "$block" "$bg")
      ge "$ratio" 1.4 || fail "$name: dark block ${role}_bg $block barely differs from background ($ratio:1)"
    fi
  done
  [[ -n "$(value "$file" char_ok)" && -n "$(value "$file" char_err)" ]] || fail "$name: missing prompt character colours"
}

# --- every shipped Ghostty theme, in the mode its background implies ---
count=0
for theme in "$repo_root"/dot_config/ghostty/themes/*; do
  [[ -f "$theme" && "$theme" != *.css ]] || continue
  bg=$(sed -n 's/^background *= *#\{0,1\}\([0-9A-Fa-f]\{6\}\).*/\1/p' "$theme" | tr 'A-F' 'a-f')
  [[ -n "$bg" ]] || continue
  mode=dark; ge "$(luminance "#$bg")" 0.3 && mode=light
  out="$test_root/$count.toml"
  starship_generate_palette "$theme" "$mode" "$out" || fail "${theme##*/}: $starship_theme_error"
  check_palette "$out" "$mode" "#$bg" "${theme##*/}"
  count=$((count + 1))
done
(( count >= 10 )) || fail "expected the repo's Ghostty themes, found $count"

# --- tolerant parsing: no '#', upper case, 3-digit hex, extra spacing ---
cat >"$test_root/loose" <<'EOF'
background=FFF
foreground =  #222222
palette = 1=#C03030
palette=2 = 2a8a2a
palette = 3=#b08000
palette = 4=#2050a0
palette = 5=#a03080
palette = 6=#208080
EOF
starship_generate_palette "$test_root/loose" light "$test_root/loose.toml" || fail "loose syntax: $starship_theme_error"
check_palette "$test_root/loose.toml" light "#ffffff" loose

# --- failures leave an existing palette untouched ---
existing="$test_root/existing.toml"
echo "sentinel" >"$existing"

printf 'background = #101010\nforeground = #eeeeee\npalette = 1=#ff0000\n' >"$test_root/partial"
if starship_generate_palette "$test_root/partial" dark "$existing"; then fail "partial theme accepted"; fi
[[ -n "$starship_theme_error" ]] || fail "partial theme: no error message"

printf 'background = not-a-colour\nforeground = #eeeeee\n' >"$test_root/garbage"
for i in 1 2 3 4 5 6; do echo "palette = $i=#808080" >>"$test_root/garbage"; done
if starship_generate_palette "$test_root/garbage" dark "$existing"; then fail "malformed background accepted"; fi

if starship_generate_palette "$test_root/missing" dark "$existing"; then fail "missing theme file accepted"; fi
if starship_generate_palette "$repo_root/dot_config/ghostty/themes/Gruvbox" sepia "$existing"; then fail "unknown mode accepted"; fi
: >"$test_root/empty"
if starship_generate_palette "$test_root/empty" light "$existing"; then fail "empty theme file accepted"; fi

[[ "$(cat "$existing")" == sentinel ]] || fail "a failed run overwrote the existing palette"
[[ -z "$(find "$test_root" -name '.palette.*')" ]] || fail "temporary file left behind"

echo "ok: starship-theme ($count themes)"
