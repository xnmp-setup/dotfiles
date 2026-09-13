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
    (.theme.mode == 0 or .theme.mode == 1) and
    .theme.engine == "dynamicTheme" and
    ([
      "darkSchemeBackgroundColor", "darkSchemeTextColor",
      "lightSchemeBackgroundColor", "lightSchemeTextColor",
      "scrollbarColor", "selectionColor"
    ] - (.theme | keys) | length == 0)
  ' "$darkreader_preset" >/dev/null \
    || fail "invalid or incomplete Dark Reader preset: $associated_slug"
done

# Kanagawa keeps its broad browser surfaces in the Sumi Ink ladder. Wave Blue
# is an accent/link color, not a full Chrome frame or inactive-tab surface.
jq -e '
  .theme.colors.frame == [42, 42, 55] and
  .theme.colors.background_tab == [23, 23, 30, 0.95] and
  .theme.colors.omnibox_background == [42, 42, 55] and
  .theme.colors.ntp_header == [42, 42, 55] and
  .theme.colors.button_background == [126, 156, 216]
' "$repo_root/dot_local/share/chrome-themes/kanagawa/manifest.json" >/dev/null \
  || fail "Kanagawa Chrome surfaces/accent mapping drifted"

grep -Fq -- '--background-secondary-alt: #2a2a37;' \
  "$repo_root/Vaults/Technical Vault/dot_obsidian/themes/Kanagawa/theme.css" \
  || fail "Kanagawa Obsidian tab surface is not mapped to Sumi Ink"

# The requested Omarchy themes are complete switch targets, not palette-only
# entries that leave individual applications on the previous theme.
omarchy_themes=(
  kanagawa tokyo-night hackerman ethereal flexoki-light ayu-light osaka-jade artzen
  infernium-dark mapquest sakura sunset
)
for omarchy_slug in "${omarchy_themes[@]}"; do
  omarchy_title=${theme_titles[$omarchy_slug]:-}
  [[ -n "$omarchy_title" ]] \
    || omarchy_title=$(printf '%s' "$omarchy_slug" | tr '-' ' ' | sed 's/\b\(.\)/\u\1/g')
  [[ -f "$repo_root/dot_config/ghostty/themes/$omarchy_title" ]] \
    || fail "Omarchy theme has no Ghostty palette: $omarchy_slug"
  [[ -f "$repo_root/dot_config/ghostty/themes/$omarchy_slug-tabs.css" ]] \
    || fail "Omarchy theme has no Ghostty tab style: $omarchy_slug"
  [[ -f "$repo_root/dot_config/tauri-explorer/themes/$omarchy_slug.css" ]] \
    || fail "Omarchy theme has no Tauri Explorer palette: $omarchy_slug"
  [[ -f "$repo_root/dot_config/lite-xl/colors/$omarchy_slug.lua" ]] \
    || fail "Omarchy theme has no Lite XL palette: $omarchy_slug"
  [[ -f "$repo_root/dot_config/micro/colorschemes/$omarchy_slug.micro" ]] \
    || fail "Omarchy theme has no Micro palette: $omarchy_slug"
  [[ -f "$repo_root/dot_config/p10k-themes/$omarchy_slug.zsh" ]] \
    || fail "Omarchy theme has no Powerlevel10k palette: $omarchy_slug"
  [[ -f "$repo_root/dot_local/share/vicinae/themes/$omarchy_slug.toml" ]] \
    || fail "Omarchy theme has no Vicinae palette: $omarchy_slug"
  vscode_theme="$repo_root/dot_vscode/extensions/local.omarchy-desktop-themes-0.0.1/themes/$omarchy_slug-color-theme.json"
  jq -e --arg title "$omarchy_title" '.name == $title' "$vscode_theme" >/dev/null \
    || fail "Omarchy theme has no matching VS Code palette: $omarchy_slug"
  jq -e --arg title "$omarchy_title" \
    --arg path "./themes/$omarchy_slug-color-theme.json" \
    '.contributes.themes[] | select(.label == $title and .path == $path)' \
    "$repo_root/dot_vscode/extensions/local.omarchy-desktop-themes-0.0.1/package.json" \
    >/dev/null || fail "VS Code extension does not expose: $omarchy_title"
  obsidian_dir="$repo_root/Vaults/Technical Vault/dot_obsidian/themes/$omarchy_title"
  [[ -f "$obsidian_dir/manifest.json" && -f "$obsidian_dir/theme.css" ]] \
    || fail "Omarchy theme has no Obsidian palette: $omarchy_slug"
  jq -e --arg title "$omarchy_title" '.name == $title' \
    "$obsidian_dir/manifest.json" >/dev/null \
    || fail "Obsidian manifest does not expose: $omarchy_title"
