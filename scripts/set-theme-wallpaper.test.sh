#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d /tmp/set-theme-wallpaper.XXXXXX)

# shellcheck source=lib/theme-wallpaper.sh
source "$repo_root/scripts/lib/theme-wallpaper.sh"
# shellcheck source=lib/chrome-theme.sh
source "$repo_root/scripts/lib/chrome-theme.sh"

cleanup() {
  [[ "$test_root" == /tmp/set-theme-wallpaper.* ]] && rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v jq >/dev/null || fail "jq is required"

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || fail "$file does not contain: $expected"
}

# A wallpaper association denotes a complete desktop theme. Keep Chrome in
# lockstep with that registry so adding a wallpaper-backed theme cannot leave
# the browser on the previous theme.
for associated_slug in "${!theme_wallpapers[@]}"; do
  chrome_dir="$repo_root/dot_local/share/chrome-themes/$associated_slug"
  chrome_manifest="$chrome_dir/manifest.json"
  darkreader_preset="$chrome_dir/darkreader-$associated_slug.json"

  [[ -f "$chrome_manifest" ]] \
    || fail "wallpaper-associated theme has no Chrome manifest: $associated_slug"
  [[ -f "$darkreader_preset" ]] \
    || fail "wallpaper-associated theme has no Dark Reader preset: $associated_slug"

  jq -e '
    .manifest_version == 3 and
    (.name | type == "string" and length > 0) and
    (.version | type == "string" and length > 0) and
    ([
      "frame", "frame_inactive", "frame_incognito",
      "frame_incognito_inactive", "toolbar", "background_tab", "tab_text",
      "tab_background_text", "bookmark_text", "ntp_background", "ntp_text",
      "ntp_link", "ntp_header", "omnibox_background", "omnibox_text",
      "toolbar_button_icon", "button_background"
    ] - (.theme.colors | keys) | length == 0)
  ' "$chrome_manifest" >/dev/null \
    || fail "invalid or incomplete Chrome manifest: $associated_slug"

  while IFS= read -r chrome_asset; do
    [[ -f "$chrome_dir/$chrome_asset" ]] \
      || fail "Chrome manifest references a missing asset: $associated_slug/$chrome_asset"
  done < <(jq -r '.theme.images // {} | .[]' "$chrome_manifest")

  jq -e '
    .theme.mode == 1 and
    .theme.engine == "dynamicTheme" and
    ([
      "darkSchemeBackgroundColor", "darkSchemeTextColor",
      "lightSchemeBackgroundColor", "lightSchemeTextColor",
      "scrollbarColor", "selectionColor"
    ] - (.theme | keys) | length == 0)
  ' "$darkreader_preset" >/dev/null \
    || fail "invalid or incomplete Dark Reader preset: $associated_slug"
done

mkdir -p "$test_root/.config/hypr" \
  "$test_root/.config/google-chrome/Default" \
  "$test_root/.local/share/chrome-themes" \
  "$test_root/Pictures/Wallpaper" \
  "$test_root/google-chrome/extensions" \
  "$test_root/bin"
touch "$test_root/Pictures/Wallpaper/planet_with_sunrise.png"
touch "$test_root/Pictures/Wallpaper/custom.photo.jpg"
cp -r "$repo_root/dot_local/share/chrome-themes/cosmic-dusk" \
  "$test_root/.local/share/chrome-themes/cosmic-dusk"

cat > "$test_root/.config/hypr/hyprpaper.conf" <<'EOF'
preload = /old/wallpaper.png

wallpaper {
    monitor = DP-1
    path = /old/wallpaper.png
    fit_mode = fill
}

wallpaper {
    monitor = DP-2
    path = /old/wallpaper.png
    fit_mode = fill
}
EOF

cat > "$test_root/.config/hypr/hyprlock.conf" <<'EOF'
background {
    path = /old/lock.png
    blur_passes = 2
}

image {
    path = /must/not/change.png
}
EOF

