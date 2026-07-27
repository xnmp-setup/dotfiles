#!/usr/bin/env bash
#
# Expire the cached sudo ticket, unless the password has been retyped since the
# lock that scheduled this. Run only by the one-shot timer that lock.sh arms —
# see the reasoning there.
#
# Argument: the mtime of the auth stamp as it was at the time of that lock.

set -uo pipefail

readonly STAMP="/run/sudo-auth-stamp.$USER"
typed_at_lock=${1:-}

# Stamp gone or newer than expected: the password was typed again after the
# lock, so the screen has not been locked since — the rule does not apply.
[[ -e $STAMP ]] || exit 0
[[ $(stat -c %Y "$STAMP") == "$typed_at_lock" ]] || exit 0

sudo -K
