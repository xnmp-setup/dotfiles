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

# A mixed group whose survivors have all lost it (here the compositor had also
# grouped Chrome with Ghostty) cannot say which survivor to rebuild it around,
# so only the Chrome member's workspace is restored. The other windows are
# never targeted, moved, or staged temporarily.
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
  if [[ "$1 $2" == "monitors -j" ]]; then
    echo '[{"activeWorkspace":{"id":2,"name":"2"}}]'
    return
  fi
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
  "members":["0xnew-a","0xnotes","0xghostty"],
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
  fail "mixed-group restoration tried to rebuild a group that no longer exists"
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
# The saved Chrome + Notes group is rebuilt around Notes, which this static
# fake cannot show happening (the stateful fake below covers rejoining), so
# only the dispatches are checked here, not the reported outcome.
chrome_layout_restore "$snapshot" 2>/dev/null || true
grep -Fq 'workspace = "4"' "$dispatch_log" ||
  fail "ungrouped Chrome window did not return to workspace 4"
if grep -E 'hl\.dsp\.window\.move\(.*address:0x(notes|ghostty)' "$dispatch_log"; then
  fail "full restoration tried to move a non-Chrome window"
fi
grep -Fq 'hl.dsp.focus({ window = "address:0xnotes" })' "$dispatch_log" ||
  fail "global focus did not return to the originally active window"

# --- Rejoining a mixed group -------------------------------------------------
# A stateful fake: groups, the visible tab, focus, two monitors with the
# workspace each shows, and each window's neighbour per direction (Hyprland's
# into_group joins whatever group is on that side).
state_file="$test_root/state.json"
active_file="$test_root/active"
view_file="$test_root/view"
sweep_before_join=0
declare -A fake_neighbor=()

fake_state() { jq -c "$1" "${@:2}" "$state_file" >"$state_file.new" && mv "$state_file.new" "$state_file"; }

