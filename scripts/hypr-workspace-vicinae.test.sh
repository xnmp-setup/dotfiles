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
cat >"$test_root/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_SYSTEMD_RUN_LOG"
EOF

chmod +x "$test_root/home/.local/bin/hypr-workspace" \
  "$test_root/home/.local/share/chezmoi/scripts/set-theme.sh" \
  "$test_root/bin/vicinae" "$test_root/bin/notify-send" \
  "$test_root/bin/systemd-run"

run_script() {
  HOME="$test_root/home" \
    PATH="$test_root/bin:$PATH" \
    TEST_WORKSPACE_LOG="$test_root/workspace.log" \
    TEST_DMENU_LOG="$test_root/dmenu.log" \
    TEST_DMENU_INPUT_LOG="$test_root/dmenu-input.log" \
    TEST_NOTIFY_LOG="$test_root/notify.log" \
    TEST_SYSTEMD_RUN_LOG="$test_root/systemd-run.log" \
    TEST_THEME_LOG="$test_root/theme.log" \
    TEST_EMPTY="${TEST_EMPTY:-0}" \
    HYPRLAND_INSTANCE_SIGNATURE=test-hyprland \
    bash "$@"
}

: >"$test_root/workspace.log"
: >"$test_root/dmenu.log"
: >"$test_root/dmenu-input.log"
: >"$test_root/notify.log"
: >"$test_root/theme.log"
: >"$test_root/systemd-run.log"

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
theme_output=$(run_script "$theme_script")
[[ "$theme_output" == "Applying Ayu Mirage" ]] \
  || fail "the theme picker did not report its asynchronous handoff"
[[ ! -s "$test_root/theme.log" ]] \
  || fail "the Vicinae command applied the theme synchronously"
grep -Fq -- '--user --collect --no-block --quiet' "$test_root/systemd-run.log" \
  || fail "the theme picker did not use a non-blocking transient user service"
grep -Fq -- '--setenv=HYPRLAND_INSTANCE_SIGNATURE=test-hyprland' \
  "$test_root/systemd-run.log" \
  || fail "the theme worker did not preserve the Hyprland instance"
grep -Fq -- "/usr/bin/env bash $theme_script --apply ayu-mirage Ayu Mirage" \
  "$test_root/systemd-run.log" \
  || fail "the transient service did not receive the selected theme"

run_script "$theme_script" --apply ayu-mirage "Ayu Mirage"
grep -Fxq 'ayu-mirage --restart-chrome' "$test_root/theme.log" ||
  fail "the background worker did not apply the selected theme and refresh Chrome"
grep -Fq -- 'Desktop theme set Ayu Mirage' "$test_root/notify.log" \
  || fail "the background worker did not report completion"
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
