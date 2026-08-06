# Preserve Hyprland placement, groups, and focus across a Chrome restart.

chrome_layout_snapshot() {
  local process_name="$1"
  local clients active_address pid_lines browser_pids snapshot

  [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || return 1
  command -v hyprctl &>/dev/null || return 1
  command -v jq &>/dev/null || return 1

  pid_lines=$(pgrep -x "$process_name") || return 1
  browser_pids=$(jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)' <<<"$pid_lines")
  clients=$(hyprctl clients -j 2>/dev/null) || return 1
  active_address=$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty')

  snapshot=$(jq -n \
    --argjson clients "$clients" \
    --argjson browser_pids "$browser_pids" \
    --arg active_address "$active_address" '
      def workspace_ref:
        if (.name // "") | startswith("special:") then .name
        elif (.id // 0) > 0 then (.id | tostring)
        elif (.name // "") | startswith("name:") then .name
        else "name:" + (.name // "")
        end;

      $clients as $all
      | [ $all[]
          | select(.mapped // true)
          | select(.pid as $pid | $browser_pids | index($pid))
        ] as $browser
      | {
          active_address: $active_address,
          classes: ($browser | map(.class) | unique),
          windows: ($browser | map({
            address,
            title: (.title // ""),
            workspace: (.workspace | workspace_ref),
            grouped: (.grouped // [])
          })),
          groups: ([ $browser[]
            | (.grouped // []) as $members
            | select(($members | length) > 1)
            | {
                key: ($members | join("|")),
                members: $members,
                workspace: (.workspace | workspace_ref),
                visible_address: (([
                  $all[]
                  | select(.address as $address | $members | index($address))
                  | select(.visible // false)
                ] | first | .address) // $members[0])
              }
          ] | unique_by(.key))
        }
      | select((.windows | length) > 0)
    ') || return 1
  [[ -n "$snapshot" ]] || return 1
  echo "$snapshot"
}

chrome_layout_assign_windows() {
  local snapshot="$1"
  local current="$2"

  jq -n --argjson snapshot "$snapshot" --argjson current "$current" '
    reduce $snapshot.windows[] as $old (
      { available: $current, pairs: [], unmatched: [], title_matches: 0 };
      (.available | map(.title) | index($old.title)) as $title_index
      | if $title_index != null then
          .pairs += [{
            old_address: $old.address,
            new_address: .available[$title_index].address
          }]
          | .title_matches += 1
          | .available |= del(.[$title_index])
        else
          .unmatched += [$old]
        end
    )
    | reduce .unmatched[] as $old (.;
        if (.available | length) > 0 then
          .pairs += [{
            old_address: $old.address,
            new_address: .available[0].address
          }]
          | .available |= del(.[0])
        else . end
      )
    | { pairs, title_matches }
  '
}

chrome_layout_current_windows() {
  local snapshot="$1"
  local clients

  clients=$(hyprctl clients -j 2>/dev/null) || return 1
  jq -c --argjson snapshot "$snapshot" '[
    .[]
    | select(.mapped // true)
    | select(.class as $class | $snapshot.classes | index($class))
    | { address, title: (.title // "") }
  ]' <<<"$clients"
}

# Wait for Chrome to restore the old number of windows. Titles are allowed to
# settle so windows can be matched by their active tabs; if a title changed,
# the remaining windows are paired in deterministic creation order.
chrome_layout_wait_for_windows() {
  local snapshot="$1"
  local timeout_seconds="${2:-20}"
  local expected restore_deadline current assignment current_count title_matches
  local current_signature previous_signature="" stable_samples=0

  expected=$(jq '.windows | length' <<<"$snapshot")
  restore_deadline=$(($(date +%s) + timeout_seconds))

  while :; do
    current=$(chrome_layout_current_windows "$snapshot") || current='[]'
    current_count=$(jq 'length' <<<"$current")
    if ((current_count >= expected)); then
      assignment=$(chrome_layout_assign_windows "$snapshot" "$current")
      title_matches=$(jq '.title_matches' <<<"$assignment")
      current_signature=$(jq -c 'map([.address, .title])' <<<"$current")
      if [[ "$current_signature" == "$previous_signature" ]]; then
        ((stable_samples += 1))
      else
        previous_signature="$current_signature"
        stable_samples=0
      fi
      if ((title_matches == expected || stable_samples >= 30 || \
        $(date +%s) >= restore_deadline)); then
        jq -n --argjson current "$current" --argjson assignment "$assignment" \
          '{ current: $current, pairs: $assignment.pairs }'
        return 0
      fi
    fi

    if (($(date +%s) >= restore_deadline)); then
      if ((current_count > 0)); then
        assignment=$(chrome_layout_assign_windows "$snapshot" "$current")
        echo "Chrome restored only $current_count of $expected window(s); restoring those available" >&2
        jq -n --argjson current "$current" --argjson assignment "$assignment" \
          '{ current: $current, pairs: $assignment.pairs }'
        return 0
      fi
      echo "Chrome restored 0 of $expected window(s)" >&2
      return 1
    fi
    sleep 0.1
  done
}

chrome_layout_lua_string() {
  jq -Rn --arg value "$1" '$value'
}

chrome_layout_dispatch() {
  local expression="$1"
  local output

  output=$(hyprctl dispatch "$expression" 2>&1)
  [[ "$output" == "ok" ]] || {
    echo "Hyprland dispatch failed: $output" >&2
    return 1
  }
}

chrome_layout_move_to_workspace() {
  local address="$1"
  local workspace="$2"
  local window_lua workspace_lua

  window_lua=$(chrome_layout_lua_string "address:$address")
  workspace_lua=$(chrome_layout_lua_string "$workspace")
  chrome_layout_dispatch \
    "hl.dsp.window.move({ workspace = $workspace_lua, follow = false, window = $window_lua })"
}

chrome_layout_group_direction() {
  local from="$1"
  local to="$2"
  local clients

  clients=$(hyprctl clients -j 2>/dev/null) || return 1
  jq -r --arg from "$from" --arg to "$to" '
    ([.[] | select(.address == $from)] | first) as $from_window
    | ([.[] | select(.address == $to)] | first) as $to_window
    | select($from_window != null and $to_window != null)
    | (($to_window.at[0] + $to_window.size[0] / 2)
       - ($from_window.at[0] + $from_window.size[0] / 2)) as $dx
    | (($to_window.at[1] + $to_window.size[1] / 2)
       - ($from_window.at[1] + $from_window.size[1] / 2)) as $dy
    | if ($dx | fabs) >= ($dy | fabs)
      then if $dx < 0 then "left" else "right" end
      else if $dy < 0 then "up" else "down" end
      end
  ' <<<"$clients"
}

chrome_layout_restore_group() {
  local group="$1"
  local group_number="$2"
  local workspace visible_address temp_workspace
  local clients available existing_groups member anchor direction window_lua direction_lua
  local group_index anchor_lua

  workspace=$(jq -r '.workspace' <<<"$group")
  visible_address=$(jq -r '.visible_address' <<<"$group")
  temp_workspace="special:chrome-theme-restore-${BASHPID}-$group_number"
  clients=$(hyprctl clients -j 2>/dev/null) || return 1
  available=$(jq -c --argjson group "$group" '[
    $group.members[] as $member
    | select([.[] | .address] | index($member))
    | $member
  ]' <<<"$clients")

  if (($(jq 'length' <<<"$available") < 2)); then
    member=$(jq -r 'first // empty' <<<"$available")
    [[ -z "$member" ]] || chrome_layout_move_to_workspace "$member" "$workspace"
    return
  fi

  # A group can contain non-Chrome windows that survived the restart. Dissolve
  # each surviving group once, then rebuild the original member set together.
  existing_groups=$(jq -c --argjson members "$available" '[
    .[]
    | select(.address as $address | $members | index($address))
    | select(((.grouped // []) | length) > 1)
    | { key: (.grouped | join("|")), address }
  ] | unique_by(.key)' <<<"$clients")
  while IFS= read -r member; do
    window_lua=$(chrome_layout_lua_string "address:$member")
    chrome_layout_dispatch "hl.dsp.group.toggle({ window = $window_lua })" || return 1
  done < <(jq -r '.[].address' <<<"$existing_groups")

  while IFS= read -r member; do
    chrome_layout_move_to_workspace "$member" "$temp_workspace" || return 1
  done < <(jq -r '.[]' <<<"$available")

  anchor=$(jq -r '.[0]' <<<"$available")
  while IFS= read -r member; do
    direction=$(chrome_layout_group_direction "$member" "$anchor") || return 1
    [[ -n "$direction" ]] || return 1
    window_lua=$(chrome_layout_lua_string "address:$member")
    direction_lua=$(chrome_layout_lua_string "$direction")
    chrome_layout_dispatch \
      "hl.dsp.window.move({ into_or_create_group = $direction_lua, window = $window_lua })" ||
      return 1
  done < <(jq -r '.[1:][]' <<<"$available")

  # Moving one member of a native group moves the complete group.
  chrome_layout_move_to_workspace "$anchor" "$workspace" || return 1

  clients=$(hyprctl clients -j 2>/dev/null) || return 1
  group_index=$(jq -r --arg anchor "$anchor" --arg visible "$visible_address" '
    [.[] | select(.address == $anchor)] | first
    | (.grouped // []) | index($visible)
    | if . == null then empty else . + 1 end
  ' <<<"$clients")
  if [[ -n "$group_index" ]]; then
    anchor_lua=$(chrome_layout_lua_string "address:$anchor")
    chrome_layout_dispatch \
      "hl.dsp.group.active({ index = $group_index, window = $anchor_lua })" ||
      return 1
  fi
}

chrome_layout_resolve_snapshot() {
  local snapshot="$1"
  local pairs="$2"

  jq --argjson pairs "$pairs" '
    . as $snapshot
    | ($snapshot.windows | map(.address)) as $browser_addresses
    | def mapped($address):
      ([ $pairs[] | select(.old_address == $address) | .new_address ] | first)
      // null;
    def is_browser($address): $browser_addresses | index($address) != null;
    def resolve_member($address):
      if is_browser($address) then mapped($address) else $address end;

    .active_address = resolve_member(.active_address)
    | .windows |= map(
        . as $window
        | mapped($window.address) as $new_address
        | select($new_address != null)
        | .address = $new_address
      )
    | .groups |= map(
        . as $group
        | ($group.members | map(resolve_member(.)) | map(select(. != null))) as $members
        | (resolve_member($group.visible_address) // $members[0]) as $visible_address
        | .members = $members
        | .visible_address = $visible_address
      )
  ' <<<"$snapshot"
}

chrome_layout_restore() {
  local snapshot="$1"
  local timeout_seconds="${2:-20}"
  local assignment plan grouped_addresses window group group_number active_address active_lua
  local address workspace
  local restore_failures=0

  assignment=$(chrome_layout_wait_for_windows "$snapshot" "$timeout_seconds") || return 1
  plan=$(chrome_layout_resolve_snapshot "$snapshot" "$(jq '.pairs' <<<"$assignment")")
  grouped_addresses=$(jq -c '[.groups[].members[]] | unique' <<<"$plan")

  while IFS= read -r window; do
    address=$(jq -r '.address' <<<"$window")
    if ! jq -e --arg address "$address" 'index($address) != null' \
      <<<"$grouped_addresses" &>/dev/null; then
      workspace=$(jq -r '.workspace' <<<"$window")
      chrome_layout_move_to_workspace "$address" "$workspace" || ((restore_failures += 1))
    fi
  done < <(jq -c '.windows[]' <<<"$plan")

  group_number=0
  while IFS= read -r group; do
    ((group_number += 1))
    chrome_layout_restore_group "$group" "$group_number" || ((restore_failures += 1))
  done < <(jq -c '.groups[]' <<<"$plan")

  active_address=$(jq -r '.active_address // empty' <<<"$plan")
  if [[ -n "$active_address" ]] && hyprctl clients -j 2>/dev/null |
    jq -e --arg address "$active_address" '.[] | select(.address == $address)' \
      &>/dev/null; then
    active_lua=$(chrome_layout_lua_string "address:$active_address")
    chrome_layout_dispatch "hl.dsp.focus({ window = $active_lua })" ||
      ((restore_failures += 1))
  fi

  ((restore_failures == 0))
}
