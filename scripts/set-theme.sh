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

# Whether the theme is a light theme. The theme's own files are the authority —
# a slug like "yosemite-glow" carries no hint, so a name test alone misfiles
# light themes as dark. Vicinae's TOML declares the variant explicitly; fall
# back to the "-light" naming convention for themes that predate a TOML.
theme_is_light() {
  local toml="$HOME/.local/share/vicinae/themes/$slug.toml"
  if [[ -f "$toml" ]]; then
    grep -qE '^\s*variant\s*=\s*"light"' "$toml"
    return
  fi
  [[ "$slug" =~ light ]]
}

title=$(title_case "$slug")
changed=0
skipped=()
# Reload hints, appended only by sections that actually changed something, so
# the summary reflects what happened rather than listing every known app.
reload=()

echo "Switching all apps to: $title ($slug)"

# --- Ghostty ---
config="$HOME/.config/ghostty/config"
if [[ -f "$config" ]]; then
  if grep -q "^theme = " "$config"; then
    sed -i "s/^theme = .*/theme = $title/" "$config"
    echo "  ✓ Ghostty → $title"
    reload+=("Ghostty: Ctrl+Shift+,")
    ((changed++))
  else
    echo "theme = $title" >> "$config"
    echo "  ✓ Ghostty → $title (appended)"
    reload+=("Ghostty: Ctrl+Shift+,")
    ((changed++))
  fi
else
  skipped+=("Ghostty (no config at $config)")
fi

# --- WezTerm ---
# Schemes come from two places: inline entries in config.color_schemes —
# historically in wezterm.lua, now in wezterm_appearance.lua — and WezTerm's
# builtin scheme collection. Check the inline table first, then ask wezterm
# itself for a builtin matching "$title" (builtin names vary per wezterm
# version, so probe rather than hardcode). The comparison ignores case and
# punctuation, and tolerates a source-collection suffix, so "Everforest Dark
# Medium" finds "Everforest Dark Medium (Gogh)". The match is smuggled out
# through the Lua error message because show-keys has no other output channel.
# Prints the builtin's real name on success. The sed keeps the line's
# indentation: inside the appearance module the assignment is indented.
wez_builtin_scheme() {
  command -v wezterm &>/dev/null || return 1
  local want
  want=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' ' ' | sed 's/^ *//; s/ *$//')
  # wezterm exits non-zero because the probe's error() "fails" the config
  # override — that is expected, so mask it under pipefail; grep's status
  # (match found or not) is the function's result.
  { wezterm --config-file /dev/null --config "status_update_interval=(function()
    local schemes = wezterm.color.get_builtin_schemes()
    local function norm(s) return (s:lower():gsub('%W+',' '):gsub('^ +',''):gsub(' +$','')) end
    for _, suffix in ipairs({'', ' gogh', ' base16', ' terminal sexy'}) do
      for k in pairs(schemes) do
        if norm(k) == '$want'..suffix then error('WEZMATCH<'..k..'>') end
      end
    end
    error('WEZNOMATCH')
  end)()" show-keys 2>&1 || true; } | grep -m1 -oP 'WEZMATCH<\K[^>]+'
}
wez_done=0
for config in "$HOME/.config/wezterm/wezterm_appearance.lua" \
              "$HOME/.config/wezterm/wezterm.lua"; do
  [[ -f "$config" ]] || continue
  grep -q "config\.color_scheme = " "$config" || continue
  wez_scheme=""
  if grep -qF "['$title']" "$config"; then
    wez_scheme="$title"
  else
    wez_scheme=$(wez_builtin_scheme "$title") || wez_scheme=""
  fi
  if [[ -n "$wez_scheme" ]]; then
    sed -i "s|^\(\s*\)config\.color_scheme = .*|\1config.color_scheme = '$wez_scheme'|" "$config"
    echo "  ✓ WezTerm → $wez_scheme ($(basename "$config"))"
    reload+=("WezTerm: Ctrl+Shift+, (reloads config)")
    ((changed++))
    wez_done=1
  fi
  break
done
if (( ! wez_done )); then
  skipped+=("WezTerm (no '$title' scheme inline in wezterm config or in wezterm's builtins)")
fi

