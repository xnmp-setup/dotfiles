#!/usr/bin/env bash
# Switch all desktop apps to a named theme.
# Usage: set-theme <theme-slug> [--wallpaper <name-or-path>]
#   e.g. set-theme everforest-dark-medium
#        set-theme everforest-dark-medium --wallpaper river_4k
#
# The theme slug is the lowercase-hyphenated form (matching filenames).
# Title Case names are derived automatically for apps that need them.
# The selected identifiers are also written to XDG_STATE_HOME so chezmoi's
# managed config templates preserve this machine-local choice.

set -uo pipefail

set_theme_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/theme-wallpaper.sh
source "$set_theme_script_dir/lib/theme-wallpaper.sh"
# shellcheck source=lib/chrome-layout.sh
source "$set_theme_script_dir/lib/chrome-layout.sh"
# shellcheck source=lib/theme-colors.sh
source "$set_theme_script_dir/lib/theme-colors.sh"
# shellcheck source=lib/theme-state.sh
source "$set_theme_script_dir/lib/theme-state.sh"

usage() {
  cat <<'EOF'
Usage: set-theme <theme-slug> [options]

Wallpaper-associated themes accept a unique slug prefix, such as "cosmic"
for "cosmic-dusk".

Options:
  -w, --wallpaper <name-or-path>  Override the theme's associated wallpaper.
                                  An extension is optional for files in
                                  ~/Pictures/Wallpaper.
      --list-wallpapers           List available wallpaper filenames.
  -h, --help                      Show this help.

Examples:
  set-theme everforest-dark-medium
  set-theme gruvbox --wallpaper river_4k
  set-theme nord -w ~/Pictures/Wallpaper/forest.png
EOF
}

