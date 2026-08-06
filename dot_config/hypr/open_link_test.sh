#!/bin/sh
# Behavioral tests for executable_open-link.sh. Run: sh open_link_test.sh

set -eu

command_name=${0##*/}

if [ "$command_name" = hyprctl ]; then
    if [ "$1" = -j ] && [ "$2" = monitors ]; then
        printf '%s\n' "$OPEN_LINK_TEST_MONITORS"
    elif [ "$1" = -j ] && [ "$2" = clients ]; then
        printf '%s\n' "$OPEN_LINK_TEST_CLIENTS"
    elif [ "$1" = dispatch ]; then
        printf 'dispatch:%s\n' "$2" >>"$OPEN_LINK_TEST_LOG"
        printf 'ok\n'
    else
        printf 'unexpected hyprctl arguments: %s\n' "$*" >&2
        exit 1
    fi
    exit 0
fi

if [ "$command_name" = google-chrome-stable ]; then
    printf 'chrome' >>"$OPEN_LINK_TEST_LOG"
    for argument in "$@"; do
        printf ' <%s>' "$argument" >>"$OPEN_LINK_TEST_LOG"
    done
    printf '\n' >>"$OPEN_LINK_TEST_LOG"
    exit 0
fi

if [ "$command_name" = sleep ]; then
    exit 0
fi

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_script=$test_dir/${0##*/}
handler=$test_dir/executable_open-link.sh
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT HUP INT TERM
test_bin=$test_root/bin
test_log=$test_root/log
mkdir -p "$test_bin"
ln -s "$test_script" "$test_bin/hyprctl"
ln -s "$test_script" "$test_bin/google-chrome-stable"
ln -s "$test_script" "$test_bin/sleep"

monitors='[{"focused":true,"activeWorkspace":{"id":2}}]'
failures=0

run_case() {
    name=$1
    clients=$2
    expected=$3
    : >"$test_log"

    OPEN_LINK_TEST_MONITORS=$monitors \
        OPEN_LINK_TEST_CLIENTS=$clients \
        OPEN_LINK_TEST_LOG=$test_log \
        HYPRLAND_INSTANCE_SIGNATURE=test \
        PATH=$test_bin:$PATH \
        sh "$handler" https://example.test

    actual=$(cat "$test_log")
    if [ "$actual" != "$expected" ]; then
        printf 'FAIL: %s\nexpected:\n%s\nactual:\n%s\n' \
            "$name" "$expected" "$actual" >&2
        failures=$((failures + 1))
    fi
}

run_case 'background browser group tab is selected before focus' \
    '[
        {"address":"0xeditor","mapped":true,"hidden":false,"visible":true,"workspace":{"id":2,"name":"2"},"floating":false,"class":"editor","grouped":["0xeditor","0xbrowser"]},
        {"address":"0xbrowser","mapped":true,"hidden":false,"visible":false,"workspace":{"id":2,"name":"2"},"floating":false,"class":"google-chrome","grouped":["0xeditor","0xbrowser"]}
    ]' \
    'dispatch:hl.dsp.group.active({ index = 2, window = "address:0xeditor" })
dispatch:hl.dsp.focus({ window = "address:0xbrowser" })
chrome <https://example.test>'

run_case 'visible browser group tab only needs focus' \
    '[
        {"address":"0xeditor","mapped":true,"hidden":false,"visible":false,"workspace":{"id":2,"name":"2"},"floating":false,"class":"editor","grouped":["0xeditor","0xbrowser"]},
        {"address":"0xbrowser","mapped":true,"hidden":false,"visible":true,"workspace":{"id":2,"name":"2"},"floating":false,"class":"google-chrome","grouped":["0xeditor","0xbrowser"]}
    ]' \
    'dispatch:hl.dsp.focus({ window = "address:0xbrowser" })
chrome <https://example.test>'

run_case 'browser on another workspace opens a new local window' \
    '[
        {"address":"0xbrowser","mapped":true,"hidden":false,"visible":false,"workspace":{"id":1,"name":"1"},"floating":false,"class":"google-chrome","grouped":[]}
    ]' \
    'chrome <--new-window> <https://example.test>'

if [ "$failures" -ne 0 ]; then
    exit 1
fi

printf 'open-link: all tests passed\n'