done

grep -Fq 'variant = "light"' \
  "$repo_root/dot_local/share/vicinae/themes/flexoki-light.toml" \
  || fail "Flexoki Light is not declared as a light desktop theme"
grep -Fq 'variant = "light"' \
  "$repo_root/dot_local/share/vicinae/themes/ayu-light.toml" \
  || fail "Ayu Light is not declared as a light desktop theme"
grep -Fq 'variant = "light"' \
  "$repo_root/dot_local/share/vicinae/themes/mapquest.toml" \
  || fail "MapQuest is not declared as a light desktop theme"

for desktop_wallpaper in \
  omarchy-kanagawa.jpg \
  omarchy-tokyo-night.webp \
  omarchy-hackerman.jpg \
  omarchy-ethereal.webp \
  marek-piwnicki-rwcONvax9qE-unsplash.jpg \
  omarchy-ayu-light.jpg \
  stephen-leonardi-eSNjFDbw_i4-unsplash.jpg \
  omarchy-osaka-jade.webp \
  omarchy-artzen.png \
  omarchy-mapquest.jpg \
  omarchy-sakura.jpg \
  omarchy-sunset.jpg; do
  grep -Fq "Pictures/Wallpaper/$desktop_wallpaper" \
    "$repo_root/.chezmoiexternal.toml" \
    || fail "desktop wallpaper is not managed by chezmoi: $desktop_wallpaper"
done

jq -e '
  [.themes[] | {name, appearance}] == [
    {name: "Kanagawa", appearance: "dark"},
    {name: "Hackerman", appearance: "dark"},
    {name: "Ethereal", appearance: "dark"},
    {name: "Ayu Light", appearance: "light"},
    {name: "Flexoki Light", appearance: "light"},
    {name: "Osaka Jade", appearance: "dark"},
    {name: "Artzen", appearance: "dark"},
    {name: "Infernium Dark", appearance: "dark"},
    {name: "MapQuest", appearance: "light"},
    {name: "Sakura", appearance: "dark"},
    {name: "Sunset", appearance: "dark"}
  ]
' "$repo_root/dot_config/zed/themes/omarchy-extra.json" >/dev/null \
  || fail "Omarchy Zed theme family is incomplete or has an invalid mode"

mkdir -p "$test_root/.config/hypr" \
  "$test_root/.config/ghostty/themes" \
  "$test_root/.config/tauri-explorer/themes" \
  "$test_root/.config/Code/User" \
  "$test_root/.config/google-chrome/Default" \
  "$test_root/.local/share/chrome-themes" \
  "$test_root/.local/share/vicinae/themes" \
  "$test_root/.vscode/extensions" \
  "$test_root/Vaults/Technical Vault/.obsidian/themes" \
  "$test_root/Pictures/Wallpaper" \
  "$test_root/google-chrome/extensions" \
  "$test_root/bin"
