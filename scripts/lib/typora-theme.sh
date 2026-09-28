# Generate Typora themes from the shared desktop palette and select them.
#
# Typora themes are plain stylesheets in <config root>/themes, listed in its
# Themes menu by file name. Every desktop theme gets its own "<slug>.css" so
# any of them can be picked by hand, and set-theme also rewrites a fixed
# "desktop.css" ("Desktop" in the menu) that always tracks the current theme.
#
# The fixed name exists because Typora keeps the selected theme in
# profile.data and rewrites that file from memory when it quits: an edit made
# while Typora is open is silently lost. Selecting "Desktop" once — which only
# has to happen while Typora is closed — makes every later switch a plain
# stylesheet rewrite that a running Typora picks up on its next launch.
#
# Requires theme-colors.sh (css_var, norm_hex, mix).

typora_theme_error=""
TYPORA_DESKTOP_THEME="desktop"

# Typora config roots present on this machine, one per line. Typora creates
# its root on first launch, so an absent root means "not installed here" and
# callers skip it. Linux (and Windows under its own %APPDATA%) use the
# Electron userData dir; macOS keeps themes under the bundle identifier.
typora_config_roots() {
  local root
  for root in \
    "${XDG_CONFIG_HOME:-$HOME/.config}/Typora" \
    "$HOME/Library/Application Support/abnerworks.Typora"; do
    [[ -d "$root" ]] && printf '%s\n' "$root"
  done
  return 0
}

