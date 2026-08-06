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

# Exercise group reconstruction with one restored Chrome window and one
# surviving non-Chrome window. The fake compositor exposes the group only after
# receiving the into_or_create_group dispatch.
group_state_file="$test_root/grouped"
dispatch_log="$test_root/dispatch.log"
fake_clients_ungrouped='[
  {"address":"0xnew-a","grouped":[],"at":[100,0],"size":[100,100]},
  {"address":"0xnotes","grouped":[],"at":[0,0],"size":[100,100]},
  {"address":"0xnew-b","grouped":[],"at":[200,0],"size":[100,100]}
]'
fake_clients_grouped='[
  {"address":"0xnew-a","grouped":["0xnew-a","0xnotes"],"at":[0,0],"size":[100,100]},
  {"address":"0xnotes","grouped":["0xnew-a","0xnotes"],"at":[0,0],"size":[100,100]},
  {"address":"0xnew-b","grouped":[],"at":[200,0],"size":[100,100]}
]'

hyprctl() {
  if [[ "$1 $2" == "clients -j" ]]; then
    if [[ -f "$group_state_file" ]]; then
      echo "$fake_clients_grouped"
    else
      echo "$fake_clients_ungrouped"
    fi
    return
  fi
  if [[ "$1" == "dispatch" ]]; then
    echo "$2" >>"$dispatch_log"
    [[ "$2" == *"hl.dsp.group.toggle"* ]] && rm -f "$group_state_file"
    [[ "$2" == *"into_or_create_group"* ]] && touch "$group_state_file"
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
chrome_layout_restore_group "$group" 1

grep -Fq 'workspace = "special:chrome-theme-restore-' "$dispatch_log" ||
  fail "group members were not isolated on a temporary workspace"
grep -Fq 'into_or_create_group = "right"' "$dispatch_log" ||
  fail "group was not recreated toward its anchor"
grep -Fq 'workspace = "2"' "$dispatch_log" ||
  fail "group was not returned to its original workspace"
grep -Fq 'hl.dsp.group.active({ index = 2' "$dispatch_log" ||
  fail "the originally visible group member was not restored"

# Full orchestration also restores an ungrouped window and returns focus to the
# non-Chrome tab that was active before the restart.
rm -f "$group_state_file"
: >"$dispatch_log"
restore_pairs=$(jq '.pairs' <<<"$assignment")
chrome_layout_wait_for_windows() {
  jq -n --argjson pairs "$restore_pairs" '{pairs: $pairs}'
}
chrome_layout_restore "$snapshot"
grep -Fq 'workspace = "4"' "$dispatch_log" ||
  fail "ungrouped Chrome window did not return to workspace 4"
grep -Fq 'hl.dsp.focus({ window = "address:0xnotes" })' "$dispatch_log" ||
  fail "global focus did not return to the originally active window"

echo "Chrome layout tests passed"
