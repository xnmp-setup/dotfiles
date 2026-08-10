#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d /tmp/chrome-layout.XXXXXX)

cleanup() {
  [[ "$test_root" == /tmp/chrome-layout.* ]] && rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_json() {
  local json="$1"
  local filter="$2"
  jq -e "$filter" <<<"$json" &>/dev/null || fail "jq assertion failed: $filter"
}

# shellcheck source=lib/chrome-layout.sh
source "$repo_root/scripts/lib/chrome-layout.sh"

fake_clients='[
  {
    "address":"0xchrome-a", "pid":42, "mapped":true,
    "class":"google-chrome", "title":"Alpha",
    "workspace":{"id":2,"name":"2"},
    "grouped":["0xchrome-a","0xnotes"], "visible":false,
    "at":[0,0], "size":[100,100]
  },
  {
    "address":"0xnotes", "pid":7, "mapped":true,
    "class":"obsidian", "title":"Notes",
    "workspace":{"id":2,"name":"2"},
    "grouped":["0xchrome-a","0xnotes"], "visible":true,
    "at":[0,0], "size":[100,100]
  },
  {
    "address":"0xchrome-b", "pid":42, "mapped":true,
    "class":"google-chrome", "title":"Beta",
    "workspace":{"id":4,"name":"4"},
    "grouped":[], "visible":true,
    "at":[100,0], "size":[100,100]
  }
]'

pgrep() {
  [[ "$1" == "-x" && "$2" == "chrome" ]] || return 1
  echo 42
}

hyprctl() {
  case "$1 $2" in
    "clients -j") echo "$fake_clients" ;;
    "activewindow -j") echo '{"address":"0xnotes"}' ;;
    *) return 1 ;;
  esac
}

HYPRLAND_INSTANCE_SIGNATURE=test
snapshot=$(chrome_layout_snapshot chrome)
assert_json "$snapshot" '.windows | length == 2'
assert_json "$snapshot" '.windows[1].workspace == "4"'
assert_json "$snapshot" '.groups | length == 1'
assert_json "$snapshot" '.groups[0].members == ["0xchrome-a", "0xnotes"]'
assert_json "$snapshot" '.groups[0].visible_address == "0xnotes"'
assert_json "$snapshot" '.active_address == "0xnotes"'

current='[
  {"address":"0xnew-b","title":"Beta"},
  {"address":"0xnew-a","title":"Alpha"}
]'
assignment=$(chrome_layout_assign_windows "$snapshot" "$current")
assert_json "$assignment" '.title_matches == 2'
assert_json "$assignment" '.pairs == [
  {"old_address":"0xchrome-a","new_address":"0xnew-a"},
  {"old_address":"0xchrome-b","new_address":"0xnew-b"}
]'

# An unmatched old title must not consume a new window that exactly matches a
# later old title; extra newly opened windows are fallback candidates only.
changed_snapshot=$(jq '.windows[0].title = "Changed"' <<<"$snapshot")
extra_current='[
  {"address":"0xnew-b","title":"Beta"},
  {"address":"0xextra","title":"Extra"},
  {"address":"0xnew-a","title":"Alpha"}
]'
changed_assignment=$(chrome_layout_assign_windows "$changed_snapshot" "$extra_current")
assert_json "$changed_assignment" '.pairs | any(
  .old_address == "0xchrome-b" and .new_address == "0xnew-b"
)'
assert_json "$changed_assignment" '.pairs | any(
  .old_address == "0xchrome-a" and .new_address == "0xextra"
)'

resolved=$(chrome_layout_resolve_snapshot "$snapshot" "$(jq '.pairs' <<<"$assignment")")
assert_json "$resolved" '.groups[0].members == ["0xnew-a", "0xnotes"]'
assert_json "$resolved" '.groups[0].visible_address == "0xnotes"'
assert_json "$resolved" '.active_address == "0xnotes"'

partial=$(chrome_layout_resolve_snapshot "$snapshot" '[
  {"old_address":"0xchrome-a","new_address":"0xnew-a"}
]')
assert_json "$partial" '.windows == [{
  "address":"0xnew-a", "title":"Alpha", "workspace":"2",
  "grouped":["0xchrome-a","0xnotes"]
}]'
assert_json "$partial" '.groups[0].members == ["0xnew-a", "0xnotes"]'
assert_json "$partial" '.active_address == "0xnotes"'

