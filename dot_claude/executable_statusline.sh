#!/usr/bin/env bash
# Wrapper around ccstatusline that recolors the context bar based on usage %.
# ccstatusline reads JSON from stdin, so we tee stdin to it.

# Force a wide effective width so ccstatusline never truncates the line.
# Truncation clips the (last) context bar mid-draw and appends "...", which
# (a) breaks the rebuild_context_bar regex below and (b) strips the "(N%)"
# the color picker greps for. The bar width is fixed (16 chars) regardless of
# this value, so a large width only prevents truncation — no visual downside.
# CCSTATUSLINE_WIDTH is checked first in ccstatusline's width probe and wins.
OUTPUT=$(cat | CCSTATUSLINE_WIDTH=1000 bunx -y ccstatusline@latest 2>/dev/null)

# Extract the percentage from the context bar, e.g. "(15%)"
PCT=$(echo "$OUTPUT" | grep -oE '\([0-9]+%\)' | head -1 | tr -dc '0-9')
PCT="${PCT:-0}"

# Pick color based on compaction proximity (ansi256 codes to match colorLevel 2)
if [ "$PCT" -lt 45 ]; then
  # Green (ansi256 78, a teal-green — git branch uses 155)
  NEW_FG='\x1b[38;5;78m'
elif [ "$PCT" -lt 70 ]; then
  # Yellow
  NEW_FG='\x1b[38;5;227m'
else
  # Red (autocompaction at 80%)
  NEW_FG='\x1b[38;5;203m'
fi

ESC=$(printf '\x1b')

echo "$OUTPUT" \
  | sed \
      -e "s/${ESC}\[38;5;203m/${NEW_FG}/g" \
      -e 's|\.\.\./||g' \
  | python3 -c '
import sys, re

FAMILIES = ("Opus", "Sonnet", "Haiku", "Fable")

def shorten_model(text):
    lo = text.lower()
    for name in FAMILIES:
        if name.lower() in lo:
            return name
    return text

BG_EMPTY = "238"  # gray bg for empty portion (lighter than 236, keeps contrast)
FG_ON_FILL = "0"  # black text on the bright filled portion

def rebuild_context_bar(m):
    """Replace [████░░░░] Xk/Yk (N%) with a text-inside-bar using bg colors."""
    fg_code = m.group(1)  # the ansi256 fg color code number
    bar = m.group(2)      # e.g. ████████░░░░░░░░
    label = m.group(3)    # e.g. 203k/1.0M (20%)

    filled = bar.count("█")
    bar_width = filled + bar.count("░")
    if bar_width == 0:
        return m.group(0)

    proportion = filled / bar_width

    # Reformat label "203k/1.0M (20%)" -> "20% of 1.0M".
    mm = re.search(r"/\s*([0-9.]+[kKmM]?)\s*\((\d+)%\)", label)
    if mm:
        total, pct = mm.group(1), mm.group(2)
        label = f"{pct}% of {total}"
    else:
        # Fallback: just shorten 1000k -> 1m if the format is unexpected.
        label = re.sub(r"(\d+)000k", r"\g<1>m", label)

    # Constant-width bar (20 chars), independent of label length.
    full_width = 20

    # Pad label to full width, centered
    text = label.center(full_width)

    # Split at the proportional fill point
    split = round(proportion * full_width)
    text_filled = text[:split]
    text_empty = text[split:]

    fg_num = int(fg_code) if fg_code else 203

    # Remap the bar color (used for both the fill block and the empty-portion
    # text) for better contrast on the grey bg. Red (203) is left as-is.
    BAR_FG = {78: 114, 227: 221}
    bar_fg = BAR_FG.get(fg_num, fg_num)

    # Filled: bg is the bar color, text is black
    # Empty: grey bg, text in the bar color
    result = ""
    if text_filled:
        result += f"\x1b[48;5;{bar_fg};38;5;{FG_ON_FILL}m{text_filled}"
    if text_empty:
        result += f"\x1b[48;5;{BG_EMPTY};38;5;{bar_fg}m{text_empty}"
    result += "\x1b[0m"
    return result

SEP = " | "  # separator used by ccstatusline (can be NBSP or regular space)
NBSP_SEP = "\xa0|\xa0"

for line in sys.stdin:
    # strip "no git" and the orphaned separator+color it leaves behind
    line = line.replace("⎇\xa0no\xa0git", "")
    line = re.sub(r"\x1b\[38;5;\d+m\x1b\[39m\xa0\|\xa0", "", line)
    # shorten model name to just the family and recolor orange
    # model uses color 30 (dark teal) from ccstatusline
    MODEL_COLORS = {"Opus": "208", "Sonnet": "216", "Haiku": "223", "Fable": "204"}
    def recolor_model(m2):
        name = shorten_model(m2.group(1))
        color = MODEL_COLORS.get(name, "208")
        return f"\x1b[38;5;{color}m{name}"
    line = re.sub(r"\x1b\[38;5;30m([^\x1b]+)", recolor_model, line)
    # remove separator: cwd | branch (after \e[49m, before \e[38;5;155m⎇)
    line = re.sub(r"(\x1b\[49m)\xa0\|\xa0(\x1b\[38;5;\d+m⎇)", r"\1 \2", line)
    # remove separator: model | bar (before \e[38;5;Nm[ where [ starts the bar)
    line = re.sub(r"\xa0\|\xa0(\x1b\[38;5;\d+m\[)", r" \1", line)
    # 1000k -> 1m (for parts outside the context bar)
    line = re.sub(r"(\d+)000k", r"\g<1>m", line)
    # rebuild context bar: match \e[38;5;Nm[████░░░░] Xk/Yk (N%)\e[39m
    line = re.sub(
        r"\x1b\[38;5;(\d+)m\[([█░]+)\]\s+([^\x1b]+)\x1b\[39m",
        rebuild_context_bar,
        line
    )
    sys.stdout.write(line)
'
