#!/bin/sh
# Reassert the link handler after an apply, by running the copy this apply just
# placed on disk. The logic, and why it exists at all, lives there:
# dot_local/bin/executable_set-default-browser.
#
# Delegating rather than duplicating keeps one definition of "which entry owns
# http", and means the two callers — this, and Hyprland startup — cannot drift
# apart. This is the weaker of the two: applies are scoped to the files that
# changed (see CLAUDE.md), so this script only runs on a full apply. The startup
# call is what actually repairs Chrome's habit of taking the association back.

set -eu

HANDLER="${HOME}/.local/bin/set-default-browser"

# Absent on the very first apply, when this script can run before the target
# exists; the next session start picks it up.
[ -x "$HANDLER" ] || exit 0

exec "$HANDLER"
