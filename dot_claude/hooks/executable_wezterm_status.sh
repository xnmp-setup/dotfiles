#!/bin/sh
# Hook: set WezTerm per-pane user var "claude_status" so format-tab-title can
# tint the tab by Claude state (working | done | attention). Status passed as $1.
# Wiring (settings.json):
#   working   <- UserPromptSubmit, PreToolUse, PostToolUse
#   attention <- PermissionRequest (immediate; fires only on a real dialog)
#   done      <- Stop, and Notification/idle_prompt (clears the interrupt-stuck
#                case, since no hook fires on user interrupt)
# A literal "notification" arg is resolved to attention/done/ignore below using
# the Notification payload's notification_type (the Notification event is
# debounced ~2s, so PermissionRequest is the fast path for red).
#
# Mechanism: OSC 1337 SetUserVar. We CANNOT write to /dev/tty — Claude spawns
# hooks without a controlling terminal, so /dev/tty open-for-write fails with
# ENXIO ("Device not configured") even though `[ -w /dev/tty ]` is true (it only
# checks mode bits). Instead resolve this pane's real device from $WEZTERM_PANE
# via `wezterm cli list` and write the escape sequence there. The sequence is a
# non-rendered control sequence, so it won't disturb Claude's TUI. Silent no-op
# outside WezTerm so it can never break a session.

status="$1"
[ -z "$status" ] && exit 0

# Read the hook JSON payload (drains stdin so the pipe never blocks).
payload=$(cat 2>/dev/null)

# The Notification event covers several sub-types. Only a permission prompt is
# "awaiting permission" (red); an idle prompt means Claude is stopped waiting on
# you (orange, same as Stop). Resolve the real status from notification_type.
# (Other sub-types: auth_success, elicitation_* — ignore them.)
if [ "$status" = "notification" ]; then
  ntype=$(printf '%s' "$payload" | jq -r '.notification_type // empty' 2>/dev/null)
  case "$ntype" in
    permission_prompt) status=attention ;;
    idle_prompt)       status=done ;;
    *)                 exit 0 ;;
  esac
fi

[ "$TERM_PROGRAM" = "WezTerm" ] || exit 0
[ -n "$WEZTERM_PANE" ] || exit 0

# wezterm CLI lives next to the gui binary that launched us.
wt="${WEZTERM_EXECUTABLE%-gui}"
[ -x "$wt" ] || wt="$(command -v wezterm 2>/dev/null)"
[ -n "$wt" ] && [ -x "$wt" ] || exit 0

# Map this pane id to its tty device.
tty_dev=$("$wt" cli list --format json 2>/dev/null \
  | jq -r --argjson p "$WEZTERM_PANE" \
      '.[] | select(.pane_id == $p) | .tty_name // empty' 2>/dev/null)
[ -n "$tty_dev" ] && [ -w "$tty_dev" ] || exit 0

# OSC 1337 SetUserVar requires the value to be base64-encoded.
b64=$(printf '%s' "$status" | base64 | tr -d '\n')
printf '\033]1337;SetUserVar=claude_status=%s\007' "$b64" > "$tty_dev" 2>/dev/null

exit 0
