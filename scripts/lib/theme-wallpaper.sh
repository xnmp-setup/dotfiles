# Wallpaper associations and Hyprpaper/Hyprlock integration for set-theme.sh.

wallpaper_dir="$HOME/Pictures/Wallpaper"

# Defaults are filenames relative to $wallpaper_dir. The command-line option
# can override an association for one invocation.
declare -A theme_wallpapers=(
  [everforest]="autumn-river-everforest-gruvbox.jpg"
  [everforest-dark-medium]="autumn-river-everforest-gruvbox.jpg"
  [gruvbox]="gruvbox_forest-4.png"
  [cosmic-dusk]="planet_with_sunrise.png"
  [rapture]="river_4k.png"
  [nord]="wp10368836-mac-os-yosemite-wallpapers.jpg"
  [ayu-mirage]="stephen-leonardi-eSNjFDbw_i4-unsplash.jpg"
  [horizon-dark]="saleh-gJ60sKuuYlE-unsplash.jpg"
  [catppuccin-mocha]="photo-1482784160316-6eb046863ece.avif"
)

list_wallpapers() {
  if [[ ! -d "$wallpaper_dir" ]]; then
    echo "Wallpaper directory not found: $wallpaper_dir" >&2
    return 1
  fi
  find "$wallpaper_dir" -maxdepth 1 -type f -printf '  %f\n' | sort
}

# Resolve an absolute path, a path relative to the current directory, or a
# filename in $wallpaper_dir. For the latter, allow the extension to be
# omitted when exactly one file has that stem.
resolve_wallpaper() {
  local choice="$1"
  local candidate=""

  if [[ -z "$choice" ]]; then
    echo "Wallpaper cannot be empty" >&2
    return 1
  fi

  case "$choice" in
    /*) candidate="$choice" ;;
    \~/*) candidate="$HOME/${choice:2}" ;;
    */*) candidate="$PWD/$choice" ;;
    *)   candidate="$wallpaper_dir/$choice" ;;
  esac

  if [[ ! -f "$candidate" && "$choice" != */* ]]; then
    local match=""
    local matches=0
    while IFS= read -r -d '' candidate; do
      if [[ "${candidate##*/}" == "$choice".* ]]; then
        match="$candidate"
        ((matches++))
      fi
    done < <(find "$wallpaper_dir" -maxdepth 1 -type f -print0 2>/dev/null)

    if (( matches > 1 )); then
      echo "Wallpaper name is ambiguous (include its extension): $choice" >&2
      return 1
    fi
    candidate="$match"
  fi

  if [[ ! -f "$candidate" ]]; then
    echo "Wallpaper not found: $choice" >&2
    return 1
  fi
  if [[ "$candidate" == *$'\n'* || "$candidate" == *,* ]]; then
    echo "Wallpaper paths cannot contain newlines or commas: $candidate" >&2
    return 1
  fi

  realpath -- "$candidate"
}

# Rewrite path only within the requested Hyprlang section. Hyprpaper's legacy
# preload/wallpaper syntax is supported for configs created by older versions.
rewrite_hypr_section_paths() {
  local file="$1"
  local section="$2"
  local replacement="$3"
  local tmp rewrite_status

  [[ -f "$file" ]] || return 2
  tmp=$(mktemp)
  rewrite_status=0
  awk -v section="$section" -v replacement="$replacement" '
    BEGIN { in_section = 0; found_path = 0 }
    {
      if ($0 ~ "^[[:space:]]*" section "[[:space:]]*\\{") {
        in_section = 1
      }

      if (in_section && match($0, /^[[:space:]]*path[[:space:]]*=[[:space:]]*/)) {
        print substr($0, 1, RLENGTH) replacement
        found_path = 1
        next
      }

      if (section == "wallpaper" &&
          match($0, /^[[:space:]]*preload[[:space:]]*=[[:space:]]*/)) {
        print substr($0, 1, RLENGTH) replacement
        next
      }

      if (section == "wallpaper" &&
          $0 ~ /^[[:space:]]*wallpaper[[:space:]]*=/ && match($0, /,/)) {
        print substr($0, 1, RSTART) replacement
        found_path = 1
        next
      }

      print
      if (in_section && $0 ~ /^[[:space:]]*}[[:space:]]*(#.*)?$/) {
        in_section = 0
      }
    }
    END { if (!found_path) exit 42 }
  ' "$file" > "$tmp" || rewrite_status=$?

  if (( rewrite_status != 0 )); then
    rm -f -- "$tmp"
    (( rewrite_status == 42 )) && return 3
    return "$rewrite_status"
  fi

  if ! cmp -s -- "$tmp" "$file"; then
    # Copy over the file to preserve its mode and follow a config-manager
    # symlink instead of replacing the link itself.
    cp -- "$tmp" "$file" || {
      rm -f -- "$tmp"
      return 1
    }
  fi
  rm -f -- "$tmp"
}

read_hyprpaper_fit_mode() {
  local config="$1"
  local configured_fit_mode

  configured_fit_mode=$(awk -F= '
    /^[[:space:]]*fit_mode[[:space:]]*=/ {
      sub(/[[:space:]]*#.*/, "", $2)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      print $2
      exit
    }
  ' "$config")
  if [[ -n "$configured_fit_mode" && "$configured_fit_mode" != *,* ]]; then
    echo "$configured_fit_mode"
  else
    echo cover
  fi
}

apply_hyprpaper_live() {
  local path="$1"
  local fit_mode="$2"
  local monitor
  local -a monitors=()

  [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || return 2
  command -v hyprctl &>/dev/null || return 2

  if command -v jq &>/dev/null; then
    mapfile -t monitors < <(hyprctl monitors -j 2>/dev/null | jq -r '.[].name' 2>/dev/null)
  else
    mapfile -t monitors < <(hyprctl monitors 2>/dev/null | awk '/^Monitor / { print $2 }')
  fi
  (( ${#monitors[@]} > 0 )) || return 1

  # A fallback target does not replace a monitor previously assigned by name.
  for monitor in "${monitors[@]}"; do
    hyprctl hyprpaper wallpaper "$monitor, $path, $fit_mode" &>/dev/null || return 1
  done
}
