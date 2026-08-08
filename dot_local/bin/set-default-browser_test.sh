#!/bin/sh
# Behavioral tests for executable_set-default-browser.
# Run: sh set-default-browser_test.sh
#
# Not applied to $HOME — .chezmoiignore keeps it out, because everything else in
# this directory lands on PATH and a test is not a command.
#
# xdg-mime is stubbed rather than run for real: the real one rewrites
# ~/.config/mimeapps.list, which is the user's live desktop configuration and
# not something a test may touch. The stub records what would have been set,
# which is the whole observable behaviour of this script.

set -eu

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
handler=$test_root/set-default-browser
cp "$script_dir/executable_set-default-browser" "$handler"
chmod +x "$handler"

bin=$test_root/bin
mkdir -p "$bin" "$test_root/share/applications"
touch "$test_root/share/applications/chrome-window.desktop"

# Answers every query with $STUB_CURRENT unless STUB_<key> overrides it, and
# appends every write to $STUB_LOG.
cat >"$bin/xdg-mime" <<'STUB'
#!/bin/sh
if [ "$1" = query ]; then
    case "$3" in
        text/html)               printf '%s\n' "${STUB_HTML-$STUB_CURRENT}" ;;
        x-scheme-handler/https)  printf '%s\n' "${STUB_HTTPS-$STUB_CURRENT}" ;;
        *)                       printf '%s\n' "$STUB_CURRENT" ;;
    esac
    exit 0
fi
[ "$1" = default ] && printf '%s\n' "$3" >>"$STUB_LOG"
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' >"$bin/google-chrome-stable"
chmod +x "$bin/xdg-mime" "$bin/google-chrome-stable"

# $bin is the whole PATH for every run, not a prefix of the real one: the guard
# cases below work by removing a command, and a real google-chrome-stable
# further down an inherited PATH would satisfy the guard they mean to trip.
# Everything the script actually calls has to be reachable here, hence cat.
for tool in cat; do
    ln -s "$(command -v "$tool")" "$bin/$tool"
done

log=$test_root/log
failures=0

# run_case <name> <current default> <expected keys written>
run_case() {
    name=$1
    current=$2
    expected=$3
    : >"$log"

    STUB_CURRENT=$current \
        STUB_LOG=$log \
        XDG_DATA_HOME=$test_root/share \
        PATH=$bin \
        "$handler"

    actual=$(tr '\n' ' ' <"$log" | sed 's/ $//')
    if [ "$actual" = "$expected" ]; then
        return 0
    fi
    printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' \
        "$name" "$expected" "$actual" >&2
    failures=$((failures + 1))
}

ALL='text/html x-scheme-handler/http x-scheme-handler/https x-scheme-handler/about x-scheme-handler/unknown'

# Chrome taking the association back is the drift this exists to undo, under
# every spelling its packagings use for the entry.
run_case 'reclaims from google-chrome.desktop'  google-chrome.desktop        "$ALL"
run_case 'reclaims from com.google.Chrome'      com.google.Chrome.desktop    "$ALL"
run_case 'reclaims from google-chrome-stable'   google-chrome-stable.desktop "$ALL"

# Nothing chose yet, so there is nothing to overrule: claim it.
run_case 'claims when unset'                    ''                           "$ALL"

# Already correct — a run must not rewrite the file, so that this is safe to
# call on every session start.
run_case 'no-op when already ours'              chrome-window.desktop        ''

# A different browser is a deliberate choice about which browser you use, not
# drift about where a Chrome window opens.
run_case 'leaves firefox alone'                 firefox.desktop              ''
run_case 'leaves an unknown browser alone'      zen-browser.desktop          ''

# The five keys drift independently, so the decision is made per key: repair the
# one Chrome took, leave the deliberate choice, skip the ones already correct.
: >"$log"
STUB_CURRENT=chrome-window.desktop \
    STUB_HTML=google-chrome.desktop \
    STUB_HTTPS=firefox.desktop \
    STUB_LOG=$log \
    XDG_DATA_HOME=$test_root/share \
    PATH=$bin \
    "$handler"
actual=$(tr '\n' ' ' <"$log" | sed 's/ $//')
if [ "$actual" != 'text/html' ]; then
    printf 'FAIL: mixed state repairs only the key Chrome took\n  expected: [text/html]\n  actual:   [%s]\n' \
        "$actual" >&2
    failures=$((failures + 1))
fi

# Guards: without Chrome, or without the entry, pointing http at the handler
# would leave links with nothing that can serve them.
: >"$log"
rm -f "$bin/google-chrome-stable"
STUB_CURRENT=google-chrome.desktop STUB_LOG=$log \
    XDG_DATA_HOME=$test_root/share PATH=$bin "$handler"
if [ -s "$log" ]; then
    printf 'FAIL: must not claim http when Chrome is absent\n' >&2
    failures=$((failures + 1))
fi
printf '#!/bin/sh\nexit 0\n' >"$bin/google-chrome-stable"
chmod +x "$bin/google-chrome-stable"

: >"$log"
rm -f "$test_root/share/applications/chrome-window.desktop"
STUB_CURRENT=google-chrome.desktop STUB_LOG=$log \
    XDG_DATA_HOME=$test_root/share PATH=$bin "$handler"
if [ -s "$log" ]; then
    printf 'FAIL: must not claim http when the entry is not installed\n' >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'set-default-browser: %d test(s) failed\n' "$failures" >&2
    exit 1
fi

printf 'set-default-browser: all tests passed\n'