touch "$test_root/Pictures/Wallpaper/planet_with_sunrise.png"
touch "$test_root/Pictures/Wallpaper/custom.photo.jpg"
touch "$test_root/Pictures/Wallpaper/omarchy-kanagawa.jpg"
touch "$test_root/Pictures/Wallpaper/omarchy-tokyo-night.webp"
touch "$test_root/Pictures/Wallpaper/omarchy-hackerman.jpg"
touch "$test_root/Pictures/Wallpaper/omarchy-ethereal.webp"
touch "$test_root/Pictures/Wallpaper/marek-piwnicki-rwcONvax9qE-unsplash.jpg"
touch "$test_root/Pictures/Wallpaper/img-20260909-082623.png"
touch "$test_root/Pictures/Wallpaper/omarchy-osaka-jade.webp"
touch "$test_root/Pictures/Wallpaper/omarchy-artzen.png"
touch "$test_root/Pictures/Wallpaper/stephen-leonardi-eSNjFDbw_i4-unsplash.jpg"
touch "$test_root/Pictures/Wallpaper/omarchy-mapquest.jpg"
touch "$test_root/Pictures/Wallpaper/omarchy-sakura.jpg"
touch "$test_root/Pictures/Wallpaper/omarchy-sunset.jpg"
printf 'theme = Old Theme\n' >"$test_root/.config/ghostty/config"
touch "$test_root/greeter.css"
printf '{"workbench.colorTheme": "Old Theme"}\n' \
  >"$test_root/.config/Code/User/settings.json"
printf '{"theme": "obsidian", "cssTheme": "Old Theme", "accentColor": "#000000"}\n' \
  >"$test_root/Vaults/Technical Vault/.obsidian/appearance.json"
cp -r "$repo_root/dot_local/share/chrome-themes/cosmic-dusk" \
  "$test_root/.local/share/chrome-themes/cosmic-dusk"
cp -r "$repo_root/dot_vscode/extensions/local.omarchy-desktop-themes-0.0.1" \
  "$test_root/.vscode/extensions/"
for omarchy_slug in "${omarchy_themes[@]}"; do
  omarchy_title=${theme_titles[$omarchy_slug]:-}
  [[ -n "$omarchy_title" ]] \
    || omarchy_title=$(printf '%s' "$omarchy_slug" | tr '-' ' ' | sed 's/\b\(.\)/\u\1/g')
  cp -r "$repo_root/dot_local/share/chrome-themes/$omarchy_slug" \
    "$test_root/.local/share/chrome-themes/$omarchy_slug"
  cp "$repo_root/dot_config/ghostty/themes/$omarchy_title" \
    "$test_root/.config/ghostty/themes/$omarchy_title"
  cp "$repo_root/dot_config/ghostty/themes/$omarchy_slug-tabs.css" \
    "$test_root/.config/ghostty/themes/$omarchy_slug-tabs.css"
  cp "$repo_root/dot_config/tauri-explorer/themes/$omarchy_slug.css" \
    "$test_root/.config/tauri-explorer/themes/$omarchy_slug.css"
  cp "$repo_root/dot_local/share/vicinae/themes/$omarchy_slug.toml" \
    "$test_root/.local/share/vicinae/themes/$omarchy_slug.toml"
  cp -r "$repo_root/Vaults/Technical Vault/dot_obsidian/themes/$omarchy_title" \
    "$test_root/Vaults/Technical Vault/.obsidian/themes/$omarchy_title"
done

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
cat > "$test_root/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_SYSTEMCTL_LOG"
[[ "$*" == "reload --user app-com.mitchellh.ghostty.service" ]]
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
  "$test_root/bin/systemctl" "$test_root/bin/hyprctl"

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
    TEST_SYSTEMCTL_LOG="$test_root/systemctl.log" \
    HOME="$test_root" \
    PATH="$test_root/bin:$PATH" \
    HYPRLAND_INSTANCE_SIGNATURE=test \
    SET_THEME_GOOGLE_CHROME_EXTENSION_DIR="$test_root/google-chrome/extensions" \
    SET_THEME_GREETER_CSS="$test_root/greeter.css" \
    DARKREADER_FORK_RELEASE_URL="file://$test_root/missing-darkreader-release.zip" \
    DARKREADER_FORK_RELEASE_SHA256="0000000000000000000000000000000000000000000000000000000000000000" \
    bash "$repo_root/scripts/set-theme.sh" "$@"
}

ethereal_wallpaper="$test_root/Pictures/Wallpaper/omarchy-ethereal.webp"

# Compound app themes are discoverable only when both their palette and package
# metadata exist. Exercise each metadata seam independently so preflight cannot
# regress to checking the color file alone.
mv "$test_root/.vscode/extensions/local.omarchy-desktop-themes-0.0.1/package.json" \
  "$test_root/vscode-package.missing"
