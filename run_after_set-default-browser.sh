#!/bin/sh
# Make chrome-window.desktop the default for links, so they go through
# open-link.sh instead of straight to Chrome.
#
# That matters because Chrome hands a URL to whichever of its windows was active
# last and does nothing about focus: with google-chrome.desktop as the handler a
# link opens in a window you cannot see — buried in a tab strip, on another
# workspace, or in the F8 drop-down while it is parked. open-link.sh picks an
# ordinary window, focuses it, and only then hands over the URL.
#
# A script rather than managing ~/.config/mimeapps.list itself: that file also
# carries image and editor associations that differ per machine, and any app
# calling xdg-mime rewrites it, so owning the whole file would mean fighting
# them over unrelated lines. This sets one association and leaves the rest.
#
# This runs after every apply because MIME defaults are mutable external state:
# Chrome or another desktop application can replace them without changing the
# chezmoi source. Reasserting this small set is idempotent and repairs that drift.

set -eu

ENTRY=chrome-window.desktop

# Every condition the entry depends on, checked at runtime rather than templated
# on the machine, so a box that gains or loses one of them stays correct.
#
#   xdg-mime           absent on macOS, where associations are LaunchServices'
#   the entry itself   .desktop files are applied everywhere but mean nothing
#                      outside a freedesktop session
#   the browser        open-link.sh ends in google-chrome-stable, so without one
#                      this would point http at a handler that cannot serve it
#
# WSL is excluded even when all three hold: links there are expected to open in
# the Windows browser through wslview, and quietly taking that over from inside
# the Linux side is not this file's call to make.
command -v xdg-mime >/dev/null 2>&1 || exit 0
command -v google-chrome-stable >/dev/null 2>&1 || exit 0
[ -f "${XDG_DATA_HOME:-$HOME/.local/share}/applications/$ENTRY" ] || exit 0
case "$(cat /proc/sys/kernel/osrelease 2>/dev/null)" in
    *[Mm]icrosoft*) exit 0 ;;
esac

for mime in text/html \
            x-scheme-handler/http \
            x-scheme-handler/https \
            x-scheme-handler/about \
            x-scheme-handler/unknown; do
    xdg-mime default "$ENTRY" "$mime"
done
