#!/usr/bin/env bash
# Contract tests for lib/claude-theme.sh: every generated theme is a valid
# Claude Code custom theme whose user-message background stands out from the
# terminal background while Claude's text still reads on it, and bad input
# fails without touching an existing theme.

set -euo pipefail

test_root=$(mktemp -d "${TMPDIR:-/tmp}/claude-theme.XXXXXX")
cleanup() {
  [[ "$test_root" == */claude-theme.* ]] && rm -rf -- "$test_root"
}
trap cleanup EXIT

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(dirname -- "$script_dir")
# shellcheck source=lib/claude-theme.sh
source "$script_dir/lib/claude-theme.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Independent oracle: parse the theme as JSON and check it against Claude
# Code's custom-theme contract and the contrast floors. Prints nothing on
# success, the reason on failure.
check_theme() {
  python3 -I - "$@" <<'EOF'
import json, re, sys

path, mode, bg, name = sys.argv[1:5]

def lum(h):
    h = h.lstrip("#"); out = 0
    for w, i in ((0.2126, 0), (0.7152, 2), (0.0722, 4)):
        v = int(h[i:i+2], 16) / 255
        out += w * (v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4)
    return out

def ratio(a, b):
    a, b = lum(a), lum(b)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)

try:
    theme = json.load(open(path))
except Exception as e:
    sys.exit(f"not JSON: {e}")
if set(theme) != {"name", "base", "overrides"}:
    sys.exit(f"unexpected keys {sorted(theme)}")
if theme["name"] != name:
    sys.exit(f"name {theme['name']!r} != {name!r}")
if theme["base"] != mode:
    sys.exit(f"base {theme['base']!r} != {mode!r}")
o = theme["overrides"]
block, hover = o.get("userMessageBackground"), o.get("userMessageBackgroundHover")
for k, v in (("userMessageBackground", block), ("userMessageBackgroundHover", hover)):
    if not isinstance(v, str) or not re.fullmatch(r"#[0-9a-f]{6}", v):
        sys.exit(f"{k} is {v!r}, not #rrggbb")

# Stands out from the terminal background, by a step visible in either mode.
floor = 1.6 if mode == "dark" else 1.15
if ratio(block, bg) < floor:
    sys.exit(f"{block} on {bg}: {ratio(block, bg):.2f} < {floor}")
if ratio(hover, bg) < ratio(block, bg):
    sys.exit(f"hover {hover} stands out less than {block}")
# Claude's own message text (white on dark, black on light) still reads.
text = "#ffffff" if mode == "dark" else "#000000"
for c in (block, hover):
    if ratio(text, c) < 7:
        sys.exit(f"{text} on {c}: {ratio(text, c):.2f} < 7")
EOF
}

mode_of() {
  python3 -I -c '
import sys
h = sys.argv[1]; out = 0
for w, i in ((0.2126, 0), (0.7152, 2), (0.0722, 4)):
    v = int(h[i:i+2], 16) / 255
    out += w * (v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4)
print("light" if out > 0.4 else "dark")
' "$1"
}

expect_ok() {
  local reason
  reason=$(check_theme "$@" 2>&1) || fail "$4: $reason"
}

# --- every shipped Ghostty theme ---
count=0
for theme in "$repo_root"/dot_config/ghostty/themes/*; do
  [[ -f "$theme" && "$theme" != *.css ]] || continue
  bg=$(sed -n 's/^background *= *#\{0,1\}\([0-9A-Fa-f]\{6\}\).*/\1/p' "$theme" | tr 'A-F' 'a-f')
  [[ -n "$bg" ]] || continue
  mode=$(mode_of "$bg")
  out="$test_root/$count.json"
  name="Desktop (${theme##*/})"
  claude_generate_theme "$theme" "$mode" "$name" "$out" || fail "${theme##*/}: $claude_theme_error"
  expect_ok "$out" "$mode" "#$bg" "$name"
  count=$((count + 1))
done
(( count >= 10 )) || fail "expected the repo's Ghostty themes, found $count"

# --- the block keeps the theme's tint: Kanagawa's inks are blue-violet ---
claude_generate_theme "$repo_root/dot_config/ghostty/themes/Kanagawa" dark K "$test_root/k.json"
block=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["overrides"]["userMessageBackground"])' "$test_root/k.json")
(( 16#${block:5:2} > 16#${block:1:2} )) || fail "Kanagawa: $block lost the theme's blue tint"

# --- no bright black, or one that is just another background ---
printf 'background = #101010\nforeground = #eeeeee\n' >"$test_root/bare-dark"
claude_generate_theme "$test_root/bare-dark" dark bare "$test_root/bare-dark.json" || fail "bare dark: $claude_theme_error"
expect_ok "$test_root/bare-dark.json" dark "#101010" bare
printf 'background=ffffff\nforeground=222222\npalette = 8=#fefefe\n' >"$test_root/flat-light"
claude_generate_theme "$test_root/flat-light" light flat "$test_root/flat-light.json" || fail "flat light: $claude_theme_error"
expect_ok "$test_root/flat-light.json" light "#ffffff" flat
printf 'background = #0b0c16\nforeground = #dddddd\npalette = 8=#14182a\n' >"$test_root/near"
claude_generate_theme "$test_root/near" dark near "$test_root/near.json" || fail "near-background bright black: $claude_theme_error"
expect_ok "$test_root/near.json" dark "#0b0c16" near

# --- a name that needs escaping stays valid JSON ---
weird='Say "hi" \ bye'
claude_generate_theme "$test_root/bare-dark" dark "$weird" "$test_root/weird.json"
expect_ok "$test_root/weird.json" dark "#101010" "$weird"

# --- the plain fallback theme ---
claude_write_plain_theme light "Desktop (X)" "$test_root/plain.json" || fail "plain: $claude_theme_error"
python3 -I -c '
import json, sys
t = json.load(open(sys.argv[1]))
assert t == {"name": "Desktop (X)", "base": "light", "overrides": {}}, t
' "$test_root/plain.json" || fail "plain theme is not the bare light base"

# --- the shipped chezmoi fallback is a valid theme too ---
python3 -I -c '
import json, sys
t = json.load(open(sys.argv[1]))
assert t["base"] in ("dark", "light") and isinstance(t["overrides"], dict), t
' "$repo_root/dot_claude/themes/create_desktop.json" || fail "create_desktop.json is not a valid theme"

# --- failures leave an existing file untouched ---
existing="$test_root/existing.json"
echo sentinel >"$existing"
if claude_generate_theme "$test_root/missing" dark x "$existing"; then fail "missing theme file accepted"; fi
[[ -n "$claude_theme_error" ]] || fail "missing theme: no error message"
: >"$test_root/empty"
if claude_generate_theme "$test_root/empty" dark x "$existing"; then fail "empty theme file accepted"; fi
printf 'background = nope\nforeground = #eeeeee\n' >"$test_root/garbage"
if claude_generate_theme "$test_root/garbage" dark x "$existing"; then fail "malformed background accepted"; fi
if claude_generate_theme "$test_root/bare-dark" sepia x "$existing"; then fail "unknown mode accepted"; fi
if claude_write_plain_theme sepia x "$existing"; then fail "plain: unknown mode accepted"; fi
[[ "$(cat "$existing")" == sentinel ]] || fail "a failed run overwrote the existing file"
[[ -z "$(find "$test_root" -name '.desktop.*')" ]] || fail "temporary file left behind"

echo "claude-theme: $count themes OK"
