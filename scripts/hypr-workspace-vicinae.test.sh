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

mkdir -p "$test_root/bin" "$test_root/home/.local/bin" \
  "$test_root/home/.local/share/chezmoi/scripts"

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
printf '%s\n' "$input" >>"$TEST_DMENU_INPUT_LOG"
[[ "${TEST_DMENU_CANCEL:-0}" == 0 ]] || exit 0
if [[ "$*" == *"Confirm Forget"* ]]; then
  printf '%s\n' "$input" | tail -n 1
else
  printf '%s\n' "$input" | head -n 1
fi
EOF

cat >"$test_root/home/.local/share/chezmoi/scripts/set-theme.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "--list-desktop-themes" ]]; then
  printf 'Ayu Mirage\nCosmic Dusk\n'
  exit 0
fi
printf '%s\n' "$*" >>"$TEST_THEME_LOG"
EOF

cat >"$test_root/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_NOTIFY_LOG"
EOF

chmod +x "$test_root/home/.local/bin/hypr-workspace" \
  "$test_root/home/.local/share/chezmoi/scripts/set-theme.sh" \
  "$test_root/bin/vicinae" "$test_root/bin/notify-send"

run_script() {
  HOME="$test_root/home" \
    PATH="$test_root/bin:$PATH" \
    TEST_WORKSPACE_LOG="$test_root/workspace.log" \
    TEST_DMENU_LOG="$test_root/dmenu.log" \
    TEST_DMENU_INPUT_LOG="$test_root/dmenu-input.log" \
    TEST_NOTIFY_LOG="$test_root/notify.log" \
    TEST_THEME_LOG="$test_root/theme.log" \
    TEST_EMPTY="${TEST_EMPTY:-0}" \
    bash "$1"
}

: >"$test_root/workspace.log"
: >"$test_root/dmenu.log"
: >"$test_root/dmenu-input.log"
: >"$test_root/notify.log"
: >"$test_root/theme.log"

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

: >"$test_root/dmenu.log"
: >"$test_root/dmenu-input.log"
: >"$test_root/notify.log"
theme_script="$repo_root/dot_local/share/vicinae/scripts/set-desktop-theme"
run_script "$theme_script"
grep -Fxq 'ayu-mirage --restart-chrome' "$test_root/theme.log" ||
  fail "the theme picker did not apply the selected theme and refresh Chrome"
grep -Fq -- 'Set Desktop Theme' "$test_root/dmenu.log" ||
  fail "the theme command did not open a searchable picker"
grep -Fq -- 'Desktop themes ({count})' "$test_root/dmenu.log" ||
  fail "the theme picker did not show its option count"
grep -Fq -- '--width 800' "$test_root/dmenu.log" ||
  fail "the theme picker did not reserve enough width for complete names"
[[ $(grep -Fxc 'Ayu Mirage' "$test_root/dmenu-input.log") -eq 1 ]] ||
  fail "the theme picker did not show each display name exactly once"
if grep -q $'\t' "$test_root/dmenu-input.log"; then
  fail "the theme picker exposed duplicate slug metadata"
fi
grep -Fq -- 'Desktop theme set' "$test_root/notify.log" ||
  fail "the completed theme switch was not visible to the user"
grep -Fxq '# @vicinae.mode silent' "$theme_script" ||
  fail "the theme command does not exit Vicinae after applying"
if grep -Fq '# @vicinae.argument' "$theme_script"; then
  fail "the theme command still asks for a free-form argument"
fi

: >"$test_root/theme.log"
TEST_DMENU_CANCEL=1 run_script "$theme_script"
[[ ! -s "$test_root/theme.log" ]] ||
  fail "cancelling the theme picker applied a theme"

echo "Vicinae workflow tests passed"
