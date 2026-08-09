#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d /tmp/hypr-workspace-vicinae.XXXXXX)
cleanup() {
  [[ "$test_root" == /tmp/hypr-workspace-vicinae.* ]] && rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$test_root/bin" "$test_root/home/.local/bin"

cat >"$test_root/home/.local/bin/hypr-workspace" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  list)
    [[ "${TEST_EMPTY:-0}" == 0 ]] || exit 0
    printf 'Project Alpha\t5 windows · 3 apps · opened 2h ago\t2\n'
    ;;
  restore|forget)
    printf '%s\t%s\n' "$1" "$2" >>"$TEST_WORKSPACE_LOG"
    printf '%s workspace %s.\n' "${1^}" "$2"
    ;;
esac
EOF

cat >"$test_root/bin/vicinae" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
input=$(cat)
printf '%s\n' "$*" >>"$TEST_DMENU_LOG"
if [[ "$*" == *"Confirm Forget"* ]]; then
  printf '%s\n' "$input" | tail -n 1
else
  printf '%s\n' "$input" | head -n 1
fi
EOF

cat >"$test_root/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_NOTIFY_LOG"
EOF

chmod +x "$test_root/home/.local/bin/hypr-workspace" \
  "$test_root/bin/vicinae" "$test_root/bin/notify-send"

run_script() {
  HOME="$test_root/home" \
    PATH="$test_root/bin:$PATH" \
    TEST_WORKSPACE_LOG="$test_root/workspace.log" \
    TEST_DMENU_LOG="$test_root/dmenu.log" \
    TEST_NOTIFY_LOG="$test_root/notify.log" \
    TEST_EMPTY="${TEST_EMPTY:-0}" \
    bash "$1"
}

: >"$test_root/workspace.log"
: >"$test_root/dmenu.log"
: >"$test_root/notify.log"

run_script "$repo_root/dot_local/share/vicinae/scripts/restore-workspace"
grep -Fxq $'restore\t2' "$test_root/workspace.log" ||
  fail "restore did not act on the selected workspace id"
grep -Fq -- 'Restore Workspace' "$test_root/dmenu.log" ||
  fail "restore did not use the workspace picker title"
grep -Fq -- 'Recent workspaces ({count})' "$test_root/dmenu.log" ||
  fail "restore did not use the standard recent-workspace section"
grep -Fq -- 'Restoring workspace' "$test_root/notify.log" ||
  fail "restore success was not visible to the user"

run_script "$repo_root/dot_local/share/vicinae/scripts/forget-workspace"
grep -Fxq $'forget\t2' "$test_root/workspace.log" ||
  fail "forget did not act on the selected workspace id"
grep -Fq -- 'Confirm Forget' "$test_root/dmenu.log" ||
  fail "forget did not require confirmation"
grep -Fq -- 'Workspace forgotten' "$test_root/notify.log" ||
  fail "forget success was not visible to the user"

: >"$test_root/notify.log"
TEST_EMPTY=1 run_script "$repo_root/dot_local/share/vicinae/scripts/restore-workspace"
grep -Fq -- 'No recent workspaces' "$test_root/notify.log" ||
  fail "the empty state was not explained"

echo "Vicinae workspace workflow tests passed"
