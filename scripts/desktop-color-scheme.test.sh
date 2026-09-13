#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Keep all fixtures inside the repo, including fake HOME and desktop commands.
test_root=$(mktemp -d "$script_dir/.desktop-color-scheme-test.XXXXXX")
cleanup() {
  [[ "$test_root" == "$script_dir"/.desktop-color-scheme-test.* ]] && rm -rf -- "$test_root"
}
trap cleanup EXIT

# shellcheck source=lib/desktop-color-scheme.sh
source "$script_dir/lib/desktop-color-scheme.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_equal() {
  [[ "$1" == "$2" ]] || fail "expected <$1>, got <$2>"
}

assert_equal Adwaita "$(desktop_color_scheme_gtk_theme_name Adwaita-dark light)"
assert_equal Adwaita "$(desktop_color_scheme_gtk_theme_name Adwaita-Dark light)"
assert_equal Adwaita-dark "$(desktop_color_scheme_gtk_theme_name Adwaita dark)"
assert_equal Nordic "$(desktop_color_scheme_gtk_theme_name Nordic dark)"
assert_equal Nordic "$(desktop_color_scheme_gtk_theme_name Nordic-Dark light)"
assert_equal Adwaita-dark "$(desktop_color_scheme_gtk_theme_name Adwaita-dark dark)"
assert_equal Nordic-dark "$(desktop_color_scheme_gtk_theme_name Nordic-dark-Dark light)"
assert_equal '' "$(desktop_color_scheme_gtk_theme_name '' light)"
assert_equal '' "$(desktop_color_scheme_gtk_theme_name '' dark)"
echo 'PASS: GTK theme-name mapping'

ini="$test_root/settings.ini"
cat > "$ini" <<'EOF'
# keep the preamble
[Other]
gtk-theme-name=Other-dark
gtk-application-prefer-dark-theme=true
[Settings]
# keep this comment
gtk-theme-name=Adwaita-dark
gtk-application-prefer-dark-theme=true
gtk-font-name=Sans 11
[Last]
unrelated=value
EOF
desktop_color_scheme_update_gtk_ini "$ini" light
cat > "$test_root/expected.ini" <<'EOF'
# keep the preamble
[Other]
gtk-theme-name=Other-dark
gtk-application-prefer-dark-theme=true
[Settings]
# keep this comment
gtk-theme-name=Adwaita
gtk-application-prefer-dark-theme=false
gtk-font-name=Sans 11
[Last]
unrelated=value
EOF
cmp "$test_root/expected.ini" "$ini" || fail 'light rewrite changed unrelated lines'
desktop_color_scheme_update_gtk_ini "$ini" dark
assert_equal 1 "$(grep -c '^gtk-theme-name=Adwaita-dark$' "$ini")"
assert_equal 2 "$(grep -c '^gtk-application-prefer-dark-theme=true$' "$ini")"
cp "$ini" "$test_root/expected.ini"
desktop_color_scheme_update_gtk_ini "$ini" dark
cmp "$test_root/expected.ini" "$ini" || fail 'dark rewrite is not idempotent'

for mode in light dark; do
  preference=false
  [[ "$mode" != dark ]] || preference=true
  printf '[Settings]\ngtk-theme-name=Nordic\n# retained\n[Other]\nx=1\n' > "$ini"
  desktop_color_scheme_update_gtk_ini "$ini" "$mode"
  printf '[Settings]\ngtk-theme-name=Nordic\n# retained\ngtk-application-prefer-dark-theme=%s\n[Other]\nx=1\n' \
    "$preference" > "$test_root/expected.ini"
  cmp "$test_root/expected.ini" "$ini" || fail "$mode: missing preference before next section"

  printf '# headerless\ngtk-theme-name=Unscoped-dark\n[Other]\nx=1\n' > "$ini"
  desktop_color_scheme_update_gtk_ini "$ini" "$mode"
  printf '# headerless\ngtk-theme-name=Unscoped-dark\n[Other]\nx=1\n[Settings]\ngtk-application-prefer-dark-theme=%s\n' \
    "$preference" > "$test_root/expected.ini"
  cmp "$test_root/expected.ini" "$ini" || fail "$mode: missing Settings section"

  printf '[Settings]\n# empty settings\n' > "$ini"
  desktop_color_scheme_update_gtk_ini "$ini" "$mode"
  printf '[Settings]\n# empty settings\ngtk-application-prefer-dark-theme=%s\n' \
    "$preference" > "$test_root/expected.ini"
  cmp "$test_root/expected.ini" "$ini" || fail "$mode: missing preference at EOF"

  : > "$ini"
  desktop_color_scheme_update_gtk_ini "$ini" "$mode"
  assert_equal "$(printf '[Settings]\ngtk-application-prefer-dark-theme=%s' "$preference")" "$(cat "$ini")"
  desktop_color_scheme_update_gtk_ini "$test_root/missing.ini" "$mode"
  [[ ! -e "$test_root/missing.ini" ]] || fail 'missing file was created'
done
printf ' [Settings] \n  gtk-theme-name = Adwaita-Dark  \n  gtk-application-prefer-dark-theme = true\n' > "$ini"
desktop_color_scheme_update_gtk_ini "$ini" light
assert_equal "$(printf ' [Settings] \n  gtk-theme-name = Adwaita  \n  gtk-application-prefer-dark-theme = false')" "$(cat "$ini")"
echo 'PASS: GTK INI light/dark updates, preservation, missing files, and idempotence'

