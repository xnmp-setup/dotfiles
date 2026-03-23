#!/usr/bin/env bash
# Accelerating resize: step grows when pressed rapidly, resets after pause.
# Usage: accel-resize.sh <direction> where direction is "grow" or "shrink"

STATE_FILE="/tmp/hypr-accel-resize"
BASE=40
MAX=200
STEP_INC=30
TIMEOUT_MS=400

direction="$1"
now_ms=$(($(date +%s%N) / 1000000))

step=$BASE
if [[ -f "$STATE_FILE" ]]; then
    read -r last_ms last_step < "$STATE_FILE"
    elapsed=$((now_ms - last_ms))
    if (( elapsed < TIMEOUT_MS )); then
        step=$(( last_step + STEP_INC ))
        (( step > MAX )) && step=$MAX
    fi
fi

echo "$now_ms $step" > "$STATE_FILE"

case "$direction" in
    grow)   hyprctl --batch "dispatch resizeactive $step $step" ;;
    shrink) hyprctl --batch "dispatch resizeactive -$step -$step" ;;
    *)      echo "Usage: $0 {grow|shrink}" >&2; exit 1 ;;
esac