# --- Lite XL ---
config="$HOME/.config/lite-xl/init.lua"
if [[ -f "$config" ]]; then
  if grep -q 'core.reload_module("colors\.' "$config"; then
    sed -i "s|core.reload_module(\"colors\.[^\"]*\")|core.reload_module(\"colors.$slug\")|" "$config"
    echo "  ✓ Lite XL → colors.$slug"
    reload+=("Lite XL: relaunch")
    ((changed++))
  elif grep -q 'load_first_theme {' "$config"; then
    # init.lua now loads themes through a fallback list; the requested theme
    # goes first and the existing fallbacks keep a missing file from aborting.
    sed -i "s|load_first_theme { \"[^\"]*\"|load_first_theme { \"$slug\"|" "$config"
    echo "  ✓ Lite XL → $slug (load_first_theme)"
    reload+=("Lite XL: relaunch")
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
    reload+=("Micro: relaunch")
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
    reload+=("VS Code: restart (new extensions need full restart)")
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
  # Light themes get moonstone, dark ones obsidian
  obs_mode="obsidian"
  theme_is_light && obs_mode="moonstone"

  if grep -q '"cssTheme"' "$config"; then
    sed -i "s|\"cssTheme\": \"[^\"]*\"|\"cssTheme\": \"$title\"|" "$config"
    sed -i "s|\"theme\": \"[^\"]*\"|\"theme\": \"$obs_mode\"|" "$config"
    echo "  ✓ Obsidian → $title ($obs_mode)"
    reload+=("Obsidian: restart or toggle in Appearance")
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
    reload+=("Tauri Explorer: relaunch")
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
# Chrome keeps exactly one theme installed at a time and offers no way to
# reload an unpacked theme from disk, so "switching" the theme really means
# installing a different extension. The only silent, scriptable install path
# is the *external extension* mechanism: pack the theme directory into a
# .crx signed with a per-machine key, then drop a descriptor where the
# browser scans for external extensions (per-user "External Extensions" on
# macOS and Chromium-branded builds; /usr/share/google-chrome/extensions for
# branded Chrome on Linux). The browser reads that at startup and installs
# (or updates) the extension without any UI.
#
# The signing key is generated once per machine and reused, which keeps the
# extension ID stable — that is what makes every later switch an *update* of
# the same extension rather than a fresh install.
#
# Two constraints follow from the mechanism and cannot be worked around:
#   1. a theme change only lands when the browser next launches (hence the
#      optional restart prompt at the end of this section);
#   2. the very first install on a machine is a genuinely new extension, so
#      Chrome may show a one-time consent/"added to Chrome" bubble. Every
#      switch after that is silent, because it is an update.
chrome_theme_dir="$HOME/chrome-themes-$slug"
# Also check alternate location
[[ ! -d "$chrome_theme_dir" ]] && chrome_theme_dir="$HOME/.local/share/chrome-themes/$slug"

# First Chromium-family binary on PATH. It is both the packer (--pack-extension
# is a short-lived mode that works alongside a running browser) and, if the
# restart prompt is accepted, the browser we relaunch.
chrome_bin=""
for c in google-chrome-stable google-chrome chromium chromium-browser \
         vivaldi microsoft-edge brave; do
  chrome_bin=$(command -v "$c" 2>/dev/null) && break
  chrome_bin=""
done

if [[ ! -d "$chrome_theme_dir" ]]; then
  skipped+=("Chrome (no theme dir found for $slug)")
elif [[ -z "$chrome_bin" ]]; then
  skipped+=("Chrome (no Chromium-family browser on PATH to pack the theme)")
elif ! command -v openssl &>/dev/null; then
  skipped+=("Chrome (openssl not installed; needed to sign the .crx)")
