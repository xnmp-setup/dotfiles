// enter-ripple.glsl  —  newline flash
//
// On Enter, a soft horizontal glow flashes across the cursor's line and fades
// over DURATION. Color is read live from the active theme via
// iCurrentCursorColor (rose in Cosmic Dusk); swap for iForegroundColor to use
// the text color.
//
// Why it can't tell apps apart:
//   Ghostty exposes NO uniform for the alternate screen, the foreground process,
//   or "am I at a shell prompt" — only cursor position/color, time, resolution,
//   and the rendered texture. A shell, Claude Code, and an editor like micro are
//   pixel-identical to this shader, and the shader can't be toggled per-window at
//   runtime either. So "flash in the shell, stay dark in micro" can only be
//   approximated from the one thing we do see: how the cursor moved.
//
// The gate — two motions keep the flash alive, the rest kill it:
//   1. NEW LINE: cursor drops a row AND the column jumps. The column jump is what
//      separates an Enter (lands at a fresh prompt, a different column) from
//      in-place vertical navigation like an editor's arrow keys (column held).
//   2. PROMPT REDRAW: the shell repaints its prompt by sweeping the cursor
//      RIGHTWARD from the start of a fresh line. Keeping this alive is what lets
//      the fade outlast a command's output — without it the flash dies the
//      instant output starts printing.
//
//   Direction is the crucial tell for case 2. The shell's prompt redraw moves
//   RIGHT from the left margin; the things you DON'T want to flash on — Home,
//   Ctrl+Left (word back), Ctrl+Backspace (delete word) — are the LEFTWARD twin
//   of that move. So we keep rightward-from-margin and drop everything leftward.
//
//   Suppressed: typing/backspace (small shift); leftward edits (Home, word-back,
//   word-delete); any upward move; in-place vertical nav (column held).
//   Flashes / kept alive: shell Enter, scrolling output lines, and the prompt
//   repainting after a command.
//   Known leaks (accepted — indistinguishable by motion alone): pressing Enter to
//   insert a newline inside an editor; arrowing onto a much shorter line; pasting
//   a long string at a short prompt. Empty Enter (no text typed) won't flash —
//   the column doesn't move.
//
// Timing: iTimeCursorChange resets on EVERY cursor move and there's no
//   cross-frame memory, so brightness is decay-only (MAXIMAL at the move, only
//   fading). A follow-up kept move (output line, prompt redraw) refreshes it to
//   full rather than cutting it short, so the fade completes while you sit idle.
//
// Requires:  custom-shader-animation = true
//
// Cursor uniforms: pixels, origin bottom-left, +Y up; .xy = top-left corner,
// .zw = cell width/height.  (fragCoord shares this origin.)

// ---- tunables --------------------------------------------------------------
const float DURATION  = 0.50;   // fade-out length, seconds
const float HOLD      = 0.20;   // fraction of DURATION held at full before fading
const float INTENSITY = 0.18;   // brightness of the glow (subtle)
const float HEIGHT    = 0.90;   // band height, in cell-heights
// Motion gate (all distances in cell-heights — see note below).
const float MIN_SHIFT   = 1.5;  // min column jump to count as a new line / prompt sweep (~3 cols)
const float LEFT_MARGIN = 3.0;  // a prompt redraw must START this close to the left edge (~6 cols)
// DEBUG: flash on EVERY cursor move (ungated), colored by direction, to learn
// what an action actually does:
//   CYAN = down >1 row   GREEN = down 1 row   BLUE = up
//   RED = same row, right   YELLOW = same row, left
const bool  DEBUG       = false;
// ---------------------------------------------------------------------------

vec2 cursorCenter(vec4 c) { return vec2(c.x + c.z * 0.5, c.y - c.w * 0.5); }

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2  prev  = cursorCenter(iPreviousCursor);
    vec2  curr  = cursorCenter(iCurrentCursor);
    float cellH = max(iCurrentCursor.w, 1.0);

    vec2 uv = fragCoord / iResolution.xy;
    vec4 color = texture2D(iChannel0, uv);

    // Keep the flash alive on two motions, kill it on all else (see header).
    // Distances are measured in CELL HEIGHTS, not the cursor's width: shells
    // switch the prompt to a beam cursor whose reported width is ~1px, so a
    // width-based threshold is unreliable. Cursor *height* is a full cell for
    // both block and beam cursors, so it's a steady yardstick.
    float dx     = curr.x - prev.x;          // + = moved right, - = moved left
    float dyDown = prev.y - curr.y;          // + = moved DOWN a row (origin bottom-left, +Y up)

    // New line: cursor drops a row AND the column jumps. The column-jump
    // requirement is what keeps an editor quiet — arrow up/down holds the column,
    // so it's filtered out; a shell Enter lands at a fresh prompt in a different
    // column, so it flashes.
    bool newLine    = dyDown > cellH * 0.5 && abs(dx) > cellH * MIN_SHIFT;

    // Prompt redraw: a rightward sweep starting at the left margin — the shell
    // repainting its prompt after output. Its leftward twin (Home, Ctrl+Left,
    // Ctrl+Backspace) is editing, not a newline, so we require the rightward sign.
    bool promptDraw = abs(dyDown) < cellH * 0.5
                   && dx > cellH * MIN_SHIFT
                   && prev.x < cellH * LEFT_MARGIN;

    bool keep = newLine || promptDraw;

    // Decay-only envelope: full at the move, smooth fade to zero by DURATION.
    // Maximal-at-zero is what lets later kept moves refresh rather than truncate it.
    float life = clamp((iTime - iTimeCursorChange) / DURATION, 0.0, 1.0);
    float env  = 1.0 - smoothstep(HOLD, 1.0, life);
    if (!keep) env = 0.0;

    vec3 glow = iCurrentCursorColor.rgb;

    // DEBUG: show every move, colored by direction, ungated by `keep`.
    if (DEBUG) {
        if      (dyDown >  cellH * 1.5) glow = vec3(0.0, 1.0, 1.0);  // down >1 row (cyan)
        else if (dyDown >  cellH * 0.5) glow = vec3(0.0, 1.0, 0.0);  // down 1 row (green)
        else if (dyDown < -cellH * 0.5) glow = vec3(0.0, 0.4, 1.0);  // up (blue)
        else if (dx > 0.0)              glow = vec3(1.0, 0.0, 0.0);  // same row, right
        else                            glow = vec3(1.0, 1.0, 0.0);  // same row, left
        env = 1.0 - smoothstep(HOLD, 1.0, life);
    }

    // Soft horizontal band centered on the current cursor row.
    float dy   = fragCoord.y - curr.y;
    float band = exp(-pow(dy / (cellH * HEIGHT), 2.0));
    color.rgb += glow * band * env * INTENSITY * (DEBUG ? 2.5 : 1.0);
    fragColor = color;
}