# typora_color_mode <hex> -> "light" or "dark", by perceived brightness. This
# is the same measure Typora applies to a theme's background to pick its own
# window chrome, so the generated stylesheet and the app agree.
typora_color_mode() {
  local h
  h=$(norm_hex "$1")
  if (( (299 * 16#${h:0:2} + 587 * 16#${h:2:2} + 114 * 16#${h:4:2}) / 1000 >= 128 )); then
    echo light
  else
    echo dark
  fi
}

# ANSI colour <n> (0-15) from a Ghostty theme file, used for syntax
# highlighting. Prints nothing when the file or entry is absent.
typora_ansi_color() {
  [[ -n "$1" && -f "$1" ]] || return 0
  grep -oP -- "^\s*palette\s*=\s*$2=\K#[0-9a-fA-F]{6}" "$1" 2>/dev/null | head -1
}

# First literal colour among CSS custom properties <var>... in <file>: a hex
# colour or an rgb()/rgba() with numeric arguments. Values built from other
# variables (var(), color-mix()) are skipped rather than resolved, so a theme
# that computes a colour falls through to the next candidate or the caller's
# fallback. Prints nothing, successfully, when there is no match.
typora_css_color() {
  local file="$1" name value
  shift
  [[ -n "$file" && -f "$file" ]] || return 0
  for name in "$@"; do
    value=$(grep -oP -- "--$name:\s*\K(#[0-9a-fA-F]{3,8}\b|rgba?\([0-9., %]+\))" "$file" 2>/dev/null | head -1)
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  done
  return 0
}

# typora_find_by_slug <dir> <slug>: the entry of <dir> whose name normalises
# to <slug> ("Horizon Dark" for horizon-dark, "MapQuest" for mapquest).
typora_find_by_slug() {
  local entry name
  for entry in "$1"/*; do
    [[ -e "$entry" && "$entry" != *.css ]] || continue
    name=$(basename -- "$entry" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    if [[ "$name" == "$2" ]]; then
      printf '%s\n' "$entry"
      return 0
    fi
  done
  return 1
}

typora_ghostty_theme_for() {
  local file
  file=$(typora_find_by_slug "$HOME/.config/ghostty/themes" "$1") || return 1
  [[ -f "$file" ]] && printf '%s\n' "$file"
}

# The vault whose Obsidian themes Typora mirrors; set-theme's Obsidian section
# switches the same vault. Absent vaults and themes fall back to the palette.
TYPORA_OBSIDIAN_THEMES_DIR="${TYPORA_OBSIDIAN_THEMES_DIR:-$HOME/Vaults/Technical Vault/.obsidian/themes}"

typora_obsidian_theme_for() {
  local dir
  dir=$(typora_find_by_slug "$TYPORA_OBSIDIAN_THEMES_DIR" "$1") || return 1
  [[ -f "$dir/theme.css" ]] && printf '%s\n' "$dir/theme.css"
}

# typora_generate_theme <palette.css> <ansi-theme-file-or-empty>
#                       <obsidian-theme.css-or-empty> <slug> <dest>
#
# The palette supplies the colours every desktop app shares. Where the
# theme's Obsidian stylesheet defines the finer document details — heading,
# emphasis, link, code and highlight colours — those win, so a note looks
# the same in both editors. Terminal ANSI colours are the last resort for
# syntax highlighting.
typora_generate_theme() {
  local palette_file="$1" ansi_file="$2" obsidian_file="$3" theme_slug="$4" destination="$5"
  local bg text text_dim text_faint accent accent_light on_accent
  local critical success caution
  local mode sidebar surface raised border rule selection hover
  local red green yellow blue magenta cyan orange mermaid_import=""
  local h1 h2 h3 h4 h5 h6 bold italic link link_hover mark_bg
  local code_bg code_fg checkbox quote_border list_marker text_muted
  local syn_keyword syn_function syn_important syn_operator syn_property
  local syn_string syn_tag syn_value syn_comment syn_punctuation
  local temporary

  typora_theme_error=""

  if [[ ! -f "$palette_file" ]]; then
    typora_theme_error="palette not found: $palette_file"
    return 1
  fi

  bg=$(css_var "$palette_file" background-solid)
  text=$(css_var "$palette_file" text-primary)
  text_dim=$(css_var "$palette_file" text-secondary)
  accent=$(css_var "$palette_file" accent)
  if [[ -z "$bg" || -z "$text" || -z "$accent" ]]; then
    typora_theme_error="palette is missing a required solid color"
    return 1
  fi

  bg="#$(norm_hex "$bg")"
  text="#$(norm_hex "$text")"
  accent="#$(norm_hex "$accent")"
  [[ -n "$text_dim" ]] || text_dim="$text"
  text_dim="#$(norm_hex "$text_dim")"
  text_faint=$(css_var "$palette_file" text-tertiary)
  if [[ -n "$text_faint" ]]; then
    text_faint="#$(norm_hex "$text_faint")"
  else
    text_faint="#$(mix "$bg" "$text_dim" 60)"
  fi
  accent_light=$(css_var "$palette_file" accent-light)
  accent_light="#$(norm_hex "${accent_light:-$accent}")"
  on_accent=$(css_var "$palette_file" text-on-accent)
  on_accent="#$(norm_hex "${on_accent:-$bg}")"
  critical=$(css_var "$palette_file" system-critical)
  success=$(css_var "$palette_file" system-success)
  caution=$(css_var "$palette_file" system-caution)

  mode=$(typora_color_mode "$bg")
  surface="#$(mix "$bg" "$text" 7)"
  raised="#$(mix "$bg" "$text" 12)"
  rule="#$(mix "$bg" "$text_dim" 30)"
  hover="#$(mix "$bg" "$accent" 14)"

  # Semantic colours: Obsidian's named colours, then the terminal's ANSI
  # palette, then the desktop palette's status and accent colours.
  ob() { typora_css_color "$obsidian_file" "$@"; }
  red=$(ob color-red);       red=${red:-$(typora_ansi_color "$ansi_file" 1)};     red=${red:-${critical:-$accent}}
  green=$(ob color-green);   green=${green:-$(typora_ansi_color "$ansi_file" 2)}; green=${green:-${success:-$accent_light}}
  yellow=$(ob color-yellow); yellow=${yellow:-$(typora_ansi_color "$ansi_file" 3)}; yellow=${yellow:-${caution:-$accent_light}}
  blue=$(ob color-blue);     blue=${blue:-$(typora_ansi_color "$ansi_file" 4)};   blue=${blue:-$accent}
  magenta=$(ob color-purple); magenta=${magenta:-$(typora_ansi_color "$ansi_file" 5)}; magenta=${magenta:-$accent_light}
  cyan=$(ob color-cyan);     cyan=${cyan:-$(typora_ansi_color "$ansi_file" 6)};   cyan=${cyan:-$accent_light}
  orange=$(ob color-orange); orange=${orange:-$yellow}

  # Document details, from Obsidian where the theme defines them.
  sidebar=$(ob background-secondary);     sidebar=${sidebar:-#$(mix "$bg" "$text" 4)}
  border=$(ob background-modifier-border); border=${border:-#$(mix "$bg" "$text_dim" 22)}
  selection=$(ob text-selection);         selection=${selection:-#$(mix "$bg" "$accent" 32)}
  text_muted=$(ob text-muted);            text_muted=${text_muted:-$text_dim}
  list_marker=$(ob list-marker-color text-faint); list_marker=${list_marker:-$text_faint}
  h1=$(ob h1-color); h1=${h1:-$text}
  h2=$(ob h2-color); h2=${h2:-$text}
  h3=$(ob h3-color); h3=${h3:-$text}
  h4=$(ob h4-color); h4=${h4:-$text}
  h5=$(ob h5-color); h5=${h5:-$text}
  h6=$(ob h6-color); h6=${h6:-$text}
  bold=$(ob bold-color);     bold=${bold:-$text}
  italic=$(ob italic-color); italic=${italic:-$text}
  link=$(ob link-external-color link-color text-accent); link=${link:-$accent}
  link_hover=$(ob link-external-color-hover link-color-hover text-accent-hover)
  link_hover=${link_hover:-$accent_light}
  mark_bg=$(ob text-highlight-bg); mark_bg=${mark_bg:-$selection}
  code_bg=$(ob code-background);   code_bg=${code_bg:-$surface}
  code_fg=$(ob code-normal);       code_fg=${code_fg:-$red}
  checkbox=$(ob checkbox-color interactive-accent); checkbox=${checkbox:-$accent}
  quote_border=$(ob blockquote-border-color interactive-accent); quote_border=${quote_border:-$accent}

  # Obsidian's code-* roles and their stock defaults.
  syn_keyword=$(ob code-keyword);         syn_keyword=${syn_keyword:-$(ob color-pink)}; syn_keyword=${syn_keyword:-$magenta}
  syn_function=$(ob code-function);       syn_function=${syn_function:-$yellow}
  syn_important=$(ob code-important);     syn_important=${syn_important:-$orange}
  syn_operator=$(ob code-operator);       syn_operator=${syn_operator:-$red}
  syn_property=$(ob code-property);       syn_property=${syn_property:-$cyan}
  syn_string=$(ob code-string);           syn_string=${syn_string:-$green}
  syn_tag=$(ob code-tag);                 syn_tag=${syn_tag:-$red}
  syn_value=$(ob code-value);             syn_value=${syn_value:-$magenta}
  syn_comment=$(ob code-comment);         syn_comment=${syn_comment:-$text_faint}
  syn_punctuation=$(ob code-punctuation); syn_punctuation=${syn_punctuation:-$text_muted}
  unset -f ob

  # Typora ships a dark Mermaid palette with its bundled Night theme; a
  # missing import is ignored, so this is safe where Night was removed.
  [[ "$mode" == dark ]] && mermaid_import='@import "night/mermaid.dark.css";'

  mkdir -p "${destination%/*}" || {
    typora_theme_error="cannot create theme directory: ${destination%/*}"
    return 1
  }
  temporary=$(typora_temp_beside "$destination") || {
    typora_theme_error="cannot create temporary stylesheet"
    return 1
  }

  if ! cat >"$temporary" <<EOF
/* Generated by set-theme.sh from $theme_slug — do not edit.
   Regenerate with: set-theme $theme_slug */
$mermaid_import

:root {
  color-scheme: $mode;

  --bg-color: $bg;
  --side-bar-bg-color: $sidebar;
  --text-color: $text;
  --select-text-bg-color: $selection;
  --item-hover-bg-color: $hover;
  --item-hover-text-color: $text;
  --control-text-color: $text_dim;
  --control-text-hover-color: $text;
  --window-border: 1px solid $border;
  --active-file-bg-color: $hover;
  --active-file-text-color: $text;
  --active-file-border-color: $accent;
  --primary-color: $accent;
  --primary-btn-border-color: $accent;
  --primary-btn-text-color: $on_accent;
  --rawblock-edit-panel-bd: $surface;
  --search-select-bg-color: $accent;
  --search-select-text-color: $on_accent;
  --md-char-color: $text_faint;
  --meta-content-color: $text_faint;
  --heading-char-color: $text_faint;
  --blur-text-color: $text_faint;
  --code-block-bg-color: $code_bg;

  --theme-surface: $surface;
  --theme-raised: $raised;
  --theme-border: $border;
  --theme-rule: $rule;
  --theme-text-dim: $text_dim;
  --theme-text-muted: $text_muted;
  --theme-text-faint: $text_faint;
  --theme-accent-light: $accent_light;
  --theme-on-accent: $on_accent;

  /* Obsidian's default font stacks, so both editors resolve the same face. */
  --theme-font-text: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI",
    Roboto, "Inter", "Apple Color Emoji", "Segoe UI Emoji", "Noto Color Emoji",
    sans-serif;
  --theme-font-mono: ui-monospace, SFMono-Regular, "Cascadia Mono", "Roboto Mono",
    "DejaVu Sans Mono", "Liberation Mono", Menlo, Monaco, Consolas,
    "Source Code Pro", monospace;
}

html {
  font-size: 16px;
  -webkit-font-smoothing: antialiased;
}

html, body {
  background: var(--bg-color);
  color: var(--text-color);
  line-height: 1.5;
}

html, body, button, input, select, textarea {
  font-family: var(--theme-font-text);
}

body, button, input, select, textarea, div.code-tooltip-content {
  color: var(--text-color);
  border-color: transparent;
}

/* Obsidian's readable line width (the vault sets --file-line-width: 850px),
   plus Typora's own 30px gutters on each side. */
#write {
  max-width: 910px;
  padding-top: 40px;
}

/* ---- Document (mirrors Obsidian's reading view) ---- */

h1, h2, h3, h4, h5, h6 {
  position: relative;
  margin: 1.2em 0 0.5em;
  line-height: 1.2;
  font-weight: 600;
}
h1 { font-size: 1.802em; font-weight: 700; color: $h1; }
h2 { font-size: 1.602em; color: $h2; }
h3 { font-size: 1.424em; color: $h3; }
h4 { font-size: 1.266em; color: $h4; }
h5 { font-size: 1.125em; color: $h5; }
h6 { font-size: 1.125em; color: $h6; }
#write > h1:first-child, #write > h2:first-child { margin-top: 0.3em; }

p, blockquote, ul, ol, dl, table, pre, .md-fences { margin: 0.75em 0; }
li > ol, li > ul { margin: 0; }
li::marker { color: $list_marker; }

a, .md-def-url {
  color: $link;
  text-decoration: underline;
  text-decoration-thickness: from-font;
}
a:hover { color: $link_hover; }

strong, b, th, dt { color: $bold; font-weight: 600; }
em, i { color: $italic; }
del, s { color: var(--theme-text-faint); }

hr {
  height: 0;
  padding: 0;
  margin: 2em 0;
  border: 0;
  border-top: 2px solid var(--theme-border);
  background: none;
}

blockquote {
  padding: 0 0 0 24px;
  color: var(--text-color);
  border-left: 2px solid $quote_border;
}

mark {
  background: $mark_bg;
  color: var(--text-color);
}

::selection, *.in-text-selection {
  background: var(--select-text-bg-color);
  color: inherit;
  text-shadow: none;
}

code, tt, kbd, var, pre, .md-fences {
  font-family: var(--theme-font-mono);
}

code, tt, var {
  padding: 0.1em 0.25em;
  border-radius: 4px;
  font-size: 0.875em;
  background: $code_bg;
  color: $code_fg;
}

kbd {
  padding: 0.1em 0.4em;
  border: 1px solid var(--theme-border);
  border-bottom-width: 2px;
  border-radius: 4px;
  font-size: 0.875em;
  background: $code_bg;
  color: var(--text-color);
}

.md-fences, pre.md-fences {
  padding: 12px 16px;
  border: none;
  border-radius: 4px;
  font-size: 0.875em;
  background: var(--code-block-bg-color);
}

.md-fences .code-tooltip { background: var(--theme-raised); }

table { border-collapse: collapse; }
th, td { padding: 4px 8px; border: 1px solid var(--theme-border); }
th { text-align: start; }

.md-task-list-item > input {
  margin-top: 0.3em;
  accent-color: $checkbox;
}
.md-task-list-item.task-list-done { color: var(--theme-text-muted); text-decoration: line-through; }

img { border-radius: 4px; }

sup.md-footnote {
  padding: 0 4px;
  border-radius: 4px;
  background: $code_bg;
  color: $link;
}

.md-toc-item, .md-toc-content a { color: $link; }

#write pre.md-meta-block {
  padding: 12px 16px;
  border-radius: 4px;
  background: $code_bg;
  color: var(--theme-text-muted);
}

.md-image > .md-meta, .md-link .md-meta, .md-meta, .md-before, .md-after {
  color: var(--md-char-color);
  font-family: inherit;
}
.md-comment { color: var(--theme-text-faint); }
.md-inline-math script, .md-inline-math svg { color: var(--text-color); }
.md-mathjax-midline { background: var(--theme-surface); border-bottom: none; }
.md-diagram-panel-error { color: $red; }

.md-alert-text-note { color: $blue; }
.md-alert-text-tip { color: $green; }
.md-alert-text-important { color: $magenta; }
.md-alert-text-warning { color: $orange; }
.md-alert-text-caution { color: $red; }

.md-search-hit { background: $mark_bg; color: var(--text-color); }
.md-search-hit * { color: var(--text-color); }
.md-search-select, .md-search-select * {
  background: var(--search-select-bg-color);
  color: var(--search-select-text-color);
}

/* ---- Code (CodeMirror), mapped onto Obsidian's code-* roles ---- */

.cm-s-inner.CodeMirror, .cm-s-inner .CodeMirror-gutters {
  background: transparent;
  color: var(--text-color);
  border: none;
}
.cm-s-inner .CodeMirror-linenumber { color: var(--theme-text-faint); }
.cm-s-inner .CodeMirror-cursor { border-left-color: var(--text-color); }
.cm-s-inner .CodeMirror-selected,
.cm-s-inner .CodeMirror-selectedtext { background: var(--select-text-bg-color); }
.cm-s-inner .CodeMirror-matchingbracket { color: $syn_string !important; text-decoration: underline; }

.cm-s-inner .cm-keyword { color: $syn_keyword; }
.cm-s-inner .cm-def { color: $syn_function; }
.cm-s-inner .cm-builtin,
.cm-s-inner .cm-variable-3,
.cm-s-inner .cm-type { color: $syn_important; }
.cm-s-inner .cm-operator { color: $syn_operator; }
.cm-s-inner .cm-property,
.cm-s-inner .cm-attribute,
.cm-s-inner .cm-meta,
.cm-s-inner .cm-qualifier { color: $syn_property; }
.cm-s-inner .cm-string,
.cm-s-inner .cm-string-2 { color: $syn_string; }
.cm-s-inner .cm-tag { color: $syn_tag; }
.cm-s-inner .cm-atom,
.cm-s-inner .cm-number { color: $syn_value; }
.cm-s-inner .cm-comment { color: $syn_comment; }
.cm-s-inner .cm-bracket,
.cm-s-inner .cm-punctuation { color: $syn_punctuation; }
.cm-s-inner .cm-variable,
.cm-s-inner .cm-variable-2 { color: var(--text-color); }
.cm-s-inner .cm-header { color: $h1; font-weight: bold; }
.cm-s-inner .cm-quote { color: $syn_string; }
.cm-s-inner .cm-hr { color: var(--theme-text-faint); }
.cm-s-inner .cm-link { color: $link; }
.cm-s-inner .cm-url { color: $blue; }
.cm-s-inner .cm-error,
.cm-s-inner .cm-negative { color: $red; }
.cm-s-inner .cm-positive { color: $green; }

/* Source-code mode uses the same editor with a different wrapper. */
#typora-source .CodeMirror-gutters { background: var(--bg-color); border: none; }
#typora-source .cm-header { color: $h1; }
#typora-source .cm-header-2 { color: $h2; }
#typora-source .cm-header-3 { color: $h3; }
#typora-source .cm-header-4 { color: $h4; }
#typora-source .cm-header-5 { color: $h5; }
#typora-source .cm-header-6 { color: $h6; }
#typora-source .cm-strong { color: $bold; }
#typora-source .cm-em { color: $italic; }
#typora-source .cm-link, #typora-source .cm-url { color: $link; }
#typora-source .cm-comment { color: $code_fg; }
#typora-source .cm-quote { color: var(--theme-text-muted); }
#typora-source .cm-formatting { color: var(--md-char-color); }

/* ---- Focus mode ---- */

.on-focus-mode .md-end-block:not(.md-focus):not(.md-focus-container) *,
.on-focus-mode li[cid]:not(.md-focus-container),
.on-focus-mode .CodeMirror.cm-s-inner:not(.CodeMirror-focused) *,
.on-focus-mode .md-fences.md-focus .CodeMirror-code > *:not(.CodeMirror-activeline) *,
.on-focus-mode #typora-source .CodeMirror-code > *:not(.CodeMirror-activeline) * {
  color: var(--theme-text-faint) !important;
}
.on-focus-mode .md-focus, .on-focus-mode .md-focus-container { color: var(--text-color); }

/* ---- Application chrome ---- */

#typora-sidebar, .sidebar-content, .sidebar-menu, #sidebar-files-menu {
  background: var(--side-bar-bg-color);
  color: var(--control-text-color);
}
#typora-sidebar { border-right: 1px solid var(--theme-border); box-shadow: none; }
.sidebar-tabs { border-bottom: 1px solid var(--theme-border); }
.outline-item:hover, .file-list-item:hover,
.file-tree-node:not(.active) > .file-node-background:hover {
  background: var(--item-hover-bg-color);
  color: var(--item-hover-text-color);
}
.file-list-item { border-bottom: 1px solid var(--theme-border); }
.file-list-item.active,
.file-library-node.active > .file-node-background {
  background: var(--active-file-bg-color);
  border-color: var(--active-file-border-color);
}
.file-library-node.active > .file-node-content,
.file-list-item.active { color: var(--active-file-text-color); }
.file-list-item-summary, .file-list-item-time { color: var(--theme-text-faint); }
.file-node-expanded > .file-node-children { display: grid; }

