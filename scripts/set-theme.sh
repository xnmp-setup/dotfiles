#!/usr/bin/env bash
# Switch all desktop apps to a named theme.
# Usage: set-theme <theme-slug>
#   e.g. set-theme golden-hour-light
#
# The theme slug is the lowercase-hyphenated form (matching filenames).
# Title Case names are derived automatically for apps that need them.

set -uo pipefail

slug="${1:-}"

list_themes() {
  local found=0
  # Gather slugs from all known theme dirs
  local -A slugs
  for f in ~/.config/ghostty/themes/* \
           ~/.config/tauri-explorer/themes/*.css \
           ~/.config/lite-xl/colors/*.lua \
           ~/.config/micro/colorschemes/*.micro \
           ~/.config/p10k-themes/*.zsh \
           ~/.local/share/chrome-themes/*/manifest.json \
           ~/chrome-themes-*/manifest.json; do
    [[ -f "$f" ]] || continue
    local name
    # For Chrome themes, use parent dir name instead of manifest.json
    if [[ "$(basename "$f")" == "manifest.json" ]]; then
      name=$(basename "$(dirname "$f")")
      name="${name#chrome-themes-}"  # strip prefix if present
    else
      name=$(basename "$f")
      name="${name%.*}"  # strip extension
    fi
    # Normalise to slug
    local s
    s=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    slugs[$s]=1
  done

  if (( ${#slugs[@]} == 0 )); then
    echo "  (none found)"
    return
  fi

  for s in $(echo "${!slugs[@]}" | tr ' ' '\n' | sort); do
    echo "  $s"
  done
}

if [[ -z "$slug" ]]; then
  echo "Usage: set-theme <theme-slug>"
  echo ""
  echo "Available themes:"
  list_themes
  exit 0
fi

# Derive title case name from slug: "golden-hour-light" -> "Golden Hour Light"
title_case() {
  echo "$1" | tr '-' ' ' | sed 's/\b\(.\)/\u\1/g'
}

title=$(title_case "$slug")
changed=0
skipped=()

echo "Switching all apps to: $title ($slug)"

# --- Ghostty ---
config="$HOME/.config/ghostty/config"
if [[ -f "$config" ]]; then
  if grep -q "^theme = " "$config"; then
    sed -i "s/^theme = .*/theme = $title/" "$config"
    echo "  ✓ Ghostty → $title"
    ((changed++))
  else
    echo "theme = $title" >> "$config"
    echo "  ✓ Ghostty → $title (appended)"
    ((changed++))
  fi
else
  skipped+=("Ghostty (no config at $config)")
fi

# --- WezTerm ---
# Schemes are defined inline in wezterm.lua (config.color_schemes), so only
# switch when the requested theme actually exists there.
config="$HOME/.config/wezterm/wezterm.lua"
if [[ -f "$config" ]]; then
  if grep -qF "['$title']" "$config"; then
    sed -i "s|^config.color_scheme = .*|config.color_scheme = '$title'|" "$config"
    echo "  ✓ WezTerm → $title"
    ((changed++))
  else
    skipped+=("WezTerm (no '$title' scheme defined in wezterm.lua)")
  fi
else
  skipped+=("WezTerm (no config at $config)")
fi

# --- Lite XL ---
config="$HOME/.config/lite-xl/init.lua"
if [[ -f "$config" ]]; then
  if grep -q 'core.reload_module("colors\.' "$config"; then
    sed -i "s|core.reload_module(\"colors\.[^\"]*\")|core.reload_module(\"colors.$slug\")|" "$config"
    echo "  ✓ Lite XL → colors.$slug"
    ((changed++))
  else
    skipped+=("Lite XL (no colors.* line in init.lua)")
  fi
else
  skipped+=("Lite XL (no config at $config)")
fi

# --- Micro ---
config="$HOME/.config/micro/settings.json"
if [[ -f "$config" ]]; then
  if grep -q '"colorscheme"' "$config"; then
    sed -i "s|\"colorscheme\": \"[^\"]*\"|\"colorscheme\": \"$slug\"|" "$config"
    echo "  ✓ Micro → $slug"
    ((changed++))
  else
    skipped+=("Micro (no colorscheme key in settings.json)")
  fi
else
  skipped+=("Micro (no config at $config)")
fi

# --- VS Code ---
config="$HOME/.config/Code/User/settings.json"
if [[ -f "$config" ]]; then
  if grep -q '"workbench.colorTheme"' "$config"; then
    sed -i "s|\"workbench.colorTheme\": \"[^\"]*\"|\"workbench.colorTheme\": \"$title\"|" "$config"
    echo "  ✓ VS Code → $title"
    ((changed++))
  else
    skipped+=("VS Code (no workbench.colorTheme in settings.json)")
  fi
else
  skipped+=("VS Code (no config at $config)")
fi

# --- Obsidian ---
config="$HOME/Vaults/Technical Vault/.obsidian/appearance.json"
if [[ -f "$config" ]]; then
  # Determine light/dark: slugs containing "light" get moonstone, else obsidian
  obs_mode="obsidian"
  [[ "$slug" =~ light ]] && obs_mode="moonstone"

  if grep -q '"cssTheme"' "$config"; then
    sed -i "s|\"cssTheme\": \"[^\"]*\"|\"cssTheme\": \"$title\"|" "$config"
    sed -i "s|\"theme\": \"[^\"]*\"|\"theme\": \"$obs_mode\"|" "$config"
    echo "  ✓ Obsidian → $title ($obs_mode)"
    ((changed++))
  else
    skipped+=("Obsidian (no cssTheme key in appearance.json)")
  fi
else
  skipped+=("Obsidian (no config at $config)")
fi

# --- Tauri Explorer ---
config="$HOME/.config/tauri-explorer/settings.json"
if [[ -f "$config" ]] && command -v jq &>/dev/null; then
  tmp=$(mktemp)
  if jq --arg t "$slug" '.theme = $t' "$config" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$config"
    echo "  ✓ Tauri Explorer → $slug"
    ((changed++))
  else
    rm -f "$tmp"
    skipped+=("Tauri Explorer (jq failed to update settings.json)")
  fi
elif [[ -f "$config" ]]; then
  skipped+=("Tauri Explorer (jq not installed)")
else
  skipped+=("Tauri Explorer (no config at $config)")
fi

# --- Chrome ---
chrome_theme_dir="$HOME/chrome-themes-$slug"
# Also check alternate location
[[ ! -d "$chrome_theme_dir" ]] && chrome_theme_dir="$HOME/.local/share/chrome-themes/$slug"
if [[ -d "$chrome_theme_dir" ]]; then
  echo "  ✓ Chrome → $slug"
  echo "    Load unpacked: chrome://extensions/ → Developer mode → Load unpacked → $chrome_theme_dir"
  echo "    (Ctrl+H in the file picker to show hidden folders)"
  ((changed++))
else
  skipped+=("Chrome (no theme dir found for $slug)")
fi

# --- Zed ---
config="$HOME/.config/zed/settings.json"
if [[ -f "$config" ]]; then
  # Determine light/dark from slug
  zed_mode="dark"
  [[ "$slug" =~ light ]] && zed_mode="light"

  if grep -q '"theme"' "$config"; then
    sed -i '/\"theme\": {/,/}/ s|"mode": "[^"]*"|"mode": "'"$zed_mode"'"|' "$config"
    sed -i '/\"theme\": {/,/}/ s|"light": "[^"]*"|"light": "'"$title"'"|' "$config"
    sed -i '/\"theme\": {/,/}/ s|"dark": "[^"]*"|"dark": "'"$title"'"|' "$config"
    echo "  ✓ Zed → $title ($zed_mode)"
    ((changed++))
  else
    skipped+=("Zed (no theme key in settings.json)")
  fi
else
  skipped+=("Zed (no config at $config)")
fi

# --- Vicinae ---
if command -v vicinae &>/dev/null; then
  vicinae theme set "$slug" &>/dev/null
  echo "  ✓ Vicinae → $slug"
  ((changed++))
else
  skipped+=("Vicinae (not installed)")
fi

# --- Powerlevel10k (zsh prompt) ---
theme_dir="$HOME/.config/p10k-themes"
theme_file="$theme_dir/$slug.zsh"
if [[ -f "$theme_file" ]]; then
  ln -sf "$theme_file" "$theme_dir/current.zsh"
  echo "  ✓ Powerlevel10k → $slug (restart shell or: source ~/.zshrc)"
  ((changed++))
elif [[ -d "$theme_dir" ]]; then
  skipped+=("Powerlevel10k (no theme file at $theme_file)")
else
  skipped+=("Powerlevel10k (no theme dir at $theme_dir)")
fi

# --- Summary ---
echo ""
if (( changed > 0 )); then
  echo "Updated $changed app(s). Reload to see changes:"
  echo "  Ghostty: Ctrl+Shift+,"
  echo "  WezTerm: Ctrl+Shift+, (reloads config)"
  echo "  Lite XL / Micro: relaunch"
  echo "  VS Code: restart (new extensions need full restart)"
  echo "  Obsidian: restart or toggle in Appearance"
  echo "  Tauri Explorer: relaunch"
  echo "  Chrome: reload extension at chrome://extensions/"
  echo "  Zed: applied immediately (if running)"
  echo "  Vicinae: applied immediately"
  echo "  Powerlevel10k: applied (if called via set-theme shell function)"
else
  echo "No apps were updated."
fi

if (( ${#skipped[@]} > 0 )); then
  echo ""
  echo "Skipped:"
  for s in "${skipped[@]}"; do
    echo "  - $s"
  done
fi