else
  chrome_state="${XDG_STATE_HOME:-$HOME/.local/state}/chrome-theme"
  chrome_staging="$chrome_state/staging"
  chrome_key="$chrome_state/key.pem"
  chrome_crx="$chrome_state/current.crx"
  mkdir -p "$chrome_state"

  # Fresh staging copy every run. "Cached Theme.pak" is a Chrome-side artefact
  # that ends up in the source dir once a theme has been installed; a stale one
  # inside the .crx would win over the manifest's colours.
  rm -rf "$chrome_staging" "$chrome_staging.crx"
  cp -r "$chrome_theme_dir" "$chrome_staging"
  rm -f "$chrome_staging/Cached Theme.pak"

  # Chrome only installs an external extension whose version is newer than the
  # installed one, so the version has to climb on every switch. Each dotted
  # component must be an integer 0-65535: the date parts are reduced to plain
  # integers (0805 -> 805, so no leading zeros) and the counter wraps far below
  # the limit while still breaking ties within the same minute.
  chrome_seq=$(( ( $(cat "$chrome_state/seq" 2>/dev/null || echo 0) + 1 ) % 65536 ))
  printf '%s\n' "$chrome_seq" > "$chrome_state/seq"
  chrome_version="$(date +%Y).$((10#$(date +%m%d))).$((10#$(date +%H%M))).$chrome_seq"

  chrome_manifest="$chrome_staging/manifest.json"
  if command -v jq &>/dev/null; then
    tmp=$(mktemp)
    jq --arg v "$chrome_version" '.version = $v' "$chrome_manifest" > "$tmp" \
      && mv "$tmp" "$chrome_manifest" || rm -f "$tmp"
  else
    sed -i "s|\"version\"\s*:\s*\"[^\"]*\"|\"version\": \"$chrome_version\"|" "$chrome_manifest"
  fi
  # Read the version back out: the descriptor's external_version must match the
  # packed manifest exactly or Chrome silently ignores the descriptor.
  chrome_version=$(grep -oP '"version"\s*:\s*"\K[^"]+' "$chrome_manifest" | head -1)

  # One RSA key per machine, never rotated — rotating it changes the extension
  # ID and turns the next switch back into a first install.
  if [[ ! -f "$chrome_key" ]]; then
    (umask 077; openssl genrsa -out "$chrome_key" 2048 &>/dev/null)
    chmod 600 "$chrome_key"
  fi

  # Extension ID: SHA-256 of the DER-encoded public key, first 16 bytes, hex
  # digits remapped 0-f -> a-p (Chrome's mpdecimal-ish alphabet).
  chrome_id=$(openssl rsa -in "$chrome_key" -pubout -outform DER 2>/dev/null \
    | openssl dgst -sha256 -binary \
    | head -c 16 | od -An -vtx1 | tr -d ' \n' | tr '0-9a-f' 'a-p')

  # --pack-extension runs headless and exits; it does not contend with a
  # running browser's profile singleton.
  chrome_pack_out=$("$chrome_bin" --pack-extension="$chrome_staging" \
    --pack-extension-key="$chrome_key" --no-message-box 2>&1)

  if [[ ! -s "$chrome_staging.crx" || ${#chrome_id} -ne 32 ]]; then
    skipped+=("Chrome (packing failed: ${chrome_pack_out:-no .crx produced})")
  else
    mv -f "$chrome_staging.crx" "$chrome_crx"

    chrome_descriptor() {
      cat > "$1" <<EOF
{
  "external_crx": "$chrome_crx",
  "external_version": "$chrome_version"
}
EOF
    }

    chrome_installed=()

    # Google Chrome on Linux is the odd one out: chromium's chrome_paths.cc
    # gates the per-user "External Extensions" dir to macOS and
    # Chromium-branded builds, so branded Chrome only scans two root-owned
    # dirs; /usr/share/google-chrome/extensions is the documented one. Chrome
    # does not verify the owner (that check is compiled in on macOS only), so
    # a one-time
    #   sudo mkdir -p /usr/share/google-chrome/extensions
    #   sudo chown $USER /usr/share/google-chrome/extensions
    # makes every later switch here work without privileges.
    chrome_sudo_hint=""
    if [[ -d "$HOME/.config/google-chrome" ]]; then
      gc_sys="/usr/share/google-chrome/extensions"
      if [[ -w "$gc_sys" ]] || { [[ -e "$gc_sys/$chrome_id.json" && -w "$gc_sys/$chrome_id.json" ]]; }; then
        chrome_descriptor "$gc_sys/$chrome_id.json"
        chrome_installed+=("google-chrome")
      else
        chrome_sudo_hint="$gc_sys"
      fi
    fi

    # Per-user profile roots that DO scan "External Extensions": every browser
    # on macOS, and Chromium-branded builds on Linux. Only existing dirs are
    # touched, which is also how we avoid branching on the OS.
    for browser_dir in "$HOME/.config/chromium" \
                       "$HOME/.config/vivaldi" \
                       "$HOME/.config/microsoft-edge" \
                       "$HOME/.config/BraveSoftware/Brave-Browser" \
                       "$HOME/Library/Application Support/Google/Chrome" \
                       "$HOME/Library/Application Support/Chromium" \
                       "$HOME/Library/Application Support/Vivaldi" \
                       "$HOME/Library/Application Support/Microsoft Edge" \
                       "$HOME/Library/Application Support/BraveSoftware/Brave-Browser"; do
      [[ -d "$browser_dir" ]] || continue
      mkdir -p "$browser_dir/External Extensions"
      chrome_descriptor "$browser_dir/External Extensions/$chrome_id.json"
      chrome_installed+=("$(basename "$browser_dir")")
    done

    echo "  ✓ Chrome → $title (applies at next browser launch)"
    reload+=("Chrome: applies at next launch (or via the restart prompt)")
    if [[ -n "$chrome_sudo_hint" ]]; then
      echo "    Google Chrome needs a ONE-TIME setup before it sees theme switches:"
      echo "      sudo mkdir -p $chrome_sudo_hint && sudo chown $USER $chrome_sudo_hint"
      echo "    then re-run set-theme $slug."
    fi
    if (( ${#chrome_installed[@]} == 0 )) && [[ -z "$chrome_sudo_hint" ]]; then
      echo "    (no Chromium-family browser profile found; .crx written anyway)"
    fi
    ((changed++))

    # Offer the restart only when a human is watching and the browser is
    # actually up; scripted runs (chezmoi hooks, ssh) must never block or kill
    # a browser. Session restore brings the tabs back.
    case "$(basename "$chrome_bin")" in
      google-chrome*|chrome) chrome_proc="chrome" ;;
      chromium*)             chrome_proc="chromium" ;;
      vivaldi*)              chrome_proc="vivaldi-bin" ;;
      microsoft-edge*)       chrome_proc="msedge" ;;
      brave*)                chrome_proc="brave" ;;
      *)                     chrome_proc="$(basename "$chrome_bin")" ;;
    esac
    if [[ -t 0 ]] && pgrep -x "$chrome_proc" &>/dev/null; then
      read -r -p "    Restart Chrome now to apply? [y/N] " chrome_answer
      if [[ "$chrome_answer" =~ ^[Yy]$ ]]; then
        pkill -TERM -x "$chrome_proc"
        for _ in $(seq 20); do
          pgrep -x "$chrome_proc" &>/dev/null || break
          sleep 0.5
        done
        if command -v setsid &>/dev/null; then
          setsid -f "$chrome_bin" &>/dev/null
        else
          nohup "$chrome_bin" &>/dev/null &
        fi
        echo "    restarted"
      fi
    fi
  fi
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
    # Light themes drive the light scheme; everything else is a dark scheme.
    dr_mode=1
    theme_is_light && dr_mode=0

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
    reload+=("Dark Reader: import the generated JSON (see above)")
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
      reload+=("Hyprland: reloaded automatically")
    else
      reload+=("Hyprland: hyprctl reload (next session picks it up otherwise)")
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
  zed_mode="dark"
  theme_is_light && zed_mode="light"

  if grep -q '"theme"' "$config"; then
    sed -i '/\"theme\": {/,/}/ s|"mode": "[^"]*"|"mode": "'"$zed_mode"'"|' "$config"
    sed -i '/\"theme\": {/,/}/ s|"light": "[^"]*"|"light": "'"$title"'"|' "$config"
    sed -i '/\"theme\": {/,/}/ s|"dark": "[^"]*"|"dark": "'"$title"'"|' "$config"
    echo "  ✓ Zed → $title ($zed_mode)"
    reload+=("Zed: applied immediately (if running)")
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
  reload+=("Vicinae: applied immediately")
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
  reload+=("Powerlevel10k: applied (if called via set-theme shell function)")
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
  for r in "${reload[@]}"; do
    echo "  $r"
  done
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