.active-tab-files #info-panel-tab-file,
.active-tab-outline #info-panel-tab-outline,
.ty-side-sort-btn.active, .ty-side-sort-btn:hover,
.sidebar-footer-item:hover, .footer-item:hover {
  color: var(--primary-color);
  background: inherit;
}

footer.ty-footer, #footer-word-count-info {
  border-color: var(--theme-border);
  background: var(--bg-color);
  color: var(--control-text-color);
}

.typora-sourceview-on #toggle-sourceview-btn,
#toggle-sourceview-btn:hover,
#footer-word-count:hover,
.ty-show-word-count #footer-word-count {
  background: var(--theme-surface);
  color: var(--text-color);
}

#top-titlebar, #top-titlebar * { color: var(--control-text-color); }
.megamenu-content, .megamenu-opened header { background: var(--bg-color); }
.megamenu-menu-panel h1, .megamenu-menu-panel h2, .long-btn { color: var(--text-color); }
.megamenu-menu-panel .dropdown-menu > li > a {
  background: var(--theme-surface);
  color: inherit;
  text-decoration: none;
}
.megamenu-menu-panel input[type='text'] {
  background: inherit;
  border: 0;
  border-bottom: 1px solid var(--theme-border);
}
#recent-file-panel tbody tr:nth-child(2n-1) { background: transparent !important; }

