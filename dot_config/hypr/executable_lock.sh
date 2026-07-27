#!/usr/bin/env bash
#
# Lock the screen, then decide whether the cached sudo ticket survives it.
#
# The rule: the password holds for the whole session, and expires only once BOTH
#   1. the screen has been locked since the password was typed, and
#   2. more than an hour has passed since it was typed
# are true. Where the rule is in force, sudo is configured never to time out on
# its own, so this script is the only thing that expires the ticket — every path
# that locks the screen must go through here, or sudo caches forever.
#
# Condition 1 is structural: everything after hyprlock returns has, by
# definition, had a lock since whatever ticket is currently held was
# authenticated. Only condition 2 needs checking.
#
# The sudo half of the rule is per-machine (on NixOS it comes from
# nixos-t14s modules/system.nix), so this probes for it rather than assuming
# it: a box without the pam_exec hook has an ordinary self-expiring sudo ticket
# and wants a plain lock, not a wrapper clearing its credentials every unlock.

set -uo pipefail

readonly TTL=3600
readonly STAMP="/run/sudo-auth-stamp.$USER"
readonly EXPIRE_UNIT=sudo-ticket-expiry

# Read before locking: /etc/pam.d/sudo is the thing that writes $STAMP, so its
# presence — not the stamp's, which is absent until the first sudo of the boot —
# is what says this machine opts into the rule.
managed_ticket=false
grep -qs sudo-auth-stamp /etc/pam.d/sudo && managed_ticket=true

hyprlock "$@" # blocks for as long as the screen is locked

$managed_ticket || exit 0

if [[ ! -e $STAMP ]]; then
  # No record of when the password was typed: either sudo hasn't been used
  # since boot (so there is no ticket and this is a no-op) or the PAM hook is
  # broken. Fail closed — with sudo's own timeout disabled, guessing the other
  # way would cache the ticket indefinitely.
  sudo -K
  exit 0
fi

typed=$(stat -c %Y "$STAMP")
age=$(($(date +%s) - typed))

if ((age >= TTL)); then
  sudo -K
  exit 0
fi

# Not an hour old yet, but nothing further needs to *happen* for the rule to
# fire — the clock just has to run out, and the lock that satisfies condition 1
# has already occurred. Arm a one-shot timer for the remainder.
#
# The timer re-reads the stamp when it fires, so typing the password again in
# the meantime (which resets condition 1) cancels the expiry instead of killing
# a fresh ticket. A fixed unit name means a later lock replaces this timer
# rather than stacking another one on top of it.
systemctl --user stop "$EXPIRE_UNIT.timer" "$EXPIRE_UNIT.service" >/dev/null 2>&1
systemd-run --user --quiet --collect \
  --unit="$EXPIRE_UNIT" \
  --on-active=$((TTL - age)) \
  "$HOME/.config/hypr/expire-sudo-ticket.sh" "$typed"
