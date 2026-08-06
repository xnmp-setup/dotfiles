#!/bin/sh
# open-link.sh — the handler behind http/https, so links land in a real browser
# window on the workspace you are looking at, rather than in the F8 drop-down.
#
# Chrome gives a URL passed on the command line to whichever of its windows was
# active last. The drop-down is an ordinary Chrome window, so it wins that race
# constantly — and it is parked in special:chrome-drop whenever anything else
# has focus, which is exactly when a link gets clicked. The page opens in a
# window that is not on screen, and F8 later reveals a pile of them.
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
#
# The search is confined to the workspace in front of you. A browser sitting on
# some other workspace is not somewhere you asked to be sent, and adopting it
# would drag the screen out from under the click; with nothing local to reuse,
# --new-window puts the page where you already are. The workspace comes from the
# focused monitor rather than from `activeworkspace`, which reports the special
# workspace while a drop-down is up — so a link clicked inside the drop-down
# still finds the ordinary window underneath it.

set -eu

CHROME=google-chrome-stable
CLASS=google-chrome

# Outside a Hyprland session there is no drop-down to avoid.
if ! command -v hyprctl >/dev/null 2>&1 || [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    exec "$CHROME" "$@"
fi

workspace=$(hyprctl -j monitors 2>/dev/null | jq -r '
    [ .[] | select(.focused) | .activeWorkspace.id ] | first // empty
') || workspace=

# An unknown workspace matches nothing, so the link opens a new window here —
# the same answer this gives when the workspace is known and simply has no
# browser on it.
#
# A browser that is a background tab of a group needs its tab selected before it
# can be focused; focusing alone leaves it behind whichever sibling the group is
# showing, which is how a URL ends up in a window nobody can see. So the plan
# carries the group hop as well as the address: the tab's 1-based position, and
# the member currently on screen, which is the one the dispatcher acts on. Both
# are empty for an ungrouped window, and for a group already showing this one —
# `hidden` is what the compositor uses to say which member that is.
plan=$(hyprctl -j clients 2>/dev/null | jq -r --arg c "$CLASS" --arg ws "$workspace" '
    . as $clients
    | [ $clients[]
        | select(.class == $c)
        | select(.mapped)
        | select(.floating | not)
        | select(.workspace.name | startswith("special:") | not)
        | select(.workspace.id | tostring == $ws)
      ] | first
    | select(. != null)
    | . as $window
    | (.grouped // []) as $members
    | if ($members | length) > 1 and ($window.hidden // false)
      then [ $window.address,
             (($members | index($window.address)) + 1 | tostring),
             ([ $clients[]
                | select(.address as $a | $members | index($a))
                | select(.hidden // false | not)
              ] | first | .address // "") ]
      else [ $window.address, "", "" ]
      end
    | @tsv
') || plan=

IFS='	' read -r target group_index group_shown <<EOF
$plan
EOF

# Nothing to reuse, or a group whose visible member could not be named — the
# dispatcher has no window to act on, so there is no way to raise the tab.
if [ -z "$target" ] || { [ -n "$group_index" ] && [ -z "$group_shown" ]; }; then
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
if [ -n "$group_index" ] && [ "$(hyprctl dispatch \
    "hl.dsp.group.active({ index = $group_index, window = \"address:$group_shown\" })" \
    2>&1)" != "ok" ]; then
    exec "$CHROME" --new-window "$@"
fi

if [ "$(hyprctl dispatch "hl.dsp.focus({ window = \"address:$target\" })" 2>&1)" != "ok" ]; then
    exec "$CHROME" --new-window "$@"
fi

# Chrome learns it is the active window from the compositor's activation event,
# so the URL has to arrive after that has been delivered rather than alongside
# it — otherwise the request is served by the window that was active before.
sleep 0.2

exec "$CHROME" "$@"