.context-menu, .dropdown-menu, #spell-check-panel, #toc-dropmenu,
.auto-suggest-container, #typora-quick-open, #md-notification,
.popover, .ty-editor-toolbar, #ty-tooltip, div.code-tooltip,
.md-table-resize-popover, #math-inline-preview, .md-hover-tip .md-arrow:after {
  background: var(--theme-raised);
  color: var(--text-color);
  border: 1px solid var(--theme-border);
}
.ty-editor-toolbar { --text-color: $text; }
.popover.bottom > .arrow:after { border-bottom-color: var(--theme-raised); }
.dropdown-menu .divider, .context-menu .divider { background: var(--theme-border); opacity: 1; }
.dropdown-menu > li > a, .context-menu a { color: var(--text-color); }
.dropdown-menu > li > a:hover, .dropdown-menu > li > a:focus,
.dropdown-menu .btn:hover, .dropdown-menu .btn:focus,
.context-menu a:hover, .context-menu a:focus,
.typora-quick-open-item:hover, .typora-quick-open-item.active,
.auto-suggest-container li.active {
  background: var(--item-hover-bg-color);
  color: var(--item-hover-text-color);
}
.typora-quick-open-item { background: inherit; color: inherit; }
#typora-quick-open input {
  background: var(--theme-surface);
  color: var(--text-color);
  border: 0;
  border-bottom: 1px solid var(--theme-border);
}
.typora-search-spinner > div { background: var(--text-color); }

