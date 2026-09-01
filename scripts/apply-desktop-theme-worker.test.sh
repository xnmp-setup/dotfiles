#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
worker="$repo_root/scripts/apply-desktop-theme-worker"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$test_root/home/.local/share/chezmoi/scripts" "$test_root/bin"

cat >"$test_root/home/.local/share/chezmoi/scripts/set-theme.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_THEME_LOG"
if [[ "${TEST_THEME_FAIL:-0}" == 1 ]]; then
  echo "simulated theme failure" >&2
  exit 1
fi
EOF

cat >"$test_root/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_NOTIFY_LOG"
EOF

cat >"$test_root/bin/flock" <<'EOF'
#!/usr/bin/env bash
[[ "${TEST_THEME_LOCKED:-0}" == 0 ]]
EOF

chmod +x "$test_root/home/.local/share/chezmoi/scripts/set-theme.sh" \
  "$test_root/bin/notify-send" "$test_root/bin/flock"

run_worker() {
  HOME="$test_root/home" \
    PATH="$test_root/bin:/usr/bin:/bin" \
    XDG_STATE_HOME="$test_root/state" \
    TEST_THEME_LOG="$test_root/theme.log" \
    TEST_NOTIFY_LOG="$test_root/notify.log" \
    TEST_THEME_FAIL="${TEST_THEME_FAIL:-0}" \
    TEST_THEME_LOCKED="${TEST_THEME_LOCKED:-0}" \
    bash "$worker" "$@"
}

: >"$test_root/theme.log"
: >"$test_root/notify.log"
run_worker kanagawa Kanagawa
grep -Fxq 'kanagawa --restart-chrome' "$test_root/theme.log" \
  || fail "worker did not invoke the theme command safely"
grep -Fq 'Desktop theme set Kanagawa' "$test_root/notify.log" \
  || fail "worker did not report successful completion"

: >"$test_root/theme.log"
: >"$test_root/notify.log"
if TEST_THEME_LOCKED=1 run_worker kanagawa Kanagawa; then
  fail "worker ignored an active theme lock"
fi
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