hyprctl() {
  local expr address
  case "$1 $2" in
    "clients -j") cat "$state_file"; return ;;
    "activewindow -j") jq -n --arg a "$(cat "$active_file")" '{address: $a}'; return ;;
    "monitors -j")
      jq -c '.focused as $f | .monitors | map({name, focused: (.name == $f),
        activeWorkspace: {id: (.shows | tonumber), name: .shows}})' "$view_file"; return ;;
    "workspaces -j")
      jq -c '.owner | to_entries | map({id: (.key | tonumber), name: .key, monitor: .value})' \
        "$view_file"; return ;;
  esac
  [[ "$1" == dispatch ]] || return 1
  expr="$2"
  echo "$expr" >>"$dispatch_log"
  [[ "$expr" =~ address:(0x[a-z0-9-]+) ]] && address="${BASH_REMATCH[1]}"
  if [[ "$expr" == *"out_of_group = true"* ]]; then
    fake_state '
      (map(select(.address == $a)) | first | .grouped) as $g
      | map(if .address == $a then .grouped = [] | .visible = true
            elif (.address as $x | $g | index($x)) then .grouped = ($g - [$a])
            else . end)
      | (map(select(.address as $x | ($g - [$a]) | index($x))) | map(.visible) | any) as $shown
      | if $shown or (($g - [$a]) | length) == 0 then .
        else map(if .address == ($g - [$a])[0] then .visible = true else . end) end' \
      --arg a "$address"
  elif [[ "$expr" =~ (into_group|into_or_create_group)\ =\ \"([a-z]+)\" ]]; then
    # Hyprland's directional lookup sees only windows on a shown workspace --
    # on any monitor. A joined window moves to the group's workspace, goes in
    # after the group's current tab, becomes the current tab, and takes focus;
    # into_or_create_group first groups a lone neighbour. With
    # sweep_before_join, group_actions.lua's lone-group sweep lands first.
    local how="${BASH_REMATCH[1]}"
    local target="${fake_neighbor["$address:${BASH_REMATCH[2]}"]:-}"
    ((sweep_before_join)) &&
      fake_state 'map(if (.grouped | length) == 1 then .grouped = [] else . end)'
    if [[ -z "$target" ]] || ! jq -e --arg t "$target" --slurpfile view "$view_file" '
      (.[] | select(.address == $t) | .workspace.name) as $w
      | $view[0].monitors | any(.shows == $w)' "$state_file" &>/dev/null; then
      echo ok; return
    fi
    if [[ "$how" == into_or_create_group ]]; then
      fake_state 'map(if .address == $t and (.grouped | length) == 0
                      then .grouped = [$t] | .visible = true else . end)' --arg t "$target"
    fi
    fake_state '
      (map(select(.address == $t)) | first) as $target
      | $target.grouped as $g
      | if ($g | length) == 0 then . else
          ([$g[] as $m | map(select(.address == $m)) | first | select(.visible) | $m]
           | first // $g[0]) as $current
          | ($g | index($current)) as $at
          | ($g[:$at + 1] + [$a] + $g[$at + 1:]) as $n
          | map(if .address as $x | $n | index($x)
                then .grouped = $n | .visible = (.address == $a) else . end)
          | map(if .address == $a then .workspace = $target.workspace else . end)
        end' --arg a "$address" --arg t "$target"
    if jq -e --arg a "$address" '.[] | select(.address == $a) | select((.grouped | length) > 0)' \
      "$state_file" &>/dev/null; then
      echo "$address" >"$active_file"
    fi
  elif [[ "$expr" =~ hl\.dsp\.focus\(\{\ workspace\ =\ \"([^\"]+)\" ]]; then
    # Shown on the monitor that owns it, which takes focus.
    jq -c --arg w "${BASH_REMATCH[1]}" '
      (.owner[$w] // .focused) as $m
      | .focused = $m | .monitors |= map(if .name == $m then .shows = $w else . end)' \
      "$view_file" >"$view_file.new" && mv "$view_file.new" "$view_file"
    echo "workspace:${BASH_REMATCH[1]}" >>"$test_root/views"
  elif [[ "$expr" =~ hl\.dsp\.focus\(\{\ monitor\ =\ \"([^\"]+)\" ]]; then
    jq -c --arg m "${BASH_REMATCH[1]}" '.focused = $m' \
      "$view_file" >"$view_file.new" && mv "$view_file.new" "$view_file"
    echo "monitor:${BASH_REMATCH[1]}" >>"$test_root/views"
  elif [[ "$expr" =~ workspace\ =\ \"([^\"]+)\" ]]; then
    fake_state 'map(if .address == $a then .workspace = {name: $w} else . end)' \
      --arg a "$address" --arg w "${BASH_REMATCH[1]}"
  elif [[ "$expr" =~ group\.active\(\{\ index\ =\ ([0-9]+) ]]; then
    fake_state '
      (map(select(.address == $a)) | first | .grouped) as $g
      | map(if .address as $x | $g | index($x)
            then .visible = (.address == $g[$i - 1]) else . end)' \
      --arg a "$address" --argjson i "${BASH_REMATCH[1]}"
  elif [[ "$expr" == *"hl.dsp.focus("* ]]; then
    # Focusing a background tab does not raise it: focus stays where it was.
    if jq -e --arg a "$address" \
      '.[] | select(.address == $a) | select(.visible)' "$state_file" &>/dev/null; then
      echo "$address" >"$active_file"
    fi
  elif [[ "$expr" =~ move_window\(\{\ forward\ =\ (true|false) ]]; then
    local focused; focused=$(cat "$active_file")
    if ! jq -e --arg a "$focused" \
      '.[] | select(.address == $a) | select((.grouped | length) > 1)' \
      "$state_file" &>/dev/null; then
      echo "warning: Window not in a group"; return
    fi
    fake_state '
      (map(select(.address == $a)) | first | .grouped) as $g
      | ($g | index($a)) as $i
      | (if $f then $i + 1 else $i - 1 end) as $j
      | ($g | .[$i] = $g[$j] | .[$j] = $a) as $n
      | map(if .address as $x | $g | index($x) then .grouped = $n else . end)' \
      --arg a "$focused" --argjson f "${BASH_REMATCH[1]}"
  fi
  echo ok
}

# Codex | chrome-a | explorer was the saved group, chrome-a visible. After the
# restart the survivors are still grouped; the new Chrome window is a tile to
# their right.
reset_mixed_state() {
  cat >"$state_file" <<'JSON'
[
  {"address":"0xcodex","grouped":["0xcodex","0xexplorer"],"visible":true,
   "workspace":{"name":"1"},"at":[0,0],"size":[100,100]},
  {"address":"0xexplorer","grouped":["0xcodex","0xexplorer"],"visible":false,
   "workspace":{"name":"1"},"at":[0,0],"size":[100,100]},
  {"address":"0xnew-a","grouped":[],"visible":true,
   "workspace":{"name":"1"},"at":[100,0],"size":[100,100]},
  {"address":"0xother","grouped":["0xother"],"visible":true,
   "workspace":{"name":"1"},"at":[200,0],"size":[100,100]}
]
JSON
  echo 0xcodex >"$active_file"
  # DP-2 (focused) shows 1 and also owns 2; DP-1 shows 6.
  cat >"$view_file" <<'JSON'
{"monitors":[{"name":"DP-1","shows":"6"},{"name":"DP-2","shows":"1"}],
 "focused":"DP-2","owner":{"1":"DP-2","2":"DP-2","6":"DP-1"}}
JSON
  sweep_before_join=0
  : >"$dispatch_log"
  : >"$test_root/views"
}
mixed_group='{
  "members":["0xcodex","0xnew-a","0xexplorer"],
  "workspace":"1",
  "visible_address":"0xnew-a"
}'
mixed_chrome='["0xnew-a"]'
group_of() { jq -c --arg a "$1" '.[] | select(.address == $a) | .grouped' "$state_file"; }
visible_of() { jq -r --arg a "$1" '.[] | select(.address == $a) | .visible' "$state_file"; }

# Rejoins the survivors' group, at its saved tab position, and shows it.
reset_mixed_state
fake_neighbor=(["0xnew-a:left"]="0xcodex")
chrome_layout_restore_group "$mixed_group" 4 "$mixed_chrome" ||
  fail "rejoining a mixed group reported failure"
[[ "$(group_of 0xcodex)" == '["0xcodex","0xnew-a","0xexplorer"]' ]] ||
  fail "Chrome did not rejoin at its saved tab position: $(group_of 0xcodex)"
[[ "$(visible_of 0xnew-a)" == true ]] ||
  fail "the tab that was showing before the restart is not showing again"
if grep -E 'window\.move\(.*address:0x(codex|explorer)' "$dispatch_log"; then
  fail "rejoining moved a surviving application window"
fi

# A join that lands in some other group is undone: Chrome is left tiled on its
# workspace, and the other group is left as it was.
reset_mixed_state
fake_neighbor=(["0xnew-a:left"]="0xother")
if chrome_layout_restore_group "$mixed_group" 5 "$mixed_chrome" 2>/dev/null; then
  fail "a rejoin into the wrong group was reported as successful"
fi
[[ "$(group_of 0xnew-a)" == '[]' ]] ||
  fail "Chrome was left in a group it never belonged to: $(group_of 0xnew-a)"
[[ "$(group_of 0xother)" == '["0xother"]' ]] ||
  fail "undoing a wrong join changed the other group: $(group_of 0xother)"
[[ "$(group_of 0xcodex)" == '["0xcodex","0xexplorer"]' ]] ||
  fail "a failed rejoin changed the survivors' group"

# Survivors no longer grouped (every other member closed): nothing to rejoin,
# and nothing is attempted.
reset_mixed_state
fake_state 'map(.grouped = [])'
fake_neighbor=(["0xnew-a:left"]="0xcodex")
chrome_layout_restore_group "$mixed_group" 6 "$mixed_chrome" ||
  fail "a group with nothing left to rejoin was reported as a failure"
if grep -Fq 'into_group' "$dispatch_log"; then
  fail "tried to rejoin a group that no longer exists"
fi

# Two Chrome tabs in one group. Hyprland inserts each joined tab after the
# current one, so the rejoined tabs land together in the middle and have to be
# placed one at a time to come back in their saved order.
reset_mixed_state
cat >"$state_file" <<'JSON'
[
  {"address":"0xs1","grouped":["0xs1","0xs2"],"visible":true,
   "workspace":{"name":"1"},"at":[0,0],"size":[100,100]},
  {"address":"0xs2","grouped":["0xs1","0xs2"],"visible":false,
   "workspace":{"name":"1"},"at":[0,0],"size":[100,100]},
  {"address":"0xc1","grouped":[],"visible":true,
   "workspace":{"name":"1"},"at":[100,0],"size":[100,100]},
  {"address":"0xc2","grouped":[],"visible":true,
   "workspace":{"name":"1"},"at":[100,100],"size":[100,100]}
]
JSON
fake_neighbor=(["0xc1:left"]="0xs1" ["0xc2:left"]="0xs1")
two_tab_group='{"members":["0xs1","0xs2","0xc1","0xc2"],"workspace":"1","visible_address":"0xs1"}'
chrome_layout_restore_group "$two_tab_group" 7 '["0xc1","0xc2"]' ||
  fail "rejoining two Chrome tabs reported failure"
[[ "$(group_of 0xs1)" == '["0xs1","0xs2","0xc1","0xc2"]' ]] ||
  fail "two rejoined Chrome tabs are out of order: $(group_of 0xs1)"
[[ "$(visible_of 0xs1)" == true ]] ||
  fail "the saved visible tab is not showing after a two-tab rejoin"

# A group on a workspace that is not on screen: Hyprland cannot see a
# neighbour there, so the workspace is shown for the rejoin and the screen is
# put back afterwards.
reset_mixed_state
fake_state 'map(.workspace = {name: "2"})'
fake_neighbor=(["0xnew-a:left"]="0xcodex")
hidden_group=$(jq -c '.workspace = "2"' <<<"$mixed_group")
chrome_layout_restore_group "$hidden_group" 8 "$mixed_chrome" ||
  fail "rejoining on a hidden workspace reported failure"
[[ "$(group_of 0xcodex)" == '["0xcodex","0xnew-a","0xexplorer"]' ]] ||
  fail "Chrome did not rejoin a group on a hidden workspace: $(group_of 0xcodex)"
[[ "$(jq -c '[.monitors[].shows, .focused]' "$view_file")" == '["6","1","DP-2"]' ]] ||
  fail "the screen was not put back: $(cat "$view_file")"
[[ "$(cat "$test_root/views")" == $'workspace:2\nmonitor:DP-2\nworkspace:1\nmonitor:DP-2' ]] ||
  fail "unexpected view changes: $(cat "$test_root/views")"

# Chrome plus one application: the lone survivor lost its group when Chrome
# closed (group_actions.lua dissolves groups of one), so the group is rebuilt
# around it in place.
reset_mixed_state
cat >"$state_file" <<'JSON'
[
  {"address":"0xnotes","grouped":[],"visible":true,
   "workspace":{"name":"1"},"at":[0,0],"size":[100,100]},
  {"address":"0xnew-a","grouped":[],"visible":true,
   "workspace":{"name":"1"},"at":[100,0],"size":[100,100]},
  {"address":"0xother","grouped":[],"visible":true,
   "workspace":{"name":"1"},"at":[200,0],"size":[100,100]}
]
JSON
fake_neighbor=(["0xnew-a:left"]="0xnotes")
pair_group='{"members":["0xnotes","0xnew-a"],"workspace":"1","visible_address":"0xnew-a"}'
chrome_layout_restore_group "$pair_group" 9 "$mixed_chrome" ||
  fail "rebuilding a Chrome + one-app group reported failure"
[[ "$(group_of 0xnotes)" == '["0xnotes","0xnew-a"]' ]] ||
  fail "the Chrome + one-app group was not rebuilt: $(group_of 0xnotes)"
[[ "$(visible_of 0xnew-a)" == true ]] ||
  fail "the rebuilt pair does not show the saved tab"
if grep -E 'window\.move\(.*address:0xnotes' "$dispatch_log"; then
  fail "rebuilding the pair moved the surviving application"
fi

# Building that group towards the wrong neighbour is undone.
pair_state=$(jq -c 'map(.grouped = [] | .visible = true)' "$state_file")
reset_mixed_state
echo "$pair_state" >"$state_file"
fake_neighbor=(["0xnew-a:left"]="0xother")
if chrome_layout_restore_group "$pair_group" 10 "$mixed_chrome" 2>/dev/null; then
  fail "building a group with the wrong neighbour was reported as successful"
fi
[[ "$(group_of 0xnew-a)" == '[]' ]] ||
  fail "Chrome was left grouped with the wrong neighbour: $(group_of 0xnew-a)"

# The survivor is still in a one-member group when the rejoin looks, and
# group_actions.lua's sweep dissolves it just before the join lands (the usual
# case when Chrome was tabbed into the terminal set-theme ran from).
reset_mixed_state
cat >"$state_file" <<'JSON'
[
  {"address":"0xghostty","grouped":["0xghostty"],"visible":true,
   "workspace":{"name":"1"},"at":[0,0],"size":[100,100]},
  {"address":"0xnew-a","grouped":[],"visible":true,
   "workspace":{"name":"1"},"at":[100,0],"size":[100,100]}
]
JSON
sweep_before_join=1
fake_neighbor=(["0xnew-a:left"]="0xghostty")
terminal_group='{"members":["0xghostty","0xnew-a"],"workspace":"1","visible_address":"0xghostty"}'
chrome_layout_restore_group "$terminal_group" 11 "$mixed_chrome" ||
  fail "rejoining a terminal whose lone group was swept reported failure"
[[ "$(group_of 0xghostty)" == '["0xghostty","0xnew-a"]' ]] ||
  fail "Chrome did not rejoin the terminal after the sweep: $(group_of 0xghostty)"

# The neighbour in that direction is a group on the other monitor. Joining
# pulls Chrome onto that workspace; undoing it must put Chrome back.
reset_mixed_state
cat >"$state_file" <<'JSON'
[
  {"address":"0xcodex","grouped":["0xcodex","0xexplorer"],"visible":true,
   "workspace":{"name":"1"},"at":[0,0],"size":[100,100]},
  {"address":"0xexplorer","grouped":["0xcodex","0xexplorer"],"visible":false,
   "workspace":{"name":"1"},"at":[0,0],"size":[100,100]},
  {"address":"0xnew-a","grouped":[],"visible":true,
   "workspace":{"name":"1"},"at":[100,0],"size":[100,100]},
  {"address":"0xfar","grouped":["0xfar","0xfar2"],"visible":true,
   "workspace":{"name":"6"},"at":[-200,0],"size":[100,100]},
  {"address":"0xfar2","grouped":["0xfar","0xfar2"],"visible":false,
   "workspace":{"name":"6"},"at":[-200,0],"size":[100,100]}
]
JSON
fake_neighbor=(["0xnew-a:left"]="0xfar")
if chrome_layout_restore_group "$mixed_group" 12 "$mixed_chrome" 2>/dev/null; then
  fail "a join into another monitor's group was reported as successful"
fi
[[ "$(jq -r '.[] | select(.address == "0xnew-a") | .workspace.name' "$state_file")" == 1 ]] ||
  fail "an undone join left Chrome on the other monitor's workspace"
[[ "$(group_of 0xfar)" == '["0xfar","0xfar2"]' ]] ||
  fail "undoing the join changed the other monitor's group: $(group_of 0xfar)"

# A hidden workspace on the monitor that does not have focus: only that
# monitor is switched and put back, and focus returns to the focused one.
reset_mixed_state
fake_state 'map(.workspace = {name: "7"})'
jq -c '.owner["7"] = "DP-1"' "$view_file" >"$view_file.new" && mv "$view_file.new" "$view_file"
fake_neighbor=(["0xnew-a:left"]="0xcodex")
chrome_layout_restore_group "$(jq -c '.workspace = "7"' <<<"$mixed_group")" 13 "$mixed_chrome" ||
  fail "rejoining on the other monitor's hidden workspace reported failure"
[[ "$(group_of 0xcodex)" == '["0xcodex","0xnew-a","0xexplorer"]' ]] ||
  fail "Chrome did not rejoin on the other monitor: $(group_of 0xcodex)"
[[ "$(jq -c '[.monitors[].shows, .focused]' "$view_file")" == '["6","1","DP-2"]' ]] ||
  fail "the other monitor was not put back: $(cat "$view_file")"

# Chrome restored none of the group's windows: the survivors are left alone,
# with no workspace switch and no change to the tab they show.
reset_mixed_state
fake_state 'map(.workspace = {name: "2"})'
chrome_layout_rejoin_mixed_group "$(jq -c '.workspace = "2"' <<<"$mixed_group")" \
  '[]' '["0xcodex","0xexplorer"]' ||
  fail "a group with no Chrome window back reported failure"
[[ ! -s "$dispatch_log" ]] ||
  fail "a group with no Chrome window back was touched: $(cat "$dispatch_log")"

# A window that was not in the saved group sits in it now. The rejoined tab
# still lands right after its saved neighbour, not at its saved index.
reset_mixed_state
cat >"$state_file" <<'JSON'
[
  {"address":"0xstranger","grouped":["0xstranger","0xcodex","0xexplorer"],"visible":true,
   "workspace":{"name":"1"},"at":[0,0],"size":[100,100]},
  {"address":"0xcodex","grouped":["0xstranger","0xcodex","0xexplorer"],"visible":false,
   "workspace":{"name":"1"},"at":[0,0],"size":[100,100]},
  {"address":"0xexplorer","grouped":["0xstranger","0xcodex","0xexplorer"],"visible":false,
   "workspace":{"name":"1"},"at":[0,0],"size":[100,100]},
  {"address":"0xnew-a","grouped":[],"visible":true,
   "workspace":{"name":"1"},"at":[100,0],"size":[100,100]}
]
JSON
fake_neighbor=(["0xnew-a:left"]="0xcodex")
chrome_layout_restore_group "$mixed_group" 14 "$mixed_chrome" ||
  fail "rejoining beside an unsaved tab reported failure"
[[ "$(group_of 0xcodex)" == '["0xstranger","0xcodex","0xnew-a","0xexplorer"]' ]] ||
  fail "an unsaved tab shifted the rejoined one: $(group_of 0xcodex)"

# The relaunch goes through the compositor when there is one.
: >"$dispatch_log"
chrome_layout_launch /usr/bin/google-chrome-stable ||
  fail "launch through Hyprland reported failure"
grep -Fq 'hl.dsp.exec_cmd("/usr/bin/google-chrome-stable")' "$dispatch_log" ||
  fail "the browser was not launched through Hyprland"
(
  unset HYPRLAND_INSTANCE_SIGNATURE
  if chrome_layout_launch /usr/bin/google-chrome-stable; then
    fail "launch claimed Hyprland outside a Hyprland session"
  fi
)

# Restored windows are found whatever the case of their class.
cat >"$state_file" <<'JSON'
[{"address":"0xx11","class":"Google-chrome","title":"Alpha","mapped":true}]
JSON
found=$(chrome_layout_current_windows '{"classes":["google-chrome"]}')
[[ "$found" == '[{"address":"0xx11","title":"Alpha"}]' ]] ||
  fail "an XWayland Chrome window was not recognised: $found"

echo "Chrome layout tests passed"
