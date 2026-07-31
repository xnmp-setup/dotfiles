// agent-aurora.glsl — Claude/Codex activity at the terminal's top edge
//
// The shell integration reserves palette entry 255 as a per-surface state
// channel. The entry is restored as soon as the agent stops, so ordinary
// terminals and unrelated progress reporters are unaffected.
//
// Signals:
//   Claude working  #b09ac0  -> theme magenta aurora
//   Codex working   #7aadcc  -> theme cyan aurora
//   Needs attention #fbbf24  -> steady theme-yellow breath
//
// The glow is deliberately shallow: its bright core occupies only the top few
// pixels, while a low-opacity haze provides enough presence on a dark theme.
// Set DRIFT_SPEED to 0.0 for a static, reduced-motion working indicator.

const float TAU = 6.28318530718;

// ---- tunables --------------------------------------------------------------
const float DRIFT_SPEED       = 0.075; // horizontal cycles per second
const float WORKING_INTENSITY = 0.17;
const float ALERT_INTENSITY   = 0.20;
const float CORE_DEPTH        = 2.2;   // pixels
const float HAZE_DEPTH        = 13.0;  // pixels
// ---------------------------------------------------------------------------

const vec3 CLAUDE_SIGNAL = vec3(176.0, 154.0, 192.0) / 255.0;
const vec3 CODEX_SIGNAL  = vec3(122.0, 173.0, 204.0) / 255.0;
const vec3 ALERT_SIGNAL  = vec3(251.0, 191.0,  36.0) / 255.0;
const float SIGNAL_TOLERANCE = 1.5 / 255.0;

float signalMatch(vec3 actual, vec3 expected) {
    return 1.0 - step(SIGNAL_TOLERANCE, distance(actual, expected));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 color = texture2D(iChannel0, uv);

    vec3 signal = iPalette[255];
    float claude = signalMatch(signal, CLAUDE_SIGNAL);
    float codex = signalMatch(signal, CODEX_SIGNAL);
    float alert = signalMatch(signal, ALERT_SIGNAL);
    float working = max(claude, codex);

    // Standard ANSI palette roles keep the rendered aurora in step with theme
    // changes even though the state-channel sentinel colors stay constant.
    vec3 workingColor = claude * iPalette[5] + codex * iPalette[6];
    vec3 alertColor = iPalette[3];

    float x = uv.x;
    float fromTop = max(iResolution.y - fragCoord.y, 0.0);

    // Two low-frequency waves make a broad ribbon drift rather than presenting
    // another hard-edged progress bar. There is always a faint continuous edge;
    // only its energy and depth travel.
    float phase = TAU * (x - iTime * DRIFT_SPEED);
    float wave = 0.5 + 0.5 * sin(phase + 0.55 * sin(phase * 0.37 + 1.1));
    float energy = 0.42 + 0.58 * smoothstep(0.08, 0.92, wave);
    float depth = CORE_DEPTH + wave * 2.8;
    float workingCore = exp(-fromTop / depth);
    float workingHaze = exp(-fromTop / HAZE_DEPTH);
    float workingLight = working
        * energy
        * (workingCore * 0.82 + workingHaze * 0.18)
        * WORKING_INTENSITY;

    // Attention holds its position and breathes slowly. Removing lateral motion
    // makes the state change legible even when peripheral vision catches it.
    float breath = 0.82 + 0.18 * sin(iTime * TAU / 2.8);
    float alertCore = exp(-fromTop / (CORE_DEPTH + 0.8));
    float alertHaze = exp(-fromTop / (HAZE_DEPTH * 0.82));
    float alertLight = alert
        * breath
        * (alertCore * 0.84 + alertHaze * 0.16)
        * ALERT_INTENSITY;

    vec3 light = workingColor * workingLight + alertColor * alertLight;

    // Screen blending adds light without washing out bright terminal content.
    color.rgb = 1.0 - (1.0 - color.rgb) * (1.0 - clamp(light, 0.0, 1.0));
    fragColor = color;
}
