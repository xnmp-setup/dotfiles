#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d /tmp/rename-hypr-workspace.XXXXXX)

cleanup() {
  [[ "$test_root" == /tmp/rename-hypr-workspace.* ]] && rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$test_root/bin" "$test_root/runtime"

cat > "$test_root/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  dispatch*)
    printf '%s\n' "$*" >> "$TEST_HYPRCTL_LOG"
    [[ "${TEST_HYPRCTL_FAIL:-0}" == 0 ]] || exit 1
    ;;
  *)
    exit 2
    ;;
esac
EOF

cat > "$test_root/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_NOTIFY_LOG"
EOF

chmod +x "$test_root/bin/hyprctl" "$test_root/bin/notify-send"

run_rename() {
  TEST_HYPRCTL_LOG="$test_root/hyprctl.log" \
    TEST_NOTIFY_LOG="$test_root/notify.log" \
    TEST_HYPRCTL_FAIL="${TEST_HYPRCTL_FAIL:-0}" \
    XDG_RUNTIME_DIR="$test_root/runtime" \
    PATH="$test_root/bin:$PATH" \
    bash "$repo_root/dot_local/bin/executable_rename-hypr-workspace" "$@"
}

: > "$test_root/hyprctl.log"
: > "$test_root/notify.log"

run_rename 2 "  project alpha  "
[[ $(cat "$test_root/hyprctl.log") == 'dispatch hl.dsp.workspace.rename({ workspace = 2, name = "project alpha" })' ]] \
  || fail "a named workspace was not dispatched"

before_locked_count=$(wc -l < "$test_root/hyprctl.log")
(
  flock --exclusive 9
  run_rename 2 "must not dispatch"
) 9> "$test_root/runtime/rename-hypr-workspace.lock"
after_locked_count=$(wc -l < "$test_root/hyprctl.log")
[[ "$after_locked_count" -eq "$before_locked_count" ]] \
  || fail "a second rename dispatched while one was already active"

: > "$test_root/hyprctl.log"
run_rename 3 "深度工作"
[[ $(cat "$test_root/hyprctl.log") == 'dispatch hl.dsp.workspace.rename({ workspace = 3, name = "深度工作" })' ]] \
  || fail "a Unicode workspace name was not dispatched"

: > "$test_root/hyprctl.log"
run_rename 2 ""
[[ $(cat "$test_root/hyprctl.log") == 'dispatch hl.dsp.workspace.rename({ workspace = 2 })' ]] \
  || fail "empty input did not reset the workspace name"

: > "$test_root/hyprctl.log"
run_rename 2 'work"; error("pwn") --'
grep -Fq -- 'name = "work\"; error(\"pwn\") --" })' \
  "$test_root/hyprctl.log" \
  || fail "workspace text was not encoded as one Lua string"

: > "$test_root/hyprctl.log"
if run_rename 2 "123456789012345678901234567890123"; then
  fail "an oversized name was accepted"
fi
[[ ! -s "$test_root/hyprctl.log" ]] || fail "an oversized name reached Hyprland"
grep -Fq -- "Use no more than 32 characters." "$test_root/notify.log" \
  || fail "an oversized name did not explain the limit"

: > "$test_root/hyprctl.log"
: > "$test_root/notify.log"
if TEST_HYPRCTL_FAIL=1 run_rename 2 "rejected"; then
  fail "a rejected Hyprland rename was reported as successful"
fi
grep -Fq -- "Hyprland rejected the rename request." "$test_root/notify.log" \
  || fail "a rejected Hyprland rename had no recovery message"

if run_rename '2;reboot' "unsafe" > "$test_root/invalid.out" 2>&1; then
  fail "a malformed workspace ID was accepted"
fi
grep -Fq -- "invalid workspace ID" "$test_root/invalid.out" \
  || fail "a malformed workspace ID had no useful error"

if run_rename 2 > "$test_root/usage.out" 2>&1; then
  fail "a missing name argument was accepted"
fi
grep -Fq -- "Usage: rename-hypr-workspace WORKSPACE_ID NAME" "$test_root/usage.out" \
  || fail "a malformed invocation had no useful usage message"

echo "rename workspace tests passed"