# Prevent the integration-style test from talking to a running Vicinae. The
# Hyprctl stub both supplies two current monitors and records the wallpaper IPC
# requests so the user-visible live update can be asserted.
cat > "$test_root/bin/vicinae" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$test_root/bin/google-chrome-stable" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  case "$argument" in
    --pack-extension=*)
      staging=${argument#*=}
      printf 'fake crx\n' >"$staging.crx"
      exit 0
      ;;
  esac
done
exit 0
EOF
cat > "$test_root/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
[[ ! -e "$TEST_CHROME_STOPPED" ]] || exit 1
printf '123\n'
EOF
cat > "$test_root/bin/pkill" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_CHROME_RESTART_LOG"
[[ "$*" == *'-TERM -x chrome'* ]] && : >"$TEST_CHROME_STOPPED"
EOF
cat > "$test_root/bin/setsid" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_CHROME_RESTART_LOG"
EOF
cat > "$test_root/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "monitors -j" ]]; then
  printf '[{"name":"DP-1"},{"name":"DP-2"}]\n'
  exit 0
fi
if [[ "$*" == "clients -j" ]]; then
  printf '[]\n'
  exit 0
fi
if [[ "$*" == "activewindow -j" ]]; then
  printf '{}\n'
  exit 0
fi
printf '%s\n' "$*" >> "$TEST_HYPRCTL_LOG"
EOF
chmod +x "$test_root/bin/vicinae" "$test_root/bin/google-chrome-stable" \
  "$test_root/bin/pgrep" "$test_root/bin/pkill" "$test_root/bin/setsid" \
  "$test_root/bin/hyprctl"

chrome_state="$test_root/.local/state/chrome-theme"
mkdir -p "$chrome_state"
openssl genrsa -out "$chrome_state/key.pem" 2048 >/dev/null 2>&1
blocked_chrome_id=$(chrome_theme_extension_id "$chrome_state/key.pem")
jq -n --arg id "$blocked_chrome_id" \
  '{extensions: {external_uninstalls: [$id]}}' \
  >"$test_root/.config/google-chrome/Default/Preferences"

run_set_theme() {
  TEST_HYPRCTL_LOG="$test_root/hyprctl.log" \
    TEST_CHROME_RESTART_LOG="$test_root/chrome-restart.log" \
    TEST_CHROME_STOPPED="$test_root/chrome-stopped" \
    HOME="$test_root" \
    PATH="$test_root/bin:$PATH" \
    HYPRLAND_INSTANCE_SIGNATURE=test \
    SET_THEME_GOOGLE_CHROME_EXTENSION_DIR="$test_root/google-chrome/extensions" \
    bash "$repo_root/scripts/set-theme.sh" "$@"
}

desktop_themes=$(HOME="$test_root" bash "$repo_root/scripts/set-theme.sh" --list-desktop-themes)
grep -Fxq 'Cosmic Dusk' <<<"$desktop_themes" \
  || fail "desktop theme listing omitted its display name"
if grep -q $'\t' <<<"$desktop_themes"; then
  fail "desktop theme listing repeated names as slug metadata"
fi

: >"$test_root/chrome-restart.log"
run_set_theme cosmic-dusk --restart-chrome > "$test_root/default.out"
default_path="$test_root/Pictures/Wallpaper/planet_with_sunrise.png"
theme_state="$test_root/.local/state/desktop-theme/current.json"
[[ -f "$theme_state" ]] || fail "set-theme did not create local theme state"
assert_contains "$theme_state" '"slug": "cosmic-dusk"'
assert_contains "$theme_state" '"title": "Cosmic Dusk"'
assert_contains "$theme_state" '"mode": "dark"'
current_chrome_id=$(chrome_theme_extension_id "$chrome_state/key.pem")
[[ "$current_chrome_id" != "$blocked_chrome_id" ]] \
  || fail "Chrome kept using an externally blocklisted theme identity"
[[ -f "$test_root/google-chrome/extensions/$current_chrome_id.json" ]] \
  || fail "Chrome descriptor was not written for the replacement identity"
[[ ! -e "$test_root/google-chrome/extensions/$blocked_chrome_id.json" ]] \
  || fail "the obsolete Chrome descriptor was not removed"
assert_contains "$test_root/default.out" \
  "Chrome had blocked the previous external theme; reset its install identity"
assert_contains "$test_root/chrome-restart.log" '-TERM -x chrome'
assert_contains "$test_root/chrome-restart.log" \
  "-f $test_root/bin/google-chrome-stable"
[[ $(grep -Fh "path = $default_path" \
  "$test_root/.config/hypr/hyprpaper.conf" \
  "$test_root/.config/hypr/hyprlock.conf" | wc -l) -eq 3 ]] \
  || fail "default wallpaper did not update every wallpaper/background block"
assert_contains "$test_root/.config/hypr/hyprpaper.conf" "preload = $default_path"
assert_contains "$test_root/.config/hypr/hyprlock.conf" "path = /must/not/change.png"
assert_contains "$test_root/hyprctl.log" "hyprpaper wallpaper DP-1, $default_path, fill"
assert_contains "$test_root/hyprctl.log" "hyprpaper wallpaper DP-2, $default_path, fill"

# Unique prefixes resolve only against wallpaper-associated desktop themes.
# In particular, an app-specific theme named "cosmic" must not prevent the
# intended desktop theme from resolving to cosmic-dusk.
run_set_theme cosmic > "$test_root/prefix.out"
assert_contains "$test_root/prefix.out" "Switching all apps to: Cosmic Dusk (cosmic-dusk)"
assert_contains "$test_root/prefix.out" "matched theme prefix: cosmic → cosmic-dusk"
assert_contains "$test_root/.config/hypr/hyprpaper.conf" "path = $default_path"

# Exact associated slugs remain unchanged, the former Everforest alias now
# resolves to the canonical slug, and unrelated names retain pass-through
# behavior.
[[ "$(resolve_theme_slug gruvbox)" == "gruvbox" ]] \
  || fail "an exact associated theme did not remain unchanged"
[[ "$(resolve_theme_slug everforest)" == "everforest-dark-medium" ]] \
  || fail "the Everforest prefix did not resolve to the canonical theme"
[[ "$(resolve_theme_slug unknown-theme)" == "unknown-theme" ]] \
  || fail "a non-associated theme did not pass through unchanged"

cp "$test_root/.config/hypr/hyprpaper.conf" "$test_root/before-ambiguous.conf"
if run_set_theme c > "$test_root/ambiguous.out" 2>&1; then
  fail "an ambiguous theme prefix was accepted"
fi
cmp -s "$test_root/before-ambiguous.conf" "$test_root/.config/hypr/hyprpaper.conf" \
  || fail "an ambiguous theme prefix partially changed the Hyprpaper config"
assert_contains "$test_root/ambiguous.out" \
  "Theme prefix 'c' is ambiguous: catppuccin-mocha, cosmic-dusk"

run_set_theme cosmic-dusk --wallpaper custom.photo > "$test_root/override.out"
override_path="$test_root/Pictures/Wallpaper/custom.photo.jpg"
assert_contains "$test_root/.config/hypr/hyprpaper.conf" "path = $override_path"
assert_contains "$test_root/.config/hypr/hyprlock.conf" "path = $override_path"

cp "$test_root/.config/hypr/hyprpaper.conf" "$test_root/before-invalid.conf"
if run_set_theme cosmic-dusk --wallpaper= > "$test_root/invalid.out" 2>&1; then
  fail "an empty explicit wallpaper was accepted"
fi
cmp -s "$test_root/before-invalid.conf" "$test_root/.config/hypr/hyprpaper.conf" \
  || fail "invalid input partially changed the Hyprpaper config"
assert_contains "$test_root/invalid.out" "Wallpaper cannot be empty"

echo "set-theme wallpaper tests passed"
