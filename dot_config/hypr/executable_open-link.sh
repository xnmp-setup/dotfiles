#!/bin/sh
# open-link.sh — the handler behind http/https, so links land in a real browser
# window rather than in the F6 drop-down.
#
# Chrome gives a URL passed on the command line to whichever of its windows was
# active last. The drop-down is an ordinary Chrome window, so it wins that race
# constantly — and it is parked in special:chrome-drop whenever anything else
# has focus, which is exactly when a link gets clicked. The page opens in a
# window that is not on screen, and F6 later reveals a pile of them.
#
# There is no flag for "put it in that window": the routing follows Chrome's own
# idea of which window was active, so the only lever is to make the window we
# want active first and then hand over the URL. With no such window there is
# nothing to disambiguate and --new-window says it outright.
#
# Telling the drop-down apart from an ordinary window has to be done by shape,
# not by name: Chrome ignores --class on Wayland, so every window it opens is
# class google-chrome. But scratchpad.lua floats the drop-down on its way in and
# parks it in a special workspace on its way out, and it is never anything else.
# So "tiled, on an ordinary workspace" names a window that is not the drop-down.
# A hand-floated ordinary Chrome window fails that test and gets a new window
# instead, which is the harmless way to be wrong.

set -eu

CHROME=google-chrome-stable
CLASS=google-chrome

# Outside a Hyprland session there is no drop-down to avoid.
if ! command -v hyprctl >/dev/null 2>&1 || [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    exec "$CHROME" "$@"
fi

target=$(hyprctl -j clients 2>/dev/null | jq -r --arg c "$CLASS" '
    [ .[]
      | select(.class == $c)
      | select(.mapped)
      | select(.floating | not)
      | select(.workspace.name | startswith("special:") | not)
    ] | first | .address // empty
') || target=

if [ -z "$target" ]; then
    exec "$CHROME" --new-window "$@"
fi

# Lua syntax, not `focuswindow address:...`: this Hyprland runs the Lua config,
# and hyprctl wraps whatever it is given as `return hl.dispatch(<arg>)`, so the
# legacy string form is a parse error. The address still needs its "address:"
# prefix — bare, hl.focus reports "window not found".
#
# Tested on the output rather than the exit status, which is 0 even for a
# dispatcher that parsed badly or matched nothing. Silently falling through
# would send the URL to whatever was active before, i.e. the drop-down.
if [ "$(hyprctl dispatch "hl.dsp.focus({ window = \"address:$target\" })" 2>&1)" != "ok" ]; then
    exec "$CHROME" --new-window "$@"
fi

# Chrome learns it is the active window from the compositor's activation event,
# so the URL has to arrive after that has been delivered rather than alongside
# it — otherwise the request is served by the window that was active before.
sleep 0.2

exec "$CHROME" "$@"