# A mixed Chrome/application group restores only the Chrome member's workspace.
# The surviving application is never targeted, moved, or staged temporarily.
dispatch_log="$test_root/dispatch.log"
detached_file="$test_root/detached"
fake_clients_mixed='[
  {"address":"0xnew-a","grouped":["0xnew-a","0xghostty"],"at":[100,0],"size":[100,100]},
  {"address":"0xghostty","grouped":["0xnew-a","0xghostty"],"at":[0,0],"size":[100,100]},
  {"address":"0xnotes","grouped":[],"at":[0,0],"size":[100,100]},
  {"address":"0xnew-b","grouped":[],"at":[200,0],"size":[100,100]}
]'
fake_clients_detached='[
  {"address":"0xnew-a","grouped":[],"at":[100,0],"size":[100,100]},
  {"address":"0xghostty","grouped":[],"at":[0,0],"size":[100,100]},
  {"address":"0xnotes","grouped":[],"at":[0,0],"size":[100,100]},
  {"address":"0xnew-b","grouped":[],"at":[200,0],"size":[100,100]}
]'
fail_group_create=0

hyprctl() {
  if [[ "$1 $2" == "clients -j" ]]; then
    if [[ -f "$detached_file" ]]; then
      echo "$fake_clients_detached"
    else
      echo "$fake_clients_mixed"
    fi
    return
  fi
  if [[ "$1" == "dispatch" ]]; then
    echo "$2" >>"$dispatch_log"
    [[ "$2" == *"out_of_group = true"* ]] && touch "$detached_file"
    if ((fail_group_create)) && [[ "$2" == *"into_or_create_group"* ]]; then
      echo failed
      return
    fi
    echo ok
    return
  fi
  return 1
}

group='{
  "members":["0xnew-a","0xnotes"],
  "workspace":"2",
  "visible_address":"0xnotes"
}'
chrome_addresses='["0xnew-a","0xnew-b"]'
chrome_layout_restore_group "$group" 1 "$chrome_addresses"

grep -Fq 'workspace = "2"' "$dispatch_log" ||
  fail "mixed-group Chrome window did not return to its original workspace"
grep -Fq 'out_of_group = true' "$dispatch_log" ||
  fail "Chrome was not extracted from its compositor-created Ghostty group"
if grep -Eq 'address:0x(notes|ghostty)' "$dispatch_log"; then
  fail "mixed-group restoration dispatched against a non-Chrome window"
fi
if grep -Eq 'special:chrome-theme-restore|hl\.dsp\.group\.|into_or_create_group' \
  "$dispatch_log"; then
  fail "mixed-group restoration attempted to reconstruct the group"
fi

# Chrome-only groups still retain their group structure.
: >"$dispatch_log"
chrome_group='{
  "members":["0xnew-a","0xnew-b"],
  "workspace":"2",
  "visible_address":"0xnew-a"
}'
chrome_layout_restore_group "$chrome_group" 2 "$chrome_addresses"
grep -Fq 'workspace = "special:chrome-theme-restore-' "$dispatch_log" ||
  fail "Chrome-only group members were not isolated for reconstruction"
grep -Fq 'into_or_create_group = ' "$dispatch_log" ||
  fail "Chrome-only group was not reconstructed"
grep -Fq 'workspace = "2"' "$dispatch_log" ||
  fail "Chrome-only group was not returned to its original workspace"

# A reconstruction failure performs a best-effort return of every staged
# Chrome window instead of leaving a temporary workspace populated.
: >"$dispatch_log"
fail_group_create=1
if chrome_layout_restore_group "$chrome_group" 3 "$chrome_addresses" 2>/dev/null; then
  fail "a rejected Chrome group dispatch was reported as successful"
fi
fail_group_create=0
grep -F 'workspace = "2"' "$dispatch_log" | grep -Fq 'address:0xnew-a' ||
  fail "failed reconstruction did not return the first Chrome window"
grep -F 'workspace = "2"' "$dispatch_log" | grep -Fq 'address:0xnew-b' ||
  fail "failed reconstruction did not return the second Chrome window"

# Full orchestration also restores an ungrouped window and returns focus to the
# non-Chrome tab that was active before the restart.
: >"$dispatch_log"
rm -f "$detached_file"
restore_pairs=$(jq '.pairs' <<<"$assignment")
chrome_layout_wait_for_windows() {
  jq -n --argjson pairs "$restore_pairs" '{pairs: $pairs}'
}
chrome_layout_restore "$snapshot"
grep -Fq 'workspace = "4"' "$dispatch_log" ||
  fail "ungrouped Chrome window did not return to workspace 4"
if grep -E 'hl\.dsp\.window\.move\(.*address:0x(notes|ghostty)' "$dispatch_log"; then
  fail "full restoration tried to move a non-Chrome window"
fi
grep -Fq 'hl.dsp.focus({ window = "address:0xnotes" })' "$dispatch_log" ||
  fail "global focus did not return to the originally active window"

echo "Chrome layout tests passed"
