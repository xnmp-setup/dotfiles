# Generate the Claude Code theme (~/.claude/themes/desktop.json) from the
# terminal theme.
#
# Claude Code draws on the terminal's own background, so the colours come
# from the Ghostty theme file, as the Starship and lig generators' do. The
# theme is a built-in base ("dark" or "light", from the theme mode) plus
# overrides; only the user-message background is overridden, so the person's
# prompts stand out from the replies around them.
#
# That background is lifted off the terminal background toward the theme's
# bright black (palette 8), the colour themes author as their muted surface,
# so it keeps the theme's tint instead of Claude's neutral grey. It stops at
# the first step that reaches a fixed contrast against the background, which
# makes the lift look the same across themes of very different palettes.
#
# Claude Code reads custom themes from ~/.claude/themes and reloads a changed
# one live; settings.json selects this one as "custom:desktop". Where
# set-theme never runs, chezmoi's create_desktop.json provides a plain dark
# theme so that selection still resolves.

# shellcheck source=awk-colour.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/awk-colour.sh"

claude_theme_error=""

# claude_generate_theme <ghostty-theme-file> <light|dark> <name> <destination>
claude_generate_theme() {
  local theme_file="$1" theme_mode="$2" name="$3" destination="$4"
  local theme

  claude_theme_error=""

  if [[ "$theme_mode" != light && "$theme_mode" != dark ]]; then
    claude_theme_error="theme mode must be light or dark, got '$theme_mode'"
    return 1
  fi
  if [[ ! -f "$theme_file" ]]; then
    claude_theme_error="terminal theme not found: $theme_file"
    return 1
  fi
  if ! theme=$(claude_theme_from_terminal "$theme_file" "$theme_mode" "$name"); then
    claude_theme_error="$theme_file lacks a valid background or foreground"
    return 1
  fi
  claude_write_theme "$theme" "$destination"
}

# claude_write_plain_theme <light|dark> <name> <destination>
# The base theme with no overrides: what set-theme falls back to when the
# terminal theme cannot be read, so Claude's light/dark still follows the
# desktop instead of keeping the previous theme's colours.
claude_write_plain_theme() {
  local theme_mode="$1" name="$2" destination="$3"

  claude_theme_error=""
  if [[ "$theme_mode" != light && "$theme_mode" != dark ]]; then
    claude_theme_error="theme mode must be light or dark, got '$theme_mode'"
    return 1
  fi
  claude_write_theme \
    "$(printf '{\n  "name": "%s",\n  "base": "%s",\n  "overrides": {}\n}' \
      "$(claude_json_escape "$name")" "$theme_mode")" \
    "$destination"
}

# Atomic replace, so Claude's watcher never reads a half-written file.
claude_write_theme() {
  local content="$1" destination="$2" destination_dir temporary

  destination_dir=$(dirname -- "$destination")
  mkdir -p -- "$destination_dir" || {
    claude_theme_error="cannot create $destination_dir"
    return 1
  }
  temporary=$(mktemp "$destination_dir/.desktop.XXXXXX") || {
    claude_theme_error="cannot write in $destination_dir"
    return 1
  }
  # mktemp makes it 0600; a theme is ordinary config, as chezmoi creates it.
  printf '%s\n' "$content" >"$temporary" && chmod 644 -- "$temporary" &&
    mv -f -- "$temporary" "$destination" || {
    rm -f -- "$temporary"
    claude_theme_error="cannot write $destination"
    return 1
  }
}

claude_json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

# Print the theme JSON for a Ghostty theme file; exit non-zero when the
# background or foreground is missing. Pure: reads the file, writes stdout.
# Plain POSIX awk (no gawk strtonum) so it runs on macOS as well.
claude_theme_from_terminal() {
  # The name goes through ENVIRON: awk -v would undo its JSON escapes.
  claude_theme_name=$(claude_json_escape "$3") \
  awk -v mode="$2" "$awk_colour_functions"'
    # The lightest share of `toward` over bg whose contrast with bg reaches
    # min; past `toward`, on toward the foreground, for a muted colour too
    # close to the background to reach it alone. Never so far that Claude
    # message text (white on dark, black on light) falls under 7:1: on a
    # light dark-theme background the last step that kept it wins instead.
    function lift(toward, min,   p, block, last) {
      last = bg
      for (p = 0.05; p <= 1.001; p += 0.05) {
        block = mix(toward, bg, p)
        if (ratio(text, block) < 7) return last
        if (ratio(block, bg) >= min) return block
        last = block
      }
      for (p = 0.05; p < 1; p += 0.05) {
        block = mix(fg, toward, p)
        if (ratio(text, block) < 7) return last
        if (ratio(block, bg) >= min) return block
        last = block
      }
      return last
    }

    /^[ \t]*background[ \t]*=/ { v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v); bg = norm(v) }
    /^[ \t]*foreground[ \t]*=/ { v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v); fg = norm(v) }
    /^[ \t]*palette[ \t]*=[ \t]*8[ \t]*=/ {
      v = $0; sub(/^[^=]*=[ \t]*8[ \t]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
      muted = norm(v)
    }

    END {
      if (bg == "" || fg == "") exit 1
      name = ENVIRON["claude_theme_name"]
      # Bright black that barely differs from the background (some themes
      # use it as a second background) cannot lift anything; use the text.
      text = (mode == "dark") ? "ffffff" : "000000"
      toward = (muted != "" && ratio(muted, bg) >= 1.5) ? muted : fg
      # Dark backgrounds need a larger ratio for the same visible step.
      if (mode == "dark") { block = lift(toward, 1.6); hover = lift(toward, 1.9) }
      else { block = lift(toward, 1.15); hover = lift(toward, 1.3) }
      printf "{\n  \"name\": \"%s\",\n  \"base\": \"%s\",\n  \"overrides\": {\n", name, mode
      printf "    \"userMessageBackground\": \"#%s\",\n", block
      printf "    \"userMessageBackgroundHover\": \"#%s\"\n  }\n}", hover
    }
  ' "$1"
}
