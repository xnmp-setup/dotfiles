#!/usr/bin/env bash
# Machine-local desktop theme state shared by set-theme and chezmoi templates.

desktop_theme_state_file() {
  local state_root="${XDG_STATE_HOME:-${HOME}/.local/state}"
  printf '%s/desktop-theme/current.json\n' "$state_root"
}

desktop_theme_json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

desktop_theme_read_state_value() {
  local state_file="$1"
  local key="$2"
  [[ -f "$state_file" ]] || return 1

  awk -v key="$key" '
    $0 ~ "^[[:space:]]*\"" key "\"[[:space:]]*:" {
      value = $0
      sub("^[[:space:]]*\"" key "\"[[:space:]]*:[[:space:]]*\"", "", value)
      sub("\"[[:space:]]*,?[[:space:]]*$", "", value)
      print value
      exit
    }
  ' "$state_file"
}

desktop_theme_read_vicinae_name() {
  local config_file="$1"
  local variant="$2"
  [[ -f "$config_file" ]] || return 1

  awk -v variant="$variant" '
    index($0, "\"" variant "\"") { in_variant = 1 }
    in_variant && match($0, /"name"[[:space:]]*:[[:space:]]*"[^"]*"/) {
      value = substr($0, RSTART, RLENGTH)
      sub(/^"name"[[:space:]]*:[[:space:]]*"/, "", value)
      sub(/"$/, "", value)
      print value
      exit
    }
    in_variant && /}/ { exit }
  ' "$config_file"
}

desktop_theme_write_state() {
  local slug="$1"
  local title="$2"
  local mode="$3"
  local wezterm_scheme="$4"
  local vicinae_light="$5"
  local vicinae_dark="$6"
  local state_file state_dir temporary_file

  state_file=$(desktop_theme_state_file) || return
  state_dir=${state_file%/*}
  mkdir -p "$state_dir" || return
  temporary_file=$(mktemp "$state_dir/current.json.XXXXXX") || return

  if ! printf '{\n  "slug": "%s",\n  "title": "%s",\n  "mode": "%s",\n  "wezterm": "%s",\n  "vicinae_light": "%s",\n  "vicinae_dark": "%s"\n}\n' \
    "$(desktop_theme_json_escape "$slug")" \
    "$(desktop_theme_json_escape "$title")" \
    "$(desktop_theme_json_escape "$mode")" \
    "$(desktop_theme_json_escape "$wezterm_scheme")" \
    "$(desktop_theme_json_escape "$vicinae_light")" \
    "$(desktop_theme_json_escape "$vicinae_dark")" \
    > "$temporary_file"; then
    rm -f "$temporary_file"
    return 1
  fi

  if [[ -f "$state_file" ]] && cmp -s "$temporary_file" "$state_file"; then
    rm -f "$temporary_file"
    return 0
  fi

  if ! mv "$temporary_file" "$state_file"; then
    rm -f "$temporary_file"
    return 1
  fi
}
