.pragma library

// Nerd Fonts v3 material-design glyphs. Rendered with Hack Nerd Font, which
// the WezTerm config already assumes is installed; cells fall back to their
// text labels when the family is missing (see MetricCell.iconAvailable).
const WIFI_OFF = "\u{f092d}";
const WIFI_OUTLINE = "\u{f092f}";
const WIFI_BARS = ["\u{f091f}", "\u{f0922}", "\u{f0925}", "\u{f0928}"];

const BATTERY_ALERT = "\u{f0083}";
const BATTERY_OUTLINE = "\u{f008e}";
const BATTERY_CHARGING = "\u{f0084}";
const BATTERY_FULL = "\u{f0079}";
// battery_10 (f007a) through battery_90 (f0082), in tens.
const BATTERY_STEPS = [
    "\u{f007a}", "\u{f007b}", "\u{f007c}", "\u{f007d}", "\u{f007e}",
    "\u{f007f}", "\u{f0080}", "\u{f0081}", "\u{f0082}"
];

function wifiIcon(connected, strength) {
    if (!connected)
        return WIFI_OFF;
    if (typeof strength !== "number" || !Number.isFinite(strength))
        return WIFI_OUTLINE;
    if (strength >= 80)
        return WIFI_BARS[3];
    if (strength >= 55)
        return WIFI_BARS[2];
    if (strength >= 30)
        return WIFI_BARS[1];
    if (strength >= 5)
        return WIFI_BARS[0];
    return WIFI_OUTLINE;
}

function batteryIcon(percent, state) {
    if (state === "charging")
        return BATTERY_CHARGING;
    if (typeof percent !== "number" || !Number.isFinite(percent))
        return BATTERY_OUTLINE;
    if (percent >= 95)
        return BATTERY_FULL;
    if (percent < 5)
        return BATTERY_ALERT;
    const step = Math.min(9, Math.max(1, Math.round(percent / 10)));
    return BATTERY_STEPS[step - 1];
}
