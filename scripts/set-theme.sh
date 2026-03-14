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
           ~/.config/micro/colorschemes/*.micro; do
    [[ -f "$f" ]] || continue
    local name
    name=$(basename "$f")
    name="${name%.*}"  # strip extension
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

# --- Summary ---
echo ""
if (( changed > 0 )); then
  echo "Updated $changed app(s). Reload to see changes:"
  echo "  Ghostty: Ctrl+Shift+,"
  echo "  Lite XL / Micro: relaunch"
  echo "  VS Code: restart (new extensions need full restart)"
  echo "  Obsidian: restart or toggle in Appearance"
  echo "  Tauri Explorer: relaunch"
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
