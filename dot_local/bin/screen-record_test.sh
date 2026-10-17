#!/usr/bin/env bash
# Contract tests for screen-record using stub slurp/recorder binaries.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
script=$repo_root/dot_local/bin/executable_screen-record
root=$(mktemp -d)
trap 'pkill -f "$root/bin" 2>/dev/null || true; rm -rf -- "$root"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$root/bin" "$root/run" "$root/out dir"
printf '#!/bin/sh\necho "1,2 300x200"\n' >"$root/bin/slurp"
# Stub recorder: writes the -f target, finalises it on SIGINT.
cat >"$root/bin/wf-recorder" <<'STUB'
#!/bin/bash
while [[ $# -gt 0 ]]; do [[ $1 == -f ]] && out=$2; shift; done
echo partial >"$out"
trap 'echo finalised >"$out"; exit 0' INT
while :; do sleep 0.1; done
STUB
chmod +x "$root/bin/"*
# exec -a would change comm; the recorder's comm must be wf-recorder, which the
# stub's filename already gives.

# Hermetic PATH: only the stubs plus the plain utilities the script needs, so a
# real wf-recorder or wl-copy on the machine cannot leak into the test.
mkdir -p "$root/tools"
for tool in bash sh cat date find mkdir chmod sleep tail rm uname setsid printf env tr; do
  found=$(command -v "$tool") && ln -s "$found" "$root/tools/$tool"
done
export PATH="$root/bin:$root/tools" WAYLAND_DISPLAY=wayland-test
export XDG_RUNTIME_DIR=$root/run SCREEN_RECORD_DIR="$root/out dir/Screen Recording"
# Stub wl-copy: stores the selection type and payload instead of using a compositor.
cat >"$root/bin/wl-copy" <<'STUB'
#!/bin/sh
[ "$1" = --type ] && echo "$2" >"$CLIP_TYPE"
cat >"$CLIP_DATA"
STUB
chmod +x "$root/bin/wl-copy"
export CLIP_TYPE=$root/clip.type CLIP_DATA=$root/clip.data

# Pushes must arrive during capture transitions, including before finalising
# the stopped file. The real bar is external; this stub observes its IPC API.
cat >"$root/bin/quickshell" <<'STUB'
#!/bin/bash
[[ $* == 'ipc -c statusbar call bar screenRecording '* ]] || exit 2
since=${!#}
if [[ $since == 0 ]]; then
  [[ ! -e $XDG_RUNTIME_DIR/screen-record/started ]] || exit 3
  echo off >>"$INDICATOR_EVENTS"
else
  [[ $(<"$XDG_RUNTIME_DIR/screen-record/started") == "$since" ]] || exit 4
  echo on >>"$INDICATOR_EVENTS"
fi
STUB
chmod +x "$root/bin/quickshell"
export INDICATOR_EVENTS=$root/indicator.events

"$script" status && fail "status must report idle before recording"
"$script" toggle
shopt -s nullglob
files=("$SCREEN_RECORD_DIR"/*.mp4)
((${#files[@]} == 1)) || fail "first toggle should start one recording, got ${#files[@]}"
[[ $("$script" status) == "recording "[0-9]* ]] || fail "status should report the start time while recording"
[[ $(<"$INDICATOR_EVENTS") == on ]] || fail "REC must be pushed on at start"

"$script" toggle
[[ $(<"${files[0]}") == finalised ]] || fail "second toggle should stop and finalise the file"
[[ $(<"$CLIP_TYPE") == text/uri-list ]] || fail "clipboard should carry a uri-list"
expected="file://${files[0]// /%20}"
[[ $(tr -d '\r' <"$CLIP_DATA") == "$expected" ]] || fail "clipboard should reference the saved file, got: $(<"$CLIP_DATA")"
"$script" status && fail "status must report idle after stop"
[[ ! -e $root/run/screen-record/pid ]] || fail "pid state should be cleared after stop"
[[ $(<"$INDICATOR_EVENTS") == $'on\noff' ]] || fail "REC must be pushed off at stop"

# A delayed startup check must not clear or announce a newer capture.
set -m # keep SIGINT usable when this test launches the toggle in the background
"$script" toggle >"$root/first.log" 2>&1 &
first=$!
set +m
for ((i = 0; i < 100; i++)); do
  [[ -e $root/run/screen-record/started ]] && break
  sleep 0.01
done
"$script" toggle
"$script" toggle
wait "$first" || fail "a deliberately stopped startup is not a failure"
"$script" status >/dev/null || fail "the newer capture must retain its state"
[[ ! -s $root/first.log ]] || fail "superseded startup must not announce success or failure"
"$script" toggle

# Cancelled selection records nothing.
printf '#!/bin/sh\nexit 1\n' >"$root/bin/slurp"
rm -f "$SCREEN_RECORD_DIR/"*.mp4
"$script" toggle
files=("$SCREEN_RECORD_DIR"/*.mp4)
((${#files[@]} == 0)) || fail "cancelled selection must not record"

# Missing recorder fails without leaving state behind.
rm "$root/bin/wf-recorder"
if "$script" toggle 2>/dev/null; then fail "missing recorder should be an error"; fi
[[ ! -e $root/run/screen-record/pid ]] || fail "no pid state without a recording"

echo "ok"
