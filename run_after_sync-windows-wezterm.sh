#!/bin/sh
# A WSL chezmoi apply targets the Linux home, while the Windows WezTerm process
# reads C:\Users\...\.config\wezterm (mounted here as ~/win/.config/wezterm).
# Sync the already-rendered target files after chezmoi has updated them. WezTerm
# does not need to be installed inside WSL.

set -eu

[ -n "${WSL_DISTRO_NAME:-}" ] || exit 0

source_dir=$HOME/.config/wezterm
windows_home=$HOME/win
target_dir=$windows_home/.config/wezterm

[ -d "$windows_home" ] || {
    printf 'windows WezTerm sync: missing Windows home at %s\n' "$windows_home" >&2
    exit 1
}
[ -f "$source_dir/wezterm.lua" ] || {
    printf 'windows WezTerm sync: missing rendered entrypoint at %s/wezterm.lua\n' \
        "$source_dir" >&2
    exit 1
}

mkdir -p "$target_dir"
changed=0

sync_file() {
    source_file=$1
    target_file=$2
    [ -f "$source_file" ] || return 0
    cmp -s "$source_file" "$target_file" 2>/dev/null && return 0

    temporary_file=$target_dir/.${target_file##*/}.chezmoi.$$
    trap 'rm -f "$temporary_file"' EXIT HUP INT TERM
    cp -p "$source_file" "$temporary_file"
    mv -f "$temporary_file" "$target_file"
    trap - EXIT HUP INT TERM
    changed=$((changed + 1))
}

# Modules first, then the entrypoint. This keeps every newly referenced module
# available if Windows WezTerm notices the file changes during the sync.
for source_file in "$source_dir"/*.lua; do
    [ -f "$source_file" ] || continue
    [ "${source_file##*/}" = wezterm.lua ] && continue
    sync_file "$source_file" "$target_dir/${source_file##*/}"
done
sync_file "$source_dir/wezterm.lua" "$target_dir/wezterm.lua"

[ "$changed" -eq 0 ] || printf 'windows WezTerm sync: updated %s Lua files\n' "$changed"
