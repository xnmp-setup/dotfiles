#!/usr/bin/env bash
# Contract tests for lib/lig-theme.sh and dot_config/zsh/lig-theme.zsh: every
# generated colour meets its contrast target on light and dark themes, a theme
# without selection colours falls back sensibly, bad input fails without
# touching an existing file, and the assembled config parses in lig.

set -euo pipefail

test_root=$(mktemp -d "${TMPDIR:-/tmp}/lig-theme.XXXXXX")
cleanup() {
  [[ "$test_root" == */lig-theme.* ]] && rm -rf -- "$test_root"
}
trap cleanup EXIT

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(dirname -- "$script_dir")
# shellcheck source=lib/lig-theme.sh
source "$script_dir/lib/lig-theme.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Independent WCAG oracle (same as starship-theme.test.sh).
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
value() { sed -n "s/^$2 = \"\\(.*\\)\"$/\\1/p" "$1"; }
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }

# assert_ratio <file> <key> <against-hex> <min> <label>
assert_ratio() {
  local v ratio
  v=$(value "$1" "$2")
  [[ "$v" =~ ^#[0-9a-f]{6}$ ]] || fail "$5: $2 is '$v', not #rrggbb"
  ratio=$(contrast "$v" "$3")
  ge "$ratio" "$4" || fail "$5: $2 $v vs $3 is $ratio:1, want $4"
}

check_colors() {
  local file="$1" bg="$2" name="$3" key selbg
  grep -qx '\[colors\]' "$file" || fail "$name: no [colors] table"
  for key in bg fg border_bg; do
    [[ "$(value "$file" $key)" == default ]] || fail "$name: $key is not default"
  done
  selbg=$(value "$file" selected_bg)
  assert_ratio "$file" selected_fg "$selbg" 4.5 "$name"
  assert_ratio "$file" selected_description_fg "$selbg" 4.5 "$name"
  assert_ratio "$file" match_fg "$bg" 4.5 "$name"
  assert_ratio "$file" description_fg "$bg" 4.5 "$name"
  assert_ratio "$file" info_fg "$bg" 4.5 "$name"
  assert_ratio "$file" border_fg "$bg" 3 "$name"
  assert_ratio "$file" scrollbar_thumb "$bg" 3 "$name"
  assert_ratio "$file" selected_bg "$bg" 1.1 "$name"
}

# --- every shipped Ghostty theme ---
count=0
for theme in "$repo_root"/dot_config/ghostty/themes/*; do
  [[ -f "$theme" && "$theme" != *.css ]] || continue
  bg=$(sed -n 's/^background *= *#\{0,1\}\([0-9A-Fa-f]\{6\}\).*/\1/p' "$theme" | tr 'A-F' 'a-f')
  [[ -n "$bg" ]] || continue
  out="$test_root/$count.toml"
  lig_generate_colors "$theme" "$out" || fail "${theme##*/}: $lig_theme_error"
  check_colors "$out" "#$bg" "${theme##*/}"
  count=$((count + 1))
done
(( count >= 10 )) || fail "expected the repo's Ghostty themes, found $count"

# --- a light theme uses its own selection colour ---
lig_generate_colors "$repo_root/dot_config/ghostty/themes/Ayu Light" "$test_root/light.toml"
[[ "$(value "$test_root/light.toml" selected_bg)" == "#c4d7f2" ]] || fail "Ayu Light: selection-background not used"

# --- no selection keys, no blue: fall back to foreground-derived colours ---
cat >"$test_root/bare" <<'EOF'
background = #ffffff
foreground = #222222
EOF
lig_generate_colors "$test_root/bare" "$test_root/bare.toml" || fail "bare theme: $lig_theme_error"
check_colors "$test_root/bare.toml" "#ffffff" bare
cat >"$test_root/bare-dark" <<'EOF'
background=101010
foreground=EEEEEE
selection-background = not-a-colour
EOF
lig_generate_colors "$test_root/bare-dark" "$test_root/bare-dark.toml" || fail "bare dark theme: $lig_theme_error"
check_colors "$test_root/bare-dark.toml" "#101010" bare-dark

# --- a selection colour too close to the background is replaced ---
printf 'background = #ffffff\nforeground = #222222\nselection-background = #fefefe\nselection-foreground = #222222\n' >"$test_root/faint"
lig_generate_colors "$test_root/faint" "$test_root/faint.toml" || fail "faint theme: $lig_theme_error"
check_colors "$test_root/faint.toml" "#ffffff" faint

# --- failures leave an existing file untouched ---
existing="$test_root/existing.toml"
echo sentinel >"$existing"
if lig_generate_colors "$test_root/missing" "$existing"; then fail "missing theme file accepted"; fi
[[ -n "$lig_theme_error" ]] || fail "missing theme: no error message"
: >"$test_root/empty"
if lig_generate_colors "$test_root/empty" "$existing"; then fail "empty theme file accepted"; fi
printf 'background = nope\nforeground = #eeeeee\n' >"$test_root/garbage"
if lig_generate_colors "$test_root/garbage" "$existing"; then fail "malformed background accepted"; fi
[[ "$(cat "$existing")" == sentinel ]] || fail "a failed run overwrote the existing file"
[[ -z "$(find "$test_root" -name '.colors.*')" ]] || fail "temporary file left behind"

# --- the zsh splice: assembly, freshness and fallback ---
if command -v zsh >/dev/null 2>&1; then
  home="$test_root/home"
  mkdir -p "$home/lig"
  cp "$repo_root/dot_config/lig/base.toml" "$home/lig/base.toml"
  splice() { XDG_CONFIG_HOME="$home" zsh -fc "source '$repo_root/dot_config/zsh/lig-theme.zsh'"; }
  config="$home/lig/config.toml"

  splice
  [[ -f "$config" ]] || fail "splice: no config without colors"
  grep -q '^\[behavior\]' "$config" && ! grep -q '^\[colors\]' "$config" || fail "splice: expected base only"

  sleep 1
  lig_generate_colors "$repo_root/dot_config/ghostty/themes/Ayu Light" "$home/lig/colors.toml"
  splice
  grep -q '^\[colors\]' "$config" && grep -q '^\[behavior\]' "$config" || fail "splice: colors not added"

  if command -v lig >/dev/null 2>&1; then
    doctor=$(XDG_CONFIG_HOME="$home" lig doctor 2>&1 || true)
    grep -q '\[ok  \] config' <<<"$doctor" || fail "lig doctor does not accept the assembled config: $doctor"
  fi

  rm -- "$home/lig/colors.toml"
  splice
  ! grep -q '^\[colors\]' "$config" || fail "splice: stale colors kept after colors.toml removed"

  # Options newer than the installed lig are dropped (it would reject the whole
  # file); switching to a lig that knows them rebuilds the config with them.
  # Fake ligs stand in for old and new releases: only `lig config` is used.
  mkdir -p "$test_root/old" "$test_root/new"
  printf '#!/bin/sh\nprintf "[behavior]\\nenter_accepts = \\"auto\\"\\n"\n' >"$test_root/old/lig"
  printf '#!/bin/sh\nprintf "[behavior]\\nenter_accepts = \\"auto\\"\\nenter_runs_commands = []\\n"\n' >"$test_root/new/lig"
  chmod +x "$test_root/old/lig" "$test_root/new/lig"
  splice_with() { _lig_bin="$1" XDG_CONFIG_HOME="$home" zsh -fc "source '$repo_root/dot_config/zsh/lig-theme.zsh'"; }
  grep -q '^enter_runs_commands' "$home/lig/base.toml" || fail "base.toml no longer sets enter_runs_commands; update this test"
  splice_with "$test_root/old/lig"
  ! grep -q '^enter_runs_commands' "$config" || fail "splice: kept an option the installed lig rejects"
  grep -q '^\[behavior\]' "$config" || fail "splice: dropped more than the unknown option"
  splice_with "$test_root/new/lig"
  grep -q '^enter_runs_commands' "$config" || fail "splice: new lig binary did not rebuild with its options"
  before=$(cksum <"$config")
  splice_with "$test_root/new/lig"
  [[ "$(cksum <"$config")" == "$before" ]] || fail "splice: rebuilt a fresh config"

  # Without base.toml nothing is written.
  rm -f -- "$config" "$home/lig/base.toml"
  splice
  [[ ! -e "$config" ]] || fail "splice: wrote a config without base.toml"
fi

echo "ok: lig-theme ($count themes)"
