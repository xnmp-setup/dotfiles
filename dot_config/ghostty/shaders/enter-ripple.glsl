// enter-ripple.glsl  —  newline flash
//
// On Enter, a soft horizontal glow flashes across the cursor's line and fades
// over DURATION. Color is read live from the active theme via
// iCurrentCursorColor (rose in Cosmic Dusk); swap for iForegroundColor to use
// the text color.
//
// Timing — why the fade now always completes:
//   Ghostty resets iTimeCursorChange on EVERY cursor move and gives the shader
//   no cross-frame memory, so we can't run a fixed timer anchored to "when
//   Enter happened." Two design choices make the full fade play out anyway,
//   regardless of when (or whether) output appears:
//
//   1. Decay-only envelope: brightness is MAXIMAL at the moment of a move and
//      only decays. A follow-up move (output, prompt redraw) can only refresh
//      it to full — never cut it short.
//
//   2. Suppress-typing gate: the flash is killed ONLY for typing-like moves
//      (the cursor stayed on its row and shifted a cell or two). Newlines,
//      output, and the prompt redrawing all keep it alive. This is the key
//      fix: a post-command prompt redraw lands on the same row but is NOT a
//      downward move, so the old movedDown gate zeroed the flash right when
//      output appeared. Now it survives, and because you're idle reading the
//      output, the fade runs to completion.
//
//   Tradeoffs (inherent to a stateless shader): output that arrives much later
//   than the fade may flash twice (once on Enter, once when it lands), each
//   playing fully; and row-to-row navigation in a pager/editor will flash.
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
// ---------------------------------------------------------------------------

vec2 cursorCenter(vec4 c) { return vec2(c.x + c.z * 0.5, c.y - c.w * 0.5); }

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2  prev  = cursorCenter(iPreviousCursor);
    vec2  curr  = cursorCenter(iCurrentCursor);
    float cellH = max(iCurrentCursor.w, 1.0);

    vec2 uv = fragCoord / iResolution.xy;
    vec4 color = texture2D(iChannel0, uv);

    // Suppress only typing-like moves: same row, shifted just a cell or two.
    // Everything else (newline, output, prompt redraw) keeps the flash alive.
    // Horizontal moves are measured in CELL HEIGHTS, not the cursor's width:
    // shells switch the prompt to a beam cursor whose reported width is ~1px,
    // so a width-based threshold missed typing entirely. Cursor *height* is a
    // full cell for both block and beam cursors, so it's a reliable yardstick.
    bool sameRow    = abs(prev.y - curr.y) < cellH * 0.5;
    bool smallShift = abs(curr.x - prev.x) < cellH * 1.5;   // ~3 character cells
    bool typing     = sameRow && smallShift;

    // Decay-only envelope: full at the move, smooth fade to zero by DURATION.
    // Maximal-at-zero is what lets later moves refresh rather than truncate it.
    float life = clamp((iTime - iTimeCursorChange) / DURATION, 0.0, 1.0);
    float env  = 1.0 - smoothstep(HOLD, 1.0, life);
    if (typing) env = 0.0;

    // Soft horizontal band centered on the current cursor row.
    float dy   = fragCoord.y - curr.y;
    float band = exp(-pow(dy / (cellH * HEIGHT), 2.0));

    color.rgb += iCurrentCursorColor.rgb * band * env * INTENSITY;
    fragColor = color;
}