missing_assets=$(HOME="$test_root" desktop_theme_missing_assets \
  ethereal Ethereal "$ethereal_wallpaper")
grep -Fq 'VS Code:' <<<"$missing_assets" \
  || fail "preflight accepted a VS Code theme without package metadata"
mv "$test_root/vscode-package.missing" \
  "$test_root/.vscode/extensions/local.omarchy-desktop-themes-0.0.1/package.json"

mv "$test_root/Vaults/Technical Vault/.obsidian/themes/Ethereal/manifest.json" \
  "$test_root/obsidian-manifest.missing"
missing_assets=$(HOME="$test_root" desktop_theme_missing_assets \
  ethereal Ethereal "$ethereal_wallpaper")
grep -Fq 'Obsidian:' <<<"$missing_assets" \
  || fail "preflight accepted an Obsidian theme without its manifest"
mv "$test_root/obsidian-manifest.missing" \
  "$test_root/Vaults/Technical Vault/.obsidian/themes/Ethereal/manifest.json"

# A managed WezTerm installation consists of the main config plus its appearance
# module. The module itself being absent must not disable validation.
mkdir -p "$test_root/.config/wezterm"
printf 'return {}\n' >"$test_root/.config/wezterm/wezterm.lua"
missing_assets=$(HOME="$test_root" desktop_theme_missing_assets \
  ethereal Ethereal "$ethereal_wallpaper")
grep -Fq 'WezTerm:' <<<"$missing_assets" \
  || fail "preflight accepted a missing WezTerm appearance module"
mv "$test_root/.config/wezterm" "$test_root/wezterm-module.missing"

# Browser detection must cover every binary supported by set-theme.sh, not just
# Google Chrome. Isolate PATH to a Vivaldi-only probe and remove its theme dir.
mkdir -p "$test_root/browser-bin"
cp "$test_root/bin/vicinae" "$test_root/browser-bin/vivaldi"
ln -s "$(command -v grep)" "$test_root/browser-bin/grep"
mv "$test_root/.config/google-chrome" "$test_root/google-chrome.hidden"
mv "$test_root/.local/share/chrome-themes/hackerman" \
  "$test_root/hackerman-chrome.missing"
missing_assets=$(HOME="$test_root" PATH="$test_root/browser-bin" \
  desktop_theme_missing_assets hackerman Hackerman \
  "$test_root/Pictures/Wallpaper/omarchy-hackerman.jpg")
grep -Fq 'Chrome:' <<<"$missing_assets" \
  || fail "preflight ignored a Vivaldi installation without theme assets"
mv "$test_root/hackerman-chrome.missing" \
  "$test_root/.local/share/chrome-themes/hackerman"
mv "$test_root/google-chrome.hidden" "$test_root/.config/google-chrome"

# Profile-only browser installs are supported on macOS even when their binary
# is not on PATH. Profile discovery comes from chrome-theme.sh on both paths.
mkdir -p "$test_root/profile-bin" \
  "$test_root/Library/Application Support/Vivaldi"
ln -s "$(command -v grep)" "$test_root/profile-bin/grep"
mv "$test_root/.config/google-chrome" "$test_root/google-chrome.hidden"
mv "$test_root/.local/share/chrome-themes/kanagawa" \
  "$test_root/kanagawa-chrome.missing"
missing_assets=$(HOME="$test_root" PATH="$test_root/profile-bin" \
  desktop_theme_missing_assets kanagawa Kanagawa \
  "$test_root/Pictures/Wallpaper/omarchy-kanagawa.jpg")
grep -Fq 'Chrome:' <<<"$missing_assets" \
  || fail "preflight ignored a macOS Vivaldi profile without theme assets"
mv "$test_root/kanagawa-chrome.missing" \
  "$test_root/.local/share/chrome-themes/kanagawa"
mv "$test_root/google-chrome.hidden" "$test_root/.config/google-chrome"

# A locally managed theme must fail before changing any settings when one of
# its assets has not been applied. This is the contract that prevents an app
# from being pointed at a nonexistent theme name.
mv "$test_root/.config/tauri-explorer/themes/ethereal.css" \
  "$test_root/ethereal.css.missing"
