# Scrivo (~/Repos/TyporaClone) consumes this catalog before its first paint.
# Uses the existing desktop palettes and preserves already installed CSS files.
scrivo_theme_error=""

scrivo_generate_theme() {
  local palette="$1" slug="$2" destination="$3"
  local bg fg muted accent surface border on_accent mode temporary token value
  local error_color string_color number_color
  scrivo_theme_error=""
  for token in background-solid text-primary text-secondary accent; do
    value=$(css_var "$palette" "$token")
    if [[ ! "$value" =~ ^#([[:xdigit:]]{3}|[[:xdigit:]]{6})$ ]]; then
      scrivo_theme_error="missing or invalid $token in $palette"
      return 1
    fi
  done
  bg=$(css_var "$palette" background-solid)
  fg=$(css_var "$palette" text-primary)
  muted=$(css_var "$palette" text-secondary)
  accent=$(css_var "$palette" accent)
  error_color=$(css_var "$palette" system-critical || true)
  string_color=$(css_var "$palette" system-success || true)
  number_color=$(css_var "$palette" system-caution || true)
  [[ "$error_color" =~ ^#([[:xdigit:]]{3}|[[:xdigit:]]{6})$ ]] || error_color="$accent"
  [[ "$string_color" =~ ^#([[:xdigit:]]{3}|[[:xdigit:]]{6})$ ]] || string_color="$accent"
  [[ "$number_color" =~ ^#([[:xdigit:]]{3}|[[:xdigit:]]{6})$ ]] || number_color="$accent"
  surface=$(desktop_color "$palette" desktop-surface "$bg" "$fg" 10)
  border=$(desktop_color "$palette" desktop-border "$bg" "$muted" 28)
  on_accent=$(pick_readable "$accent" "$bg" "$fg")
  mode=dark
  grep -qE 'color-scheme:[[:space:]]*light' "$palette" && mode=light
  mkdir -p -- "${destination%/*}" || return 1
  temporary=$(mktemp "$destination.XXXXXX") || return 1
  if ! cat >"$temporary" <<EOF
/* Desktop palette: $slug. Compatible with Scrivo and Obsidian variables. */
:root, .theme-dark, .theme-light {
  color-scheme: $mode;
  --background-primary: $bg;
  --background-secondary: #$surface;
  --background-secondary-alt: #$surface;
  --background-modifier-border: #$border;
  --text-normal: $fg;
  --text-title: $fg;
  --text-muted: $muted;
  --text-faint: $muted;
  --interactive-accent: $accent;
  --text-accent: $accent;
  --text-on-accent: #$on_accent;
  --text-selection: #$(mix "$bg" "$accent" 30);
  --caret-color: $fg;
  --code-background: #$surface;
  --blockquote-border-color: $accent;
  --table-row-alt-background: #$surface;
  --text-error: $error_color;
  --overlay: rgba($(rgb_triplet "$bg"), 0.65);
  --shadow: 0 8px 30px rgba($(rgb_triplet "$bg"), 0.5);
  --find-match: #$(mix "$bg" "$accent" 30);
  --find-current: #$(mix "$bg" "$accent" 55);
  --tok-keyword: $accent;
  --tok-string: $string_color;
  --tok-number: $number_color;
  --tok-comment: $muted;
  --tok-function: $accent;
  --tok-type: $accent;
  --tok-property: $fg;
  --tok-operator: $fg;
  --tok-meta: $muted;
}
EOF
  then
    rm -f -- "$temporary"
    return 1
  fi
  mv -- "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
}

scrivo_apply_theme() {
  local palettes="$1" root="$2" slug="$3" mode="$4"
  local palette name title css entries temporary
  scrivo_theme_error=""
  command -v jq >/dev/null || { scrivo_theme_error="jq not installed"; return 1; }
  [[ "$slug" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ && "$mode" =~ ^(light|dark)$ ]] \
    || { scrivo_theme_error="invalid theme or mode"; return 1; }
  [[ -f "$palettes/$slug.css" ]] \
    || { scrivo_theme_error="palette not found: $palettes/$slug.css"; return 1; }
  mkdir -p -- "$root/themes" || return 1
  for palette in "$palettes/"*.css; do
    [[ -f "$palette" ]] || continue
    name=$(basename -- "$palette" .css)
    [[ -f "$root/themes/$name.css" ]] && continue
    scrivo_generate_theme "$palette" "$name" "$root/themes/$name.css" || return 1
  done
  entries=$(mktemp "$root/catalog.XXXXXX") || return 1
  temporary=$(mktemp "$root/desktop-theme.json.XXXXXX") || { rm -f -- "$entries"; return 1; }
  for palette in "$palettes/"*.css; do
    [[ -f "$palette" ]] || continue
    name=$(basename -- "$palette" .css)
    css="$root/themes/$name.css"
    title=$(sed -nE 's/.*--theme-name:[[:space:]]*"([^"]+)";.*/\1/p' "$palette" | head -1)
    [[ -n "$title" ]] || title=$(printf '%s' "$name" | tr '-' ' ' | sed 's/\b\(.\)/\u\1/g')
    if ! jq -n --arg id "builtin:desktop:$name" --arg name "$title" --rawfile css "$css" \
      '{id: $id, name: $name, css: $css}' >>"$entries"; then
      rm -f -- "$entries" "$temporary"
      scrivo_theme_error="cannot read theme: $css"
      return 1
    fi
  done
  if ! jq -s --arg theme "builtin:desktop:$slug" --arg mode "$mode" \
    '{themes: ., theme: $theme, mode: $mode}' "$entries" >"$temporary"; then
    rm -f -- "$entries" "$temporary"
    return 1
  fi
  rm -f -- "$entries"
  # Match the native loader's contract before publishing. A damaged preserved
  # stylesheet must not make set-theme report success for an unusable catalog.
  if (( $(wc -c <"$temporary") > 4 * 1024 * 1024 )) || ! jq -e '
    (.themes | length > 0 and length <= 64) and
    ([.themes[].id] | length == (unique | length)) and
    any(.themes[]; .id == $theme) and
    all(.themes[];
      (.id | test("^builtin:desktop:[a-z0-9-]+$") and utf8bytelength <= 100) and
      (.name | utf8bytelength > 0 and utf8bytelength <= 100) and
      (.css | test("\\S") and utf8bytelength <= 1048576))
  ' --arg theme "builtin:desktop:$slug" "$temporary" >/dev/null; then
    rm -f -- "$temporary"
    scrivo_theme_error="invalid or oversized theme catalog; check $root/themes (CSS must be nonempty and at most 1 MiB)"
    return 1
  fi
  mv -- "$temporary" "$root/desktop-theme.json" || { rm -f -- "$temporary"; return 1; }
}