#md-searchpanel { border-bottom: 1px solid var(--theme-border); background: var(--bg-color); }
#md-searchpanel input, .form-control, .ty-preferences input, .ty-preferences select,
.modal-content input, .input-group-addon {
  background: var(--theme-surface);
  color: var(--text-color);
  border-color: var(--theme-border);
}

.modal-content, .ty-preferences, .ty-preferences .window,
.ty-preferences .sidebar, .ty-preferences .content {
  background: var(--bg-color);
  color: var(--text-color);
  border-color: var(--theme-border);
}
.modal-header, .modal-footer { border-color: var(--theme-border); }
.modal-backdrop { background: rgba(0, 0, 0, 0.45); }
.ty-preferences .nav-group-item.active, .export-item.active,
.export-items-list-control, .export-detail {
  background: var(--item-hover-bg-color);
}

.btn, .btn-default { background: transparent; color: var(--text-color); }
.btn-default:hover, .btn-default:focus, .btn-default:active,
.open > .dropdown-toggle.btn-default {
  background: var(--item-hover-bg-color);
  color: var(--text-color);
  border-color: var(--theme-border);
}
.btn-primary, .btn-primary:hover {
  background: var(--primary-color);
  border-color: var(--primary-color);
  color: var(--primary-btn-text-color);
}