mkdir -p "$test_root/bin" "$test_root/gsettings-bin" "$test_root/home"
for utility in bash cp mv rm mktemp; do
  ln -s "$(command -v "$utility")" "$test_root/bin/$utility"
done
cat > "$test_root/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Linux\n'
EOF
cat > "$test_root/gsettings-bin/gsettings" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GSETTINGS_LOG"
[[ "${GSETTINGS_FAIL:-}" != "$1:${3:-}" ]] || exit 1
case "$1" in
  writable) printf '%s\n' "${GSETTINGS_WRITABLE:-true}" ;;
  get) printf "'%s'\n" "${GSETTINGS_THEME:-Adwaita-dark}" ;;
  set) ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$test_root/bin/uname" "$test_root/gsettings-bin/gsettings"
export HOME="$test_root/home"
export XDG_CONFIG_HOME="$test_root/config"
export GSETTINGS_LOG="$test_root/gsettings.log"
unset GSETTINGS_FAIL GSETTINGS_WRITABLE GSETTINGS_THEME

(
  export PATH="$test_root/gsettings-bin:$test_root/bin"
  desktop_color_scheme_apply light || fail 'gsettings light failed'
  assert_equal '' "$desktop_color_scheme_error"
  assert_equal 'gsettings color-scheme=prefer-light' "${desktop_color_scheme_applied[*]}"
)
cat > "$test_root/expected.log" <<'EOF'
writable org.gnome.desktop.interface color-scheme
get org.gnome.desktop.interface gtk-theme
set org.gnome.desktop.interface color-scheme prefer-light
set org.gnome.desktop.interface gtk-theme Adwaita
EOF
cmp "$test_root/expected.log" "$GSETTINGS_LOG" || fail 'incorrect light gsettings calls'
: > "$GSETTINGS_LOG"
(
  export PATH="$test_root/gsettings-bin:$test_root/bin" GSETTINGS_THEME=Adwaita
  desktop_color_scheme_apply dark || fail 'gsettings dark failed'
)
grep -Fxq 'set org.gnome.desktop.interface color-scheme prefer-dark' "$GSETTINGS_LOG" || fail 'dark scheme not set'
grep -Fxq 'set org.gnome.desktop.interface gtk-theme Adwaita-dark' "$GSETTINGS_LOG" || fail 'dark GTK theme not set'
: > "$GSETTINGS_LOG"
(
  export PATH="$test_root/gsettings-bin:$test_root/bin" GSETTINGS_THEME=Nordic
  desktop_color_scheme_apply dark || fail 'unchanged theme failed'
)
if grep -q '^set .* gtk-theme ' "$GSETTINGS_LOG"; then fail 'unchanged GTK theme was written'; fi

: > "$GSETTINGS_LOG"
(
  export PATH="$test_root/gsettings-bin:$test_root/bin" GSETTINGS_WRITABLE=false
  if desktop_color_scheme_apply light; then fail 'non-writable gsettings succeeded'; fi
  assert_equal 0 "${#desktop_color_scheme_applied[@]}"
  [[ -n "$desktop_color_scheme_error" ]] || fail 'missing unavailable error'
)
assert_equal 'writable org.gnome.desktop.interface color-scheme' "$(cat "$GSETTINGS_LOG")"
for failed_call in writable:color-scheme get:gtk-theme set:color-scheme set:gtk-theme; do
  (
    export PATH="$test_root/gsettings-bin:$test_root/bin" GSETTINGS_FAIL="$failed_call"
    if desktop_color_scheme_apply light; then fail "$failed_call unexpectedly succeeded"; fi
    assert_equal 0 "${#desktop_color_scheme_applied[@]}"
  )
done
echo 'PASS: gsettings set calls, unchanged themes, non-writable schema, and failures'

(
  export PATH="$test_root/bin"
  desktop_color_scheme_applied=('stale result')
  if desktop_color_scheme_apply dark; then
    fail 'empty environment unexpectedly succeeded'
  else
    assert_equal 1 "$?"
  fi
  assert_equal 0 "${#desktop_color_scheme_applied[@]}"
  [[ "$desktop_color_scheme_error" == *'nothing was available'* ]] || fail 'missing unavailable error'
)
mkdir -p "$XDG_CONFIG_HOME/gtk-3.0" "$XDG_CONFIG_HOME/gtk-4.0"
printf '[Settings]\ngtk-theme-name=Adwaita-dark\n' > "$XDG_CONFIG_HOME/gtk-3.0/settings.ini"
printf '[Settings]\ngtk-theme-name=Nordic\n' > "$XDG_CONFIG_HOME/gtk-4.0/settings.ini"
(
  export PATH="$test_root/gsettings-bin:$test_root/bin" GSETTINGS_WRITABLE=false
  desktop_color_scheme_apply light || fail 'GTK fallback failed'
  assert_equal 2 "${#desktop_color_scheme_applied[@]}"
  assert_equal '' "$desktop_color_scheme_error"
)
grep -Fxq 'gtk-theme-name=Adwaita' "$XDG_CONFIG_HOME/gtk-3.0/settings.ini" || fail 'GTK3 theme not updated'
for version in 3 4; do
  grep -Fxq 'gtk-application-prefer-dark-theme=false' "$XDG_CONFIG_HOME/gtk-$version.0/settings.ini" || fail "GTK$version preference not updated"
done
(
  unset XDG_CONFIG_HOME
  export PATH="$test_root/bin"
  if desktop_color_scheme_apply light; then fail 'missing default GTK files counted as applied'; fi
)
echo 'PASS: unavailable backends and independent GTK fallbacks'
echo 'desktop-color-scheme tests passed'
