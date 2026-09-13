#!/usr/bin/env bash
# Optional machine-local desktop appearance backends; no work at source time.

desktop_color_scheme_gtk_theme_name() {
  local name="$1" mode="$2"
  case "$mode" in
    light) case "$name" in *-dark|*-Dark) name=${name%-*} ;; esac ;;
    dark) [[ "$name" != Adwaita ]] || name=Adwaita-dark ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$name"
}

desktop_color_scheme_update_gtk_ini() {
  local file="$1" mode="$2" prefer_dark temporary_file
  local line prefix value suffix mapped in_settings=0 saw_settings=0 saw_preference=0
  local section_pattern='^[[:space:]]*\[([^]]+)\][[:space:]]*$'
  local preference_pattern='^([[:space:]]*gtk-application-prefer-dark-theme[[:space:]]*=[[:space:]]*)(.*)$'
  local theme_pattern='^([[:space:]]*gtk-theme-name[[:space:]]*=[[:space:]]*)(.*)$'

  [[ -f "$file" ]] || return 0
  case "$mode" in
    light) prefer_dark=false ;;
    dark) prefer_dark=true ;;
    *) return 1 ;;
  esac
  temporary_file=$(mktemp "$file.XXXXXX") || return 1
  # Keep the existing permissions; stage beside the file for an atomic rename.
  if ! cp -p "$file" "$temporary_file"; then
    rm -f "$temporary_file" || return 1
    return 1
  fi
  if ! (
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ $section_pattern ]]; then
        if (( in_settings && ! saw_preference )); then
          printf 'gtk-application-prefer-dark-theme=%s\n' "$prefer_dark" || return 1
        fi
        in_settings=0
        if [[ "${BASH_REMATCH[1]}" == Settings ]]; then
          in_settings=1
          saw_settings=1
          saw_preference=0
        fi
      elif (( in_settings )) && [[ "$line" =~ $preference_pattern ]]; then
        line="${BASH_REMATCH[1]}$prefer_dark"
        saw_preference=1
      elif (( in_settings )) && [[ "$line" =~ $theme_pattern ]]; then
        prefix=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        mapped=${value%"${value##*[![:space:]]}"}
        suffix=${value#"$mapped"}
        mapped=$(desktop_color_scheme_gtk_theme_name "$mapped" "$mode") || return 1
        line="$prefix$mapped$suffix"
      fi
      printf '%s\n' "$line" || return 1
    done < "$file" || return 1
    if (( ! saw_settings )); then
      printf '[Settings]\ngtk-application-prefer-dark-theme=%s\n' "$prefer_dark" || return 1
    elif (( in_settings && ! saw_preference )); then
      printf 'gtk-application-prefer-dark-theme=%s\n' "$prefer_dark" || return 1
    fi
    return 0
  ) > "$temporary_file"; then
    rm -f "$temporary_file" || return 1
    return 1
  fi
  if ! mv -f "$temporary_file" "$file"; then
    rm -f "$temporary_file" || return 1
    return 1
  fi
  return 0
}

desktop_color_scheme_apply() {
  local mode="$1" prefer_dark use_light writable current mapped file os_name
  local config_root="${XDG_CONFIG_HOME:-$HOME/.config}"
  local schema=org.gnome.desktop.interface
  local registry_key='HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
  desktop_color_scheme_applied=()
  desktop_color_scheme_error=""
  case "$mode" in
    light) prefer_dark=false; use_light=1 ;;
    dark) prefer_dark=true; use_light=0 ;;
    *) desktop_color_scheme_error="invalid desktop colour scheme: $mode"; return 1 ;;
  esac

  # The schema and session bus are optional (notably on NixOS/headless hosts).
  if command -v gsettings >/dev/null 2>&1 \
    && writable=$(gsettings writable "$schema" color-scheme 2>/dev/null) \
    && [[ "$writable" == true ]] \
    && current=$(gsettings get "$schema" gtk-theme 2>/dev/null); then
    current=${current#\'}
    current=${current%\'}
    current=${current#\"}
    current=${current%\"}
    if mapped=$(desktop_color_scheme_gtk_theme_name "$current" "$mode") \
      && gsettings set "$schema" color-scheme "prefer-$mode" >/dev/null 2>&1; then
      if [[ "$mapped" == "$current" ]] \
        || gsettings set "$schema" gtk-theme "$mapped" >/dev/null 2>&1; then
        desktop_color_scheme_applied+=("gsettings color-scheme=prefer-$mode")
      fi
    fi
  fi

  for file in "$config_root/gtk-3.0/settings.ini" "$config_root/gtk-4.0/settings.ini"; do
    if [[ -f "$file" ]] && desktop_color_scheme_update_gtk_ini "$file" "$mode" 2>/dev/null; then
      desktop_color_scheme_applied+=("$file")
    fi
  done

  if os_name=$(uname -s 2>/dev/null) && [[ "$os_name" == Darwin ]] \
    && command -v osascript >/dev/null 2>&1; then
    if osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $prefer_dark" \
      >/dev/null 2>&1; then
      desktop_color_scheme_applied+=("macOS appearance")
    fi
  fi

  # Windows/WSL registry integration is untested here; reg.exe is optional.
  if command -v reg.exe >/dev/null 2>&1; then
    if reg.exe add "$registry_key" /v AppsUseLightTheme /t REG_DWORD /d "$use_light" /f >/dev/null 2>&1 \
      && reg.exe add "$registry_key" /v SystemUsesLightTheme /t REG_DWORD /d "$use_light" /f >/dev/null 2>&1; then
      desktop_color_scheme_applied+=("Windows AppsUseLightTheme" "Windows SystemUsesLightTheme")
    fi
  fi

  (( ${#desktop_color_scheme_applied[@]} > 0 )) && return 0
  desktop_color_scheme_error="nothing was available to apply the desktop colour scheme"
  return 1
}
