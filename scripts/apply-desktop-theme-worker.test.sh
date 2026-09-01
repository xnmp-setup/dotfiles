#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
worker="$repo_root/scripts/apply-desktop-theme-worker"
test_root=$(mktemp -d)

cleanup() {
  for pid_file in "$test_root/child.pid" "$test_root/lock-holder.pid"; do
    [[ -s "$pid_file" ]] || continue
    kill "$(<"$pid_file")" 2>/dev/null || true
  done
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$test_root/home/.local/share/chezmoi/scripts" "$test_root/bin"

cat >"$test_root/home/.local/share/chezmoi/scripts/set-theme.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_THEME_LOG"
if [[ "${TEST_THEME_SPAWN_CHILD:-0}" == 1 ]]; then
  sleep 30 </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" >"$TEST_CHILD_PID_LOG"
fi
if [[ "${TEST_THEME_FAIL:-0}" == 1 ]]; then
  echo "simulated theme failure" >&2
  exit 1
fi
EOF

cat >"$test_root/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_NOTIFY_LOG"
EOF

chmod +x "$test_root/home/.local/share/chezmoi/scripts/set-theme.sh" \
  "$test_root/bin/notify-send"

run_worker() {
  HOME="$test_root/home" \
    PATH="$test_root/bin:/usr/bin:/bin" \
    XDG_STATE_HOME="$test_root/state" \
    TEST_THEME_LOG="$test_root/theme.log" \
    TEST_NOTIFY_LOG="$test_root/notify.log" \
    TEST_THEME_FAIL="${TEST_THEME_FAIL:-0}" \
    TEST_THEME_SPAWN_CHILD="${TEST_THEME_SPAWN_CHILD:-0}" \
    TEST_CHILD_PID_LOG="$test_root/child.pid" \
    bash "$worker" "$@"
}

: >"$test_root/theme.log"
: >"$test_root/notify.log"
run_worker kanagawa Kanagawa
grep -Fxq 'kanagawa --restart-chrome' "$test_root/theme.log" \
  || fail "worker did not invoke the theme command safely"
grep -Fq 'Desktop theme set Kanagawa' "$test_root/notify.log" \
  || fail "worker did not report successful completion"

TEST_THEME_SPAWN_CHILD=1 run_worker kanagawa Kanagawa
[[ -s "$test_root/child.pid" ]] \
  || fail "lock inheritance fixture did not start a descendant"
/usr/bin/flock -n "$test_root/state/desktop-theme/apply.lock" true \
  || fail "theme command descendant inherited the worker lock"

: >"$test_root/theme.log"
: >"$test_root/notify.log"
(
  exec 8>"$test_root/state/desktop-theme/apply.lock"
  /usr/bin/flock 8
  : >"$test_root/lock.ready"
  sleep 30
) &
printf '%s\n' "$!" >"$test_root/lock-holder.pid"
for _ in {1..100}; do
  [[ -e "$test_root/lock.ready" ]] && break
  sleep 0.01
done
[[ -e "$test_root/lock.ready" ]] || fail "lock holder did not start"
if run_worker kanagawa Kanagawa; then
  fail "worker ignored an active theme lock"
fi
kill "$(<"$test_root/lock-holder.pid")" 2>/dev/null || true
rm -f "$test_root/lock-holder.pid"
[[ ! -s "$test_root/theme.log" ]] \
  || fail "locked worker reached the theme command"
grep -Fq 'Desktop theme already changing' "$test_root/notify.log" \
  || fail "worker did not explain lock contention"

: >"$test_root/theme.log"
: >"$test_root/notify.log"
if TEST_THEME_FAIL=1 run_worker kanagawa Kanagawa; then
  fail "worker hid a theme application failure"
fi
grep -Fq 'Desktop theme was not set simulated theme failure' \
  "$test_root/notify.log" \
  || fail "worker did not report the final failure"
grep -Fq 'simulated theme failure' "$test_root/state/desktop-theme/last-error.log" \
  || fail "worker did not persist failure details"

echo "desktop theme worker tests passed"