cp "$test_root/.config/ghostty/config" "$test_root/ghostty-before-preflight"
cp "$test_root/.config/Code/User/settings.json" "$test_root/code-before-preflight"
cp "$test_root/Vaults/Technical Vault/.obsidian/appearance.json" \
  "$test_root/obsidian-before-preflight"
if run_set_theme ethereal >"$test_root/preflight.out" 2>&1; then
  fail "an incomplete locally managed theme was accepted"
fi
cmp -s "$test_root/ghostty-before-preflight" \
  "$test_root/.config/ghostty/config" \
  || fail "failed theme preflight partially changed Ghostty"
cmp -s "$test_root/code-before-preflight" \
  "$test_root/.config/Code/User/settings.json" \
  || fail "failed theme preflight partially changed VS Code"
cmp -s "$test_root/obsidian-before-preflight" \
  "$test_root/Vaults/Technical Vault/.obsidian/appearance.json" \
  || fail "failed theme preflight partially changed Obsidian"
[[ ! -e "$test_root/.local/state/desktop-theme/current.json" ]] \
  || fail "failed theme preflight persisted partial state"
assert_contains "$test_root/preflight.out" \
  "Theme 'Ethereal' is not installed completely; no settings were changed."
assert_contains "$test_root/preflight.out" \
  "Tauri Explorer/shared palette: $test_root/.config/tauri-explorer/themes/ethereal.css"
mv "$test_root/ethereal.css.missing" \
  "$test_root/.config/tauri-explorer/themes/ethereal.css"

desktop_themes=$(HOME="$test_root" bash "$repo_root/scripts/set-theme.sh" --list-desktop-themes)
grep -Fxq 'Cosmic Dusk' <<<"$desktop_themes" \
  || fail "desktop theme listing omitted its display name"
if grep -q $'\t' <<<"$desktop_themes"; then
  fail "desktop theme listing repeated names as slug metadata"
fi

mv "$test_root/Pictures/Wallpaper/omarchy-sunset.jpg" \
  "$test_root/omarchy-sunset.jpg.missing"
incomplete_desktop_themes=$(
  HOME="$test_root" bash "$repo_root/scripts/set-theme.sh" --list-desktop-themes
)
if grep -Fxq 'Sunset' <<<"$incomplete_desktop_themes"; then
  fail "desktop theme listing exposed a theme with missing required assets"
fi
mv "$test_root/omarchy-sunset.jpg.missing" \
  "$test_root/Pictures/Wallpaper/omarchy-sunset.jpg"

: >"$test_root/chrome-restart.log"
run_set_theme cosmic-dusk --restart-chrome > "$test_root/default.out"
default_path="$test_root/Pictures/Wallpaper/planet_with_sunrise.png"
theme_state="$test_root/.local/state/desktop-theme/current.json"
[[ -f "$theme_state" ]] || fail "set-theme did not create local theme state"
assert_contains "$theme_state" '"slug": "cosmic-dusk"'
assert_contains "$theme_state" '"title": "Cosmic Dusk"'
assert_contains "$theme_state" '"mode": "dark"'
assert_contains "$test_root/.config/ghostty/config" 'theme = Cosmic Dusk'
assert_contains "$test_root/systemctl.log" \
  'reload --user app-com.mitchellh.ghostty.service'
assert_contains "$test_root/default.out" 'Ghostty: reloaded automatically'
current_chrome_id=$(chrome_theme_extension_id "$chrome_state/key.pem")
[[ "$current_chrome_id" != "$blocked_chrome_id" ]] \
  || fail "Chrome kept using an externally blocklisted theme identity"
[[ -f "$test_root/google-chrome/extensions/$current_chrome_id.json" ]] \
  || fail "Chrome descriptor was not written for the replacement identity"
[[ ! -e "$test_root/google-chrome/extensions/$blocked_chrome_id.json" ]] \
  || fail "the obsolete Chrome descriptor was not removed"
assert_contains "$test_root/default.out" \
  "Chrome had blocked the previous external theme; reset its install identity"
