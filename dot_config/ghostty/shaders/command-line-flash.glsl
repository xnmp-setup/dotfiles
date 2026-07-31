// command-line-flash.glsl — fixed-duration semantic command-line flash
//
// zsh preexec drives palette entry 254 for exactly 320 ms. Its red/green
// channels identify the private pulse protocol; blue contains a sampled
// smoothstep envelope. Because timing lives in this explicit event channel,
// command output, cursor movement, prompt redraws, and command duration cannot
// shorten, extend, or retrigger the animation.
//
// The protocol signal is never rendered as color. The flash uses the active
// theme's ANSI bright-red accent, lifted slightly toward its foreground for
// reliable contrast across dark and light themes. Cosmic Dusk resolves this to
// the rose family of the original effect without hardcoding that color.

const vec2 PULSE_MARKER = vec2(23.0, 231.0) / 255.0;
const float SIGNAL_TOLERANCE = 0.5 / 255.0;

// ---- tunables --------------------------------------------------------------
const float CORE_WIDTH_PX = 1.25;
const float HALO_HEIGHT   = 0.90; // cell heights
const float CORE_ENERGY   = 0.075;
const float HALO_ENERGY   = 0.21;
// ---------------------------------------------------------------------------

float pulseMarkerMatch(vec2 actual) {
    vec2 delta = abs(actual - PULSE_MARKER);
    return 1.0 - step(SIGNAL_TOLERANCE, max(delta.x, delta.y));
}

vec2 cursorCenter(vec4 cursor) {
    return vec2(
        cursor.x + cursor.z * 0.5,
        cursor.y - cursor.w * 0.5
    );
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 color = texture2D(iChannel0, uv);

    vec3 pulseSignal = iPalette[254];
    float flash = pulseMarkerMatch(pulseSignal.rg)
        * pulseSignal.b
        * float(iFocus > 0);

    vec2 cursor = cursorCenter(iCurrentCursor);
    float cellH = max(iCurrentCursor.w, 1.0);
    float fromRow = abs(fragCoord.y - cursor.y);

    // A bright one-pixel crest sharpens the impact while the nearly full-cell
    // bloom restores the satisfying body of the original flash.
    float core = exp(-fromRow / CORE_WIDTH_PX);
    float halo = exp(-pow(fromRow / (cellH * HALO_HEIGHT), 2.0));

    // Preserve the original uniform full-row read; only the outermost edge is
    // feathered so the light terminates in the window rather than clipping.
    float horizontal = smoothstep(0.0, 0.018, uv.x)
        * smoothstep(0.0, 0.018, 1.0 - uv.x);

    float energy = core * CORE_ENERGY + halo * HALO_ENERGY;
    vec3 flashColor = mix(iPalette[9], iForegroundColor, 0.10);
    vec3 light = flashColor * horizontal * energy * flash;

    // Screen blending preserves bright glyphs and ANSI contrast.
    color.rgb = 1.0 - (1.0 - color.rgb) * (1.0 - clamp(light, 0.0, 1.0));
    fragColor = color;
}