.ty-table-edit { background: var(--bg-color); border-top: 1px solid var(--theme-border); }

::-webkit-scrollbar-thumb,
.typora-node::-webkit-scrollbar-thumb:vertical {
  background: var(--theme-rule);
  border-radius: 4px;
}
::-webkit-scrollbar-thumb:active,
.typora-node::-webkit-scrollbar-thumb:vertical:active {
  background: var(--theme-text-faint);
}
EOF
  then
    rm -f -- "$temporary"
    typora_theme_error="cannot write temporary stylesheet"
    return 1
  fi

  if ! chmod 644 "$temporary" || ! mv -f -- "$temporary" "$destination"; then
    rm -f -- "$temporary"
    typora_theme_error="cannot install stylesheet: $destination"
    return 1
  fi
}

# typora_publish_desktop <themes-dir> <slug>: atomically make the Desktop
# theme a copy of "<slug>.css". Typora may read it at any moment.
typora_publish_desktop() {
  local source="$1/$2.css" destination="$1/$TYPORA_DESKTOP_THEME.css" temporary
  temporary=$(typora_temp_beside "$destination") || return 1
  if ! cp -- "$source" "$temporary" || ! chmod 644 "$temporary" \
    || ! mv -f -- "$temporary" "$destination"; then
    rm -f -- "$temporary"
    return 1
  fi
}