state_output_line=$(grep -nF '✓ Local theme state' "$test_root/default.out" | cut -d: -f1)
chrome_output_line=$(grep -nF '✓ Chrome' "$test_root/default.out" | cut -d: -f1)
[[ -n "$state_output_line" && -n "$chrome_output_line" \
  && "$state_output_line" -lt "$chrome_output_line" ]] \
  || fail "Chrome did not run after the persisted desktop theme update"
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

# Each requested theme switches the observable desktop state, uses its own
# wallpaper and palette, and classifies every light theme correctly.
omarchy_cases=(
  'kanagawa|Kanagawa|dark|omarchy-kanagawa.jpg|#7e9cd8|#1f1f28|#dcd7ba|#363646'
  'tokyo-night|Tokyo Night|dark|omarchy-tokyo-night.webp|#7aa2f7|#1a1b26|#a9b1d6|#292e42'
  'hackerman|Hackerman|dark|omarchy-hackerman.jpg|#82fb9c|#0b0c16|#ddf7ff|#1f253a'
  'ethereal|Ethereal|dark|omarchy-ethereal.webp|#7d82d9|#060b1e|#ffcead|#252e56'
  'flexoki-light|Flexoki Light|light|marek-piwnicki-rwcONvax9qE-unsplash.jpg|#205ea6|#fffcf0|#100f0f|#cecdc3'
  'ayu-light|Ayu Light|light|img-20260909-082623.png|#3199e1|#f8f9fa|#5c6166|#d3e1f5'
  'osaka-jade|Osaka Jade|dark|omarchy-osaka-jade.webp|#509475|#111c18|#c1c497|#32473b'
  'artzen|Artzen|dark|omarchy-artzen.png|#da7a6f|#181c1f|#fdf9f8|#3b2b2c'
  'infernium-dark|Infernium Dark|dark|stephen-leonardi-eSNjFDbw_i4-unsplash.jpg|#e3884a|#1c1c1c|#e0e0e0|#d66938'
  'mapquest|MapQuest|light|omarchy-mapquest.jpg|#465353|#ecd3a1|#3c4747|#b79f70'
  'sakura|Sakura|dark|omarchy-sakura.jpg|#d9a56c|#0d0509|#f0eaed|#230e18'
  'sunset|Sunset|dark|omarchy-sunset.jpg|#dda660|#070605|#ffffff|#302519'
)
for omarchy_case in "${omarchy_cases[@]}"; do
  IFS='|' read -r omarchy_slug omarchy_title omarchy_mode \
    omarchy_wallpaper omarchy_accent omarchy_background omarchy_foreground \
    omarchy_selection <<<"$omarchy_case"
  run_set_theme "$omarchy_slug" >"$test_root/$omarchy_slug.out" 2>&1
  assert_contains "$test_root/$omarchy_slug.out" \
    "Switching all apps to: $omarchy_title ($omarchy_slug)"
  assert_contains "$test_root/$omarchy_slug.out" "Chrome → $omarchy_title"
  assert_contains "$test_root/$omarchy_slug.out" "Dark Reader → $omarchy_slug"
  assert_contains "$theme_state" "\"slug\": \"$omarchy_slug\""
  assert_contains "$theme_state" "\"mode\": \"$omarchy_mode\""
  assert_contains "$test_root/.config/ghostty/config" "theme = $omarchy_title"
  assert_contains "$test_root/.config/Code/User/settings.json" \
    "\"workbench.colorTheme\": \"$omarchy_title\""
  assert_contains "$test_root/Vaults/Technical Vault/.obsidian/appearance.json" \
    "\"cssTheme\": \"$omarchy_title\""
  assert_contains "$test_root/Vaults/Technical Vault/.obsidian/appearance.json" \
    "\"accentColor\": \"$omarchy_accent\""
  obsidian_mode=obsidian
  [[ "$omarchy_mode" == light ]] && obsidian_mode=moonstone
  assert_contains "$test_root/Vaults/Technical Vault/.obsidian/appearance.json" \
    "\"theme\": \"$obsidian_mode\""
  assert_contains "$test_root/.config/hypr/hyprpaper.conf" \
    "path = $test_root/Pictures/Wallpaper/$omarchy_wallpaper"
  assert_contains "$test_root/.config/hypr/theme-colors.lua" \
    "accent       = \"${omarchy_accent#\#}\""
  assert_contains "$test_root/.config/hypr/theme-colors.lua" \
    "mode         = \"$omarchy_mode\""
  expected_opacity=0.95
  expected_shadow=0.45
  if [[ "$omarchy_mode" == light ]]; then
    expected_opacity=0.99
    expected_shadow=0.12
  fi
  assert_contains "$test_root/.config/ghostty/config" "background-opacity = $expected_opacity"
  assert_contains "$test_root/greeter.css" "box-shadow: 0 8px 32px rgba(0, 0, 0, $expected_shadow)"
  if [[ "$omarchy_slug" == flexoki-light ]]; then
    assert_contains "$test_root/.config/hypr/theme-colors.lua" 'surface      = "f2efe4"'
    assert_contains "$test_root/.config/hypr/theme-colors.lua" 'border       = "d4d1c8"'
    assert_contains "$test_root/greeter.css" 'background-color: #f2efe4;'
    assert_contains "$test_root/greeter.css" 'background-color: rgba(255, 252, 240, 0.97);'
  fi
  # Reload the real theme module against each generated file: light -> dark
  # transitions must restore the configured application opacity.
  lua - "$repo_root" "$test_root" "$omarchy_mode" <<'LUA'
