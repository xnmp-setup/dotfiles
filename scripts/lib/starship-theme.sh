# Generate the Starship prompt palette (~/.config/starship/palette.toml) from
# the terminal theme.
#
# The prompt's blocks have to sit on the terminal's own colours, so the palette
# comes from the Ghostty theme file (background, foreground, ANSI 1-6) rather
# than the tauri stylesheet the desktop generators use. Starship has no include
# directive: ~/.config/zsh/starship-theme.zsh splices this file into a copy of
# ~/.config/starship.toml, so the layout stays in chezmoi and only the colours
# are generated.
#
# Two looks, chosen by theme mode:
#   light  "tinted": a 20% wash of each colour over the background, with the
#          text in that colour.
#   dark   "dusk":   each colour mixed 60/40 with the background, with text in
#          the background colour, or the theme's foreground where the block
#          is too dark for that.
# Either way a text colour that falls short of WCAG 4.5:1 on its block is
# pushed toward black or white until it reaches it.

starship_theme_error=""

# starship_generate_palette <ghostty-theme-file> <light|dark> <destination>
starship_generate_palette() {
  local theme_file="$1"
  local theme_mode="$2"
  local destination="$3"
  local destination_dir temporary palette

  starship_theme_error=""

  if [[ ! -f "$theme_file" ]]; then
    starship_theme_error="terminal theme not found: $theme_file"
    return 1
  fi
  if [[ "$theme_mode" != light && "$theme_mode" != dark ]]; then
    starship_theme_error="theme mode must be light or dark, got '$theme_mode'"
    return 1
  fi

  if ! palette=$(starship_palette_from_theme "$theme_file" "$theme_mode"); then
    starship_theme_error="$theme_file lacks a background, foreground or colours 1-6"
    return 1
  fi

  destination_dir=$(dirname -- "$destination")
  mkdir -p -- "$destination_dir" || {
    starship_theme_error="cannot create $destination_dir"
    return 1
  }
  temporary=$(mktemp "$destination_dir/.palette.XXXXXX") || {
    starship_theme_error="cannot write in $destination_dir"
    return 1
  }
  printf '%s\n' "$palette" >"$temporary" && mv -f -- "$temporary" "$destination" || {
    rm -f -- "$temporary"
    starship_theme_error="cannot write $destination"
    return 1
  }
}

# Print the [palettes.theme] table for a Ghostty theme file; exit non-zero
# when a required colour is missing. Pure: reads the file, writes stdout.
# Plain POSIX awk (no gawk strtonum) so it runs on macOS as well.
starship_palette_from_theme() {
  awk -v mode="$2" '
    function hexdigit(c) { return index("0123456789abcdef", tolower(c)) - 1 }
    function chan(h, i) { return hexdigit(substr(h, i, 1)) * 16 + hexdigit(substr(h, i + 1, 1)) }
    function norm(v) {
      sub(/^#/, "", v)
      if (v !~ /^[0-9A-Fa-f]+$/) return ""
      if (length(v) == 3) v = substr(v,1,1) substr(v,1,1) substr(v,2,1) substr(v,2,1) substr(v,3,1) substr(v,3,1)
      return (length(v) == 6) ? tolower(v) : ""
    }
    function hex(r, g, b) { return sprintf("%02x%02x%02x", int(r + 0.5), int(g + 0.5), int(b + 0.5)) }
    # mix(a, b, p): p is the share of a.
    function mix(a, b, p) {
      return hex(chan(a,1) * p + chan(b,1) * (1 - p), chan(a,3) * p + chan(b,3) * (1 - p), chan(a,5) * p + chan(b,5) * (1 - p))
    }
    function lin(v) { v = v / 255; return (v <= 0.03928) ? v / 12.92 : ((v + 0.055) / 1.055) ^ 2.4 }
    function lum(h) { return 0.2126 * lin(chan(h,1)) + 0.7152 * lin(chan(h,3)) + 0.0722 * lin(chan(h,5)) }
    function ratio(x, y,   a, b, t) {
      a = lum(x); b = lum(y)
      if (a < b) { t = a; a = b; b = t }
      return (a + 0.05) / (b + 0.05)
    }
    # Text on a block, moved toward black or white until it reads at 4.5:1.
    function extreme(block) { return (ratio("000000", block) >= ratio("ffffff", block)) ? "000000" : "ffffff" }
    function legible(text, block,   end, p, t) {
      if (ratio(text, block) >= 4.5) return text
      end = extreme(block)
      for (p = 0.95; p > 0; p -= 0.05) {
        t = mix(text, end, p)
        if (ratio(t, block) >= 4.5) return t
      }
      return end
    }
    function role(name, colour,   block, text) {
      if (mode == "light") { block = mix(colour, bg, 0.20); text = legible(colour, block) }
      else {
        # Dark text where it reads; on a deeper block, the theme foreground,
        # so a dark colour never gets dragged through grey toward white.
        block = mix(colour, bg, 0.60)
        if (ratio(bg, block) >= 4.5) text = bg
        else if (ratio(fg, block) >= 4.5) text = fg
        else text = legible((extreme(block) == "000000") ? bg : fg, block)
      }
      printf "%s_bg = \"#%s\"\n%s_fg = \"#%s\"\n", name, block, name, text
    }

    /^[ \t]*background[ \t]*=/ { v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v); bg = norm(v) }
    /^[ \t]*foreground[ \t]*=/ { v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v); fg = norm(v) }
    /^[ \t]*palette[ \t]*=[ \t]*[0-9]+[ \t]*=/ {
      v = $0; sub(/^[^=]*=[ \t]*/, "", v)
      n = v; sub(/[ \t]*=.*/, "", n)
      sub(/^[0-9]+[ \t]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
      c[n + 0] = norm(v)
    }

    END {
      if (bg == "" || fg == "") exit 1
      for (i = 1; i <= 6; i++) if (c[i] == "") exit 1
      print "# Generated by set-theme (scripts/lib/starship-theme.sh); edits are overwritten."
      print "[palettes.theme]"
      role("dir", c[4]); role("branch", c[2]); role("sync", c[3])
      role("lang", c[6]); role("err", c[1]); role("dur", c[5])
      printf "char_ok = \"#%s\"\nchar_err = \"#%s\"\n", c[2], c[1]
    }
  ' "$1"
}