# A hidden temporary file next to <path>, so an interrupted write can neither
# replace the target with a partial file nor appear in Typora's Themes menu.
typora_temp_beside() {
  local dir="${1%/*}" base="${1##*/}"
  mktemp "$dir/.$base.XXXXXX"
}

# typora_theme_running -> success while a Typora process is alive.
typora_theme_running() {
  command -v pgrep &>/dev/null && pgrep -x Typora &>/dev/null
}

# profile.data is the JSON settings object, hex-encoded as ASCII.
typora_profile_decode() {
  local hex
  hex=$(tr -d '[:space:]' <"$1") || return 1
  [[ -n "$hex" && "$hex" =~ ^([0-9a-fA-F]{2})+$ ]] || return 1
  printf '%b' "$(sed 's/../\\x&/g' <<<"$hex")"
}

typora_profile_encode() {
  od -An -v -tx1 | tr -d ' \n'
}

# typora_select_theme <profile.data> <theme-name> <background-hex>
#
# Point Typora at "<theme-name>.css" and record the theme's background and
# brightness, which Typora uses to paint the window before the stylesheet
# loads. Refuses while Typora runs, because the running app overwrites the
# file on exit. Returns 2 in that case so callers can tell "not now" from
# "broken".
typora_select_theme() {
  local profile="$1" theme_name="$2" background="$3"
  local json updated temporary is_dark=false

  typora_theme_error=""

  if [[ ! -f "$profile" ]]; then
    typora_theme_error="no profile at $profile; launch Typora once"
    return 1
  fi
  if ! command -v jq &>/dev/null; then
    typora_theme_error="jq not installed"
    return 1
  fi
  if typora_theme_running; then
    typora_theme_error="Typora is running and would overwrite its profile on exit"
    return 2
  fi
  if ! json=$(typora_profile_decode "$profile") \
    || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$json"; then
    typora_theme_error="unreadable profile: $profile"
    return 1
  fi

  [[ "$(typora_color_mode "$background")" == dark ]] && is_dark=true
  if ! updated=$(jq -c \
    --arg theme "$theme_name.css" \
    --arg bg "#$(norm_hex "$background" | tr '[:lower:]' '[:upper:]')" \
    --argjson dark "$is_dark" \
    '.theme = $theme | .backgroundColor = $bg | .isDarkMode = $dark' <<<"$json"); then
    typora_theme_error="could not update profile JSON"
    return 1
  fi

  temporary=$(typora_temp_beside "$profile") || {
    typora_theme_error="cannot create temporary profile"
    return 1
  }
  # Typora creates its profile 644; mktemp's 600 would silently tighten it.
  if ! printf '%s' "$updated" | typora_profile_encode >"$temporary" \
    || ! chmod 644 "$temporary" \
    || ! mv -f -- "$temporary" "$profile"; then
    rm -f -- "$temporary"
    typora_theme_error="cannot write profile: $profile"
    return 1
  fi
}

# typora_selected_theme <profile.data> -> the selected theme file name, if any.
typora_selected_theme() {
  local json
  json=$(typora_profile_decode "$1" 2>/dev/null) || return 1
  jq -r '.theme // empty' <<<"$json" 2>/dev/null
}
