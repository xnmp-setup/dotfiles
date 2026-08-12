#!/usr/bin/env bash

set -euo pipefail

test_dir=$(mktemp -d /tmp/theme-state.XXXXXX)

cleanup() {
  [[ "$test_dir" == /tmp/theme-state.* ]] && rm -rf -- "$test_dir"
}
trap cleanup EXIT

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=${script_dir%/scripts}
# shellcheck source=lib/theme-state.sh
source "$script_dir/lib/theme-state.sh"

export HOME="$test_dir/home"
export XDG_STATE_HOME="$test_dir/state"
mkdir -p "$HOME"

state_file=$(desktop_theme_state_file)
[[ "$state_file" == "$test_dir/state/desktop-theme/current.json" ]]
[[ ! -e "$state_file" ]]

chezmoi_for_test() {
  chezmoi \
    --source "$repo_dir" \
    --destination "$HOME" \
    "$@"
}

render_target() {
  local relative_target="$1"
  chezmoi_for_test cat "$HOME/$relative_target"
}

rg -Fq '"colorscheme": "nord"' < <(render_target ".config/micro/settings.json")

desktop_theme_write_state \
  "cosmic-dusk" \
  "Cosmic Dusk" \
  "dark" \
  "Cosmic Dusk" \
  "yosemite-glow" \
  "cosmic-dusk"

[[ -f "$state_file" ]]
[[ "$(desktop_theme_read_state_value "$state_file" slug)" == "cosmic-dusk" ]]
[[ "$(desktop_theme_read_state_value "$state_file" wezterm)" == "Cosmic Dusk" ]]

expected_state="$test_dir/expected.json"
printf '%s\n' \
  '{' \
  '  "slug": "cosmic-dusk",' \
  '  "title": "Cosmic Dusk",' \
  '  "mode": "dark",' \
  '  "wezterm": "Cosmic Dusk",' \
  '  "vicinae_light": "yosemite-glow",' \
  '  "vicinae_dark": "cosmic-dusk"' \
  '}' > "$expected_state"
cmp "$expected_state" "$state_file"

rg -Fq 'theme = Cosmic Dusk' < <(render_target ".config/ghostty/config")
rg -Fq "config.color_scheme = 'Cosmic Dusk'" \
  < <(render_target ".config/wezterm/wezterm_appearance.lua")
rg -Fq 'load_first_theme { "cosmic-dusk",' \
  < <(render_target ".config/lite-xl/init.lua")
rg -Fq '"colorscheme": "cosmic-dusk"' \
  < <(render_target ".config/micro/settings.json")
rg -Fq '"workbench.colorTheme": "Cosmic Dusk"' \
  < <(render_target ".config/Code/User/settings.json")
rg -Fq '"dark": "Cosmic Dusk"' \
  < <(render_target ".config/zed/settings.json")
rg -Fq '"name": "yosemite-glow"' \
  < <(render_target ".config/vicinae/settings.json")
rg -Fq '"name": "cosmic-dusk"' \
  < <(render_target ".config/vicinae/settings.json")
rg -Fq '"hideToTrayOnClose": true' \
  < <(render_target ".config/YouTube Music Desktop App/config.json")
rg -Fq '"customCSSEnabled": true' \
  < <(render_target ".config/YouTube Music Desktop App/config.json")
rg -Fq "\"customCSSPath\": \"$HOME/.config/YouTube Music Desktop App/theme.css\"" \
  < <(render_target ".config/YouTube Music Desktop App/config.json")

managed_targets=(
  ".config/ghostty/config"
  ".config/wezterm/wezterm_appearance.lua"
  ".config/lite-xl/init.lua"
  ".config/micro/settings.json"
  ".config/Code/User/settings.json"
  ".config/zed/settings.json"
  ".config/vicinae/settings.json"
  ".config/YouTube Music Desktop App/config.json"
)
absolute_targets=()
for relative_target in "${managed_targets[@]}"; do
  absolute_target="$HOME/$relative_target"
  absolute_targets+=("$absolute_target")
  chezmoi_for_test apply --parent-dirs "$absolute_target"
done

[[ -z "$(chezmoi_for_test diff -- "${absolute_targets[@]}")" ]]

vicinae_config="$test_dir/vicinae.json"
printf '%s\n' \
  '{' \
  '  "theme": {' \
  '    "light": { "name": "yosemite-glow" },' \
  '    "dark": {' \
  '      "name": "nord"' \
  '    }' \
  '  }' \
  '}' > "$vicinae_config"

[[ "$(desktop_theme_read_vicinae_name "$vicinae_config" light)" == "yosemite-glow" ]]
[[ "$(desktop_theme_read_vicinae_name "$vicinae_config" dark)" == "nord" ]]
[[ -z "$(desktop_theme_read_vicinae_name "$test_dir/missing.json" dark || true)" ]]

desktop_theme_write_state \
  'quoted"slug' \
  $'Line\nBreak' \
  "dark" \
  'Back\slash' \
  "light" \
  "dark"

rg -Fq '  "slug": "quoted\"slug",' "$state_file"
rg -Fq '  "title": "Line\nBreak",' "$state_file"
rg -Fq '  "wezterm": "Back\\slash",' "$state_file"

echo "theme-state tests passed"
