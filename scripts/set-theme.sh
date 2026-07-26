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

# Extract a hex colour for a CSS custom property from a stylesheet.
#   css_var <file> <var-name-without-dashes>
css_var() {
  grep -oP -- "--$2:\s*\K#[0-9a-fA-F]{3,8}" "$1" 2>/dev/null | head -1
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

# --- Dark Reader (browser extension) ---
# Dark Reader keeps its config in the browser's extension storage (a live
# LevelDB), which can't be safely edited from a script. Instead we generate an
# importable settings file and derive the palette from the theme's tauri CSS,
# then the user imports it via the Dark Reader UI (one-time per theme change).
dr_css="$HOME/.config/tauri-explorer/themes/$slug.css"
if [[ -f "$dr_css" ]] && command -v jq &>/dev/null; then
  bg=$(css_var "$dr_css" background-solid)
  fg=$(css_var "$dr_css" text-primary)
  accent=$(css_var "$dr_css" accent)
  if [[ -n "$bg" && -n "$fg" ]]; then
    # Light slugs drive the light scheme; everything else is a dark scheme.
    dr_mode=1
    [[ "$slug" =~ light ]] && dr_mode=0

    dr_dir="$HOME/.local/share/darkreader-themes"
    mkdir -p "$dr_dir"
    dr_file="$dr_dir/$slug.json"

    # Full default theme object with our colour overrides, so importing this
    # replaces only the theme (site lists etc. are preserved by the merge).
    jq -n \
      --argjson mode "$dr_mode" \
      --arg bg "$bg" --arg fg "$fg" \
      --arg sel "${accent:-auto}" \
      '{
        enabled: true,
        theme: {
          mode: $mode,
          brightness: 100, contrast: 100, grayscale: 0, sepia: 0,
          useFont: false, fontFamily: "", textStroke: 0,
          engine: "dynamicTheme", stylesheet: "",
          darkSchemeBackgroundColor: (if $mode == 1 then $bg else "#181a1b" end),
          darkSchemeTextColor:       (if $mode == 1 then $fg else "#e8e6e3" end),
          lightSchemeBackgroundColor:(if $mode == 0 then $bg else "#dcdad7" end),
          lightSchemeTextColor:      (if $mode == 0 then $fg else "#181a1b" end),
          scrollbarColor: "auto",
          selectionColor: $sel,
          styleSystemControls: true
        }
      }' > "$dr_file"

    echo "  ✓ Dark Reader → $slug (bg $bg, fg $fg)"
    echo "    Import once: Dark Reader → Settings (gear) → Manage settings"
    echo "    → Import Settings → $dr_file"
    ((changed++))
  else
    skipped+=("Dark Reader (could not read colours from $dr_css)")
  fi
elif [[ -f "$dr_css" ]]; then
  skipped+=("Dark Reader (jq not installed)")
else
  skipped+=("Dark Reader (no tauri theme CSS at $dr_css to derive colours)")
fi

# --- Hyprland ---
# Hyprland's Lua config reads its palette from theme-colors.lua (see
# ~/.config/hypr/theme.lua). Derive it from the same tauri stylesheet Dark
# Reader is fed, so borders, the tab strip and the backdrop behind a resize
# follow the theme instead of staying on whatever they were built with.
#
# Only the vars that are reliably a solid hex across every theme are read:
# background-solid, accent, accent-light, text-primary, text-secondary. The
# rest of what Hyprland needs is mixed from those, which is also what keeps
# light themes working — "a shade lifted off the background" has to darken on
# a light theme and lighten on a dark one, and a fixed colour cannot do both.
hypr_css="$HOME/.config/tauri-explorer/themes/$slug.css"
hypr_dir="$HOME/.config/hypr"
if [[ -f "$hypr_css" && -d "$hypr_dir" ]]; then
  # Expand #abc to #aabbcc so the mixer always has six digits to work with.
  norm_hex() {
    local h="${1#\#}"
    if (( ${#h} == 3 )); then
      h="${h:0:1}${h:0:1}${h:1:1}${h:1:1}${h:2:1}${h:2:1}"
    fi
    echo "${h:0:6}"
  }

  # mix <hex-a> <hex-b> <percent-of-b> -> hex
  mix() {
    local a b t
    a=$(norm_hex "$1"); b=$(norm_hex "$2"); t="$3"
    printf '%02x%02x%02x' \
      $(( 16#${a:0:2} + (16#${b:0:2} - 16#${a:0:2}) * t / 100 )) \
      $(( 16#${a:2:2} + (16#${b:2:2} - 16#${a:2:2}) * t / 100 )) \
      $(( 16#${a:4:2} + (16#${b:4:2} - 16#${a:4:2}) * t / 100 ))
  }

  h_bg=$(css_var "$hypr_css" background-solid)
  h_accent=$(css_var "$hypr_css" accent)
  h_accent_light=$(css_var "$hypr_css" accent-light)
  h_text=$(css_var "$hypr_css" text-primary)
  h_text_dim=$(css_var "$hypr_css" text-secondary)

  if [[ -n "$h_bg" && -n "$h_accent" && -n "$h_text" ]]; then
    # Fall back within the theme before falling back to the config's defaults.
    [[ -z "$h_accent_light" ]] && h_accent_light="$h_accent"
    [[ -z "$h_text_dim" ]] && h_text_dim="$h_text"

    # The active tab sits 18% of the way from the background toward the text,
    # and an inactive border 30% — enough to read as a surface and an edge
    # without either becoming a second accent.
    h_surface=$(mix "$h_bg" "$h_text" 18)
    h_border=$(mix "$h_bg" "$h_text_dim" 30)

    cat > "$hypr_dir/theme-colors.lua" <<EOF
-- Generated by set-theme.sh from $slug — do not edit.
-- Regenerate with: set-theme $slug
return {
    accent       = "$(norm_hex "$h_accent")",
    accent_light = "$(norm_hex "$h_accent_light")",
    background   = "$(norm_hex "$h_bg")",
    surface      = "$h_surface",
    border       = "$h_border",
    text         = "$(norm_hex "$h_text")",
    text_dim     = "$(norm_hex "$h_text_dim")",
}
EOF
    echo "  ✓ Hyprland → $slug (bg $h_bg, accent $h_accent)"
    # Only reload a compositor that is actually up; set-theme also runs over ssh.
    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && command -v hyprctl &>/dev/null; then
      hyprctl reload &>/dev/null && echo "    reloaded"
    fi
    ((changed++))
  else
    skipped+=("Hyprland (could not read colours from $hypr_css)")
  fi
elif [[ -d "$hypr_dir" ]]; then
  skipped+=("Hyprland (no tauri theme CSS at $hypr_css to derive colours)")
else
  skipped+=("Hyprland (no config dir at $hypr_dir)")
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
  echo "  Dark Reader: import the generated JSON (see above)"
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
