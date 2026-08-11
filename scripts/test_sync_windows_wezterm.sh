#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sync_script=$script_dir/run_after_sync-windows-wezterm.sh
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

linux_home=$test_root/home
mkdir -p "$linux_home/.config/wezterm" "$linux_home/win"
printf '%s\n' 'return { font_size = 14 }' > "$linux_home/.config/wezterm/wezterm.lua"
printf '%s\n' 'return { value = "module" }' > "$linux_home/.config/wezterm/helper.lua"

HOME=$linux_home WSL_DISTRO_NAME=Ubuntu sh "$sync_script"

cmp "$linux_home/.config/wezterm/wezterm.lua" \
    "$linux_home/win/.config/wezterm/wezterm.lua"
cmp "$linux_home/.config/wezterm/helper.lua" \
    "$linux_home/win/.config/wezterm/helper.lua"

# A second run is idempotent and leaves existing targets byte-identical.
before=$(cksum "$linux_home/win/.config/wezterm/wezterm.lua")
HOME=$linux_home WSL_DISTRO_NAME=Ubuntu sh "$sync_script"
after=$(cksum "$linux_home/win/.config/wezterm/wezterm.lua")
[ "$before" = "$after" ]

# Outside WSL the Windows tree is untouched.
printf '%s\n' 'sentinel' > "$linux_home/win/.config/wezterm/sentinel.lua"
HOME=$linux_home WSL_DISTRO_NAME= sh "$sync_script"
[ "$(cat "$linux_home/win/.config/wezterm/sentinel.lua")" = sentinel ]

printf 'windows WezTerm sync tests: passed\n'
