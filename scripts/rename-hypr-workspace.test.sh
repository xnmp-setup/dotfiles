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
  "activeworkspace -j")
    printf '{"id":3,"name":"focused"}\n'
    ;;
  "workspaces -j")
    printf '[{"id":2,"name":"web"},{"id":3,"name":"focused"}]\n'
    ;;
  dispatch*)
    printf '%s\n' "$*" >> "$TEST_HYPRCTL_LOG"
    [[ "${TEST_HYPRCTL_FAIL:-0}" == 0 ]] || exit 1
    ;;
  *)
    exit 2
    ;;
esac
EOF

cat > "$test_root/bin/wofi" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_WOFI_LOG"
[[ "${TEST_WOFI_CANCEL:-0}" == 0 ]] || exit 1
printf '%s' "${TEST_WOFI_RESPONSE:-}"
EOF

cat > "$test_root/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_NOTIFY_LOG"
EOF

chmod +x "$test_root/bin/hyprctl" "$test_root/bin/wofi" "$test_root/bin/notify-send"

run_rename() {
  TEST_HYPRCTL_LOG="$test_root/hyprctl.log" \
    TEST_WOFI_LOG="$test_root/wofi.log" \
    TEST_NOTIFY_LOG="$test_root/notify.log" \
    TEST_HYPRCTL_FAIL="${TEST_HYPRCTL_FAIL:-0}" \
    XDG_RUNTIME_DIR="$test_root/runtime" \
    PATH="$test_root/bin:$PATH" \
    bash "$repo_root/dot_local/bin/executable_rename-hypr-workspace" "$@"
}

TEST_WOFI_RESPONSE="  project alpha  " run_rename 2
[[ $(cat "$test_root/hyprctl.log") == 'dispatch hl.dsp.workspace.rename({ workspace = 2, name = "project alpha" })' ]] \
  || fail "a named workspace was not dispatched"
grep -Fq -- "--search web" "$test_root/wofi.log" \
  || fail "the existing workspace name was not prefilled"
grep -Fq -- "--normal-window" "$test_root/wofi.log" \
  || fail "the prompt was not opened as a normal dismissible window"

before_locked_count=$(wc -l < "$test_root/wofi.log")
(
  flock --exclusive 9
  TEST_WOFI_RESPONSE="must not open" run_rename 2
) 9> "$test_root/runtime/rename-hypr-workspace.lock"
after_locked_count=$(wc -l < "$test_root/wofi.log")
[[ "$after_locked_count" -eq "$before_locked_count" ]] \
  || fail "a second rename prompt opened while one was already active"

: > "$test_root/hyprctl.log"
TEST_WOFI_RESPONSE="深度工作" run_rename
[[ $(cat "$test_root/hyprctl.log") == 'dispatch hl.dsp.workspace.rename({ workspace = 3, name = "深度工作" })' ]] \
  || fail "Alt+F2 did not target the focused workspace"

: > "$test_root/hyprctl.log"
TEST_WOFI_RESPONSE="" run_rename 2
[[ $(cat "$test_root/hyprctl.log") == 'dispatch hl.dsp.workspace.rename({ workspace = 2 })' ]] \
  || fail "empty input did not reset the workspace name"

: > "$test_root/hyprctl.log"
TEST_WOFI_RESPONSE='work"; error("pwn") --' run_rename 2
grep -Fq -- 'name = "work\"; error(\"pwn\") --" })' \
  "$test_root/hyprctl.log" \
  || fail "workspace text was not encoded as one Lua string"

: > "$test_root/hyprctl.log"
TEST_WOFI_CANCEL=1 run_rename 2
[[ ! -s "$test_root/hyprctl.log" ]] || fail "cancelling renamed a workspace"

: > "$test_root/hyprctl.log"
if TEST_WOFI_RESPONSE="123456789012345678901234567890123" run_rename 2; then
  fail "an oversized name was accepted"
fi
[[ ! -s "$test_root/hyprctl.log" ]] || fail "an oversized name reached Hyprland"
grep -Fq -- "Use no more than 32 characters." "$test_root/notify.log" \
  || fail "an oversized name did not explain the limit"

: > "$test_root/hyprctl.log"
: > "$test_root/notify.log"
if TEST_HYPRCTL_FAIL=1 TEST_WOFI_RESPONSE="rejected" run_rename 2; then
  fail "a rejected Hyprland rename was reported as successful"
fi
grep -Fq -- "Hyprland rejected the rename request." "$test_root/notify.log" \
  || fail "a rejected Hyprland rename had no recovery message"

if run_rename '2;reboot' > "$test_root/invalid.out" 2>&1; then
  fail "a malformed workspace ID was accepted"
fi
grep -Fq -- "invalid workspace ID" "$test_root/invalid.out" \
  || fail "a malformed workspace ID had no useful error"

echo "rename workspace tests passed"