slug=""
wallpaper_override=""
wallpaper_override_set=0
while (( $# > 0 )); do
  case "$1" in
    -w|--wallpaper)
      if (( $# < 2 )); then
        echo "Missing value for $1" >&2
        usage >&2
        exit 2
      fi
      wallpaper_override="$2"
      wallpaper_override_set=1
      shift 2
      ;;
    --wallpaper=*)
      wallpaper_override="${1#*=}"
      wallpaper_override_set=1
      shift
      ;;
    --list-wallpapers)
      list_wallpapers
      exit
      ;;
    -h|--help)
      usage
      exit
      ;;
    --)
      shift
      if (( $# > 0 )) && [[ -z "$slug" ]]; then
        slug="$1"
        shift
      fi
      if (( $# > 0 )); then
        echo "Unexpected argument: $1" >&2
        exit 2
      fi
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$slug" ]]; then
        echo "Unexpected argument: $1" >&2
        usage >&2
        exit 2
      fi
      slug="$1"
      shift
      ;;
  esac
done

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
  usage
  echo ""
  echo "Available themes:"
  list_themes
  exit 0
fi

requested_slug="$slug"
if ! slug=$(resolve_theme_slug "$requested_slug"); then
  exit 2
fi

wallpaper_request="${theme_wallpapers[$slug]:-}"
(( wallpaper_override_set )) && wallpaper_request="$wallpaper_override"
wallpaper_path=""
wallpaper_resolution_error=""
if (( wallpaper_override_set )) || [[ -n "$wallpaper_request" ]]; then
  if ! wallpaper_path=$(resolve_wallpaper "$wallpaper_request"); then
    if (( wallpaper_override_set )); then
      # An explicit choice is part of the requested operation. Validate it
      # before editing any application config, so failure cannot leave a
      # partially applied theme.
      exit 2
    fi
    wallpaper_resolution_error="associated file not found: $wallpaper_request"
  fi
fi

# Derive title case name from slug: "golden-hour-light" -> "Golden Hour Light"
title_case() {
  echo "$1" | tr '-' ' ' | sed 's/\b\(.\)/\u\1/g'
}

# css_var, norm_hex, mix, rgb_triplet and pick_readable come from
# lib/theme-colors.sh.

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
theme_mode="dark"
theme_is_light && theme_mode="light"

theme_state_file=$(desktop_theme_state_file)
vicinae_config="$HOME/.config/vicinae/settings.json"
vicinae_light=$(desktop_theme_read_vicinae_name "$vicinae_config" light || true)
vicinae_dark=$(desktop_theme_read_vicinae_name "$vicinae_config" dark || true)
[[ -n "$vicinae_light" ]] \
  || vicinae_light=$(desktop_theme_read_state_value "$theme_state_file" vicinae_light || true)
[[ -n "$vicinae_dark" ]] \
  || vicinae_dark=$(desktop_theme_read_state_value "$theme_state_file" vicinae_dark || true)
vicinae_light=${vicinae_light:-yosemite-glow}
vicinae_dark=${vicinae_dark:-nord}
if [[ "$theme_mode" == "light" ]]; then
  vicinae_light="$slug"
else
  vicinae_dark="$slug"
fi

changed=0
skipped=()
# Reload hints, appended only by sections that actually changed something, so
# the summary reflects what happened rather than listing every known app.
reload=()

echo "Switching all apps to: $title ($slug)"
if [[ "$requested_slug" != "$slug" ]]; then
  echo "  matched theme prefix: $requested_slug → $slug"
fi

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
wez_state="$title"
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
    wez_state="$wez_scheme"
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
        chrome_layout=""
        if chrome_layout=$(chrome_layout_snapshot "$chrome_proc"); then
          echo "    saved Chrome workspaces, groups, and focus"
        fi

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
        if [[ -n "$chrome_layout" ]]; then
          if chrome_layout_restore "$chrome_layout"; then
            echo "    restarted; restored Chrome workspaces, groups, and focus"
          else
            echo "    restarted; warning: Chrome layout could not be fully restored"
          fi
        else
          echo "    restarted"
        fi
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
    # fontFamily must be a non-empty string even with useFont off — Dark
    # Reader's import validator rejects "" ("Unexpected value for fontFamily").
    jq -n \
      --argjson mode "$dr_mode" \
      --arg bg "$bg" --arg fg "$fg" \
      --arg sel "${accent:-auto}" \
      '{
        enabled: true,
        theme: {
          mode: $mode,
          brightness: 100, contrast: 100, grayscale: 0, sepia: 0,
          useFont: false, fontFamily: "Open Sans", textStroke: 0,
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

# --- Hyprpaper + Hyprlock + greeter wallpaper ---
if [[ -n "$wallpaper_path" ]]; then
  hyprpaper_config="$HOME/.config/hypr/hyprpaper.conf"
  hyprlock_config="$HOME/.config/hypr/hyprlock.conf"
  hyprpaper_fit_mode="cover"
  wallpaper_configs=()

  if rewrite_hypr_section_paths "$hyprpaper_config" wallpaper "$wallpaper_path"; then
    wallpaper_configs+=("Hyprpaper")
    hyprpaper_fit_mode=$(read_hyprpaper_fit_mode "$hyprpaper_config")
  elif [[ ! -f "$hyprpaper_config" ]]; then
    skipped+=("Hyprpaper wallpaper (no config at $hyprpaper_config)")
  else
    skipped+=("Hyprpaper wallpaper (no wallpaper path in $hyprpaper_config)")
  fi

  if rewrite_hypr_section_paths "$hyprlock_config" background "$wallpaper_path"; then
    wallpaper_configs+=("Hyprlock")
  elif [[ ! -f "$hyprlock_config" ]]; then
    skipped+=("Hyprlock wallpaper (no config at $hyprlock_config)")
  else
    skipped+=("Hyprlock wallpaper (no background path in $hyprlock_config)")
  fi

  # The greeter is the one wallpaper consumer that is not a config file to
  # rewrite: it reads a fixed path, so switching themes means replacing the
  # image at that path. Its config names the path, and this only ever writes to
  # the file already named there — a machine with no regreet config has no
  # greeter of this kind and is skipped.
  #
  # The file is root-owned out of the box, and a theme switch must not need
  # privileges (set-theme also runs from hooks and over ssh). So an unwritable
  # destination becomes a one-time chown hint, the same arrangement the Chrome
  # section above uses for /usr/share/google-chrome/extensions.
  if greeter_background=$(regreet_background_path); then
    if install_greeter_wallpaper "$wallpaper_path" "$greeter_background"; then
      wallpaper_configs+=("greeter")
      reload+=("Greeter: applies at next logout")
    else
      skipped+=("Greeter wallpaper ($greeter_background is not writable; one-time setup: sudo chown $USER $greeter_background)")
    fi
  else
    skipped+=("Greeter wallpaper (no [background] path in /etc/greetd/regreet.toml)")
  fi

  if (( ${#wallpaper_configs[@]} > 0 )); then
    echo "  ✓ Wallpaper → $(basename "$wallpaper_path") (${wallpaper_configs[*]})"
    if apply_hyprpaper_live "$wallpaper_path" "$hyprpaper_fit_mode"; then
      echo "    Hyprpaper applied immediately"
      reload+=("Hyprpaper: applied automatically; Hyprlock: next lock")
    else
      reload+=("Hyprpaper: restart if running outside this session; Hyprlock: next lock")
    fi
    ((changed++))
  fi
elif [[ -n "$wallpaper_resolution_error" ]]; then
  skipped+=("Wallpaper ($wallpaper_resolution_error)")
else
  skipped+=("Wallpaper (no association for $slug; use --wallpaper to choose one)")
fi

# --- Hyprland colours ---
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
      # Reload resets decoration:screen_shader to unset, wiping the runtime
      # night-light shader; tell the solar daemon (laptops) to re-assert it.
      # No-op where the daemon isn't running (desktops use wlsunset).
      pkill -USR1 -f hyprshade_solar.py 2>/dev/null || true
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

# --- Greeter appearance (regreet) ---
# The greeter's wallpaper is handled with the other wallpapers above; this is
# the login box drawn on top of it. regreet is a GTK4 app and takes a custom
# global stylesheet — /etc/greetd/regreet.css by default — so the theme reaches
# it the same way it reaches Hyprland: a generated file derived from the tauri
# stylesheet, rather than a per-app theme someone has to install.
#
# The rules target regreet's own widget tree (see its templates.rs): the login
# box, the clock and the notification bar are all a GtkFrame carrying the
# "background" class, Login is .suggested-action and the power buttons are
# .destructive-action. Styling those nodes directly, rather than redefining
# Adwaita's named colours, keeps this working whichever GTK theme regreet.toml
# happens to name — and means a light theme needs no special case.
greeter_css_source="$HOME/.config/tauri-explorer/themes/$slug.css"
# regreet takes the stylesheet path as a CLI flag (--style), so it is not
# discoverable from its config the way the background path is. This follows the
# upstream default and lets a machine that passes --style, or a dry run against
# a scratch file, point the generator at the same place.
greeter_css="${SET_THEME_GREETER_CSS:-/etc/greetd/regreet.css}"
if [[ ! -f "$greeter_css_source" ]]; then
  skipped+=("Greeter appearance (no tauri theme CSS at $greeter_css_source to derive colours)")
elif [[ ! -d "${greeter_css%/*}" ]]; then
  skipped+=("Greeter appearance (no greetd config dir at ${greeter_css%/*})")
else
  g_bg=$(css_var "$greeter_css_source" background-solid)
  g_accent=$(css_var "$greeter_css_source" accent)
  g_accent_light=$(css_var "$greeter_css_source" accent-light)
  g_text=$(css_var "$greeter_css_source" text-primary)
  g_text_dim=$(css_var "$greeter_css_source" text-secondary)

  if [[ -z "$g_bg" || -z "$g_accent" || -z "$g_text" ]]; then
    skipped+=("Greeter appearance (could not read colours from $greeter_css_source)")
  elif [[ ! -w "$greeter_css" ]]; then
    # Same arrangement as the greeter wallpaper and the Chrome extensions dir:
    # a theme switch must never need privileges, so an unwritable target is
    # reported as one-time setup rather than escalated to.
    skipped+=("Greeter appearance ($greeter_css is not writable; one-time setup: sudo touch $greeter_css && sudo chown $USER $greeter_css)")
  else
    [[ -z "$g_accent_light" ]] && g_accent_light="$g_accent"
    [[ -z "$g_text_dim" ]] && g_text_dim="$g_text"

    # The same two mixes Hyprland gets, for the same reason: a surface that
    # reads as raised off the background, and an edge that reads as an edge.
    g_surface=$(mix "$g_bg" "$g_text" 18)
    g_border=$(mix "$g_bg" "$g_text_dim" 30)
    g_bg_rgb=$(rgb_triplet "$g_bg")
    g_accent_rgb=$(rgb_triplet "$g_accent")
    # Label for anything filled with the accent — measured, not assumed, since
    # the winner flips between light and dark themes.
    g_on_accent=$(pick_readable "$g_accent" "$g_bg" "$g_text")

    cat > "$greeter_css" <<EOF
/* Generated by set-theme.sh from $slug — do not edit.
   Regenerate with: set-theme $slug */

/* Let the wallpaper through everywhere the login box is not. */
window,
window > overlay,
picture {
    background-color: transparent;
}

/* The login box, the clock and the notification frame. Translucent so the
   wallpaper stays legible behind it, which is the whole point of having one. */
frame.background {
    background-color: rgba($g_bg_rgb, 0.82);
    border: 1px solid #$g_border;
    border-radius: 14px;
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.45);
}

label {
    color: #$(norm_hex "$g_text");
}

/* Text inputs sit on the raised surface, and take the accent when focused so
   there is never any doubt about where typing goes. */
entry,
passwordentry,
combobox button.combo {
    background-color: #$g_surface;
    background-image: none;
    color: #$(norm_hex "$g_text");
    border: 1px solid #$g_border;
    border-radius: 8px;
    min-height: 34px;
    caret-color: #$(norm_hex "$g_accent");
}

/* GTK draws the focus ring as an outline, not as the border, so recolouring
   the border alone leaves the stock Adwaita blue sitting on the theme. */
entry:focus-within,
passwordentry:focus-within,
combobox button.combo:focus {
    border-color: #$(norm_hex "$g_accent");
    outline-color: rgba($g_accent_rgb, 0.6);
    box-shadow: 0 0 0 2px rgba($g_accent_rgb, 0.35);
}

button:focus-visible {
    outline-color: rgba($g_accent_rgb, 0.6);
}

button {
    background-color: #$g_surface;
    background-image: none;
    color: #$(norm_hex "$g_text");
    border: 1px solid #$g_border;
    border-radius: 8px;
}

button:hover {
    background-color: #$g_border;
}

/* Login. The background sits on the accent, so its label has to return to the
   page colour to stay readable — text-primary on accent is not a safe pair. */
button.suggested-action {
    background-color: #$(norm_hex "$g_accent");
    background-image: none;
    color: #$g_on_accent;
    border-color: #$(norm_hex "$g_accent");
    font-weight: bold;
}

button.suggested-action:hover {
    background-color: #$(norm_hex "$g_accent_light");
    border-color: #$(norm_hex "$g_accent_light");
}

/* Reboot and power off. Deliberately quiet until pointed at: they are the two
   controls on this screen that are destructive to press by accident. */
button.destructive-action {
    background-color: transparent;
    background-image: none;
    color: #$(norm_hex "$g_text_dim");
    border-color: #$g_border;
}

button.destructive-action:hover {
    background-color: #$(norm_hex "$g_accent");
    color: #$g_on_accent;
    border-color: #$(norm_hex "$g_accent");
}

infobar,
infobar > revealer > box {
    background-color: #$g_surface;
    background-image: none;
    color: #$(norm_hex "$g_text");
}
EOF
    echo "  ✓ Greeter → $slug (bg $g_bg, accent $g_accent)"
    # The wallpaper section may already have said this; the greeter is one
    # screen and wants one line about it however many pieces were written.
    [[ " ${reload[*]} " == *" Greeter: applies at next logout "* ]] \
      || reload+=("Greeter: applies at next logout")
    ((changed++))
  fi
fi

# --- Zed ---
config="$HOME/.config/zed/settings.json"
if [[ -f "$config" ]]; then
  zed_mode="$theme_mode"

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
if command -v vicinae &>/dev/null && vicinae theme set "$slug" &>/dev/null; then
  echo "  ✓ Vicinae → $slug"
  reload+=("Vicinae: applied immediately")
  ((changed++))
else
  skipped+=("Vicinae (not installed or theme update failed)")
fi

if desktop_theme_write_state \
  "$slug" \
  "$title" \
  "$theme_mode" \
  "$wez_state" \
  "$vicinae_light" \
  "$vicinae_dark"; then
  echo "  ✓ Local theme state → $(desktop_theme_state_file)"
else
  skipped+=("Local theme state (could not write $(desktop_theme_state_file))")
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