local repo, root, mode = arg[1], arg[2], arg[3]
package.path = root .. '/.config/hypr/?.lua;' .. repo .. '/dot_config/hypr/?.lua;' .. package.path
-- Simulate the previous session's cached modules, then execute the actual
-- config reload prelude before requiring the newly generated palette.
package.loaded.theme = { window_opacity = function() return 'stale' end }
package.loaded['theme-colors'] = { mode = mode == 'light' and 'dark' or 'light' }
local config = assert(io.open(repo .. '/dot_config/hypr/hyprland.lua.tmpl'))
local prelude = config:read('*a'):match('^(.-)local nary =')
config:close()
assert(load(prelude))()
local theme = require 'theme'
assert(theme.window_opacity(0.93) == (mode == 'light' and '0.98 0.98' or '0.93 0.93'))
LUA

  zed_theme="$repo_root/dot_config/zed/themes/omarchy-extra.json"
  [[ "$omarchy_slug" == tokyo-night ]] \
    && zed_theme="$repo_root/dot_config/zed/themes/tokyo-night.json"
  jq -e --arg title "$omarchy_title" \
    --arg background "${omarchy_background}ff" \
    --arg foreground "${omarchy_foreground}ff" \
    --arg selection "${omarchy_selection}ff" '
      .themes[] | select(.name == $title) |
      .style.background == $background and
      .style.text == $foreground and
      .style["element.selected"] == $selection
    ' "$zed_theme" >/dev/null \
    || fail "Zed palette drifted from Omarchy: $omarchy_slug"

  obsidian_theme="$repo_root/Vaults/Technical Vault/dot_obsidian/themes/$omarchy_title/theme.css"
  assert_contains "$obsidian_theme" "--background-primary: $omarchy_background"
  assert_contains "$obsidian_theme" "--text-normal: $omarchy_foreground"

  darkreader_mode=1
  darkreader_background_key=darkSchemeBackgroundColor
  darkreader_foreground_key=darkSchemeTextColor
  if [[ "$omarchy_mode" == light ]]; then
    darkreader_mode=0
    darkreader_background_key=lightSchemeBackgroundColor
    darkreader_foreground_key=lightSchemeTextColor
  fi
  jq -e --argjson mode "$darkreader_mode" \
    --arg background "$omarchy_background" \
    --arg foreground "$omarchy_foreground" \
    --arg background_key "$darkreader_background_key" \
    --arg foreground_key "$darkreader_foreground_key" '
      .theme.mode == $mode and
      .theme[$background_key] == $background and
      .theme[$foreground_key] == $foreground
    ' "$test_root/.local/state/darkreader-theme-bridge/current.json" >/dev/null \
    || fail "Dark Reader palette drifted from Omarchy: $omarchy_slug"
done

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
