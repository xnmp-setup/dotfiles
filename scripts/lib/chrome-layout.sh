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
  # Case-insensitive: the same browser reports "google-chrome" as a Wayland
  # client and "Google-chrome" under XWayland, and which one a restart yields
  # depends on the environment it was launched from.
  jq -c --argjson snapshot "$snapshot" '
    ($snapshot.classes | map(strings | ascii_downcase)) as $classes
    | [ .[]
        | select(.mapped // true)
        | select((.class // "" | ascii_downcase) as $class | $classes | index($class))
        | { address, title: (.title // "") }
      ]' <<<"$clients"
}

# Start the browser as a child of the compositor when one is running, so it
# gets the session environment it gets at login. Launched from whatever ran
# set-theme instead, it inherits that caller's environment: a shell started by
# a systemd user service lacks XDG_SESSION_TYPE, Chromium's platform hint then
# falls back to X11, and the restarted browser comes up under XWayland with a
# different window class. Returns non-zero when there is no Hyprland to ask,
# so the caller launches it directly.
chrome_layout_launch() {
  local browser="$1"
  local command_lua

  [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || return 1
  command -v hyprctl &>/dev/null || return 1
  command_lua=$(chrome_layout_lua_string "$(printf '%q' "$browser")")
  chrome_layout_dispatch "hl.dsp.exec_cmd($command_lua)" 2>/dev/null
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

chrome_layout_detach_from_mixed_group() {
  local address="$1"
  local chrome_addresses="$2"
  local clients window_lua

  clients=$(hyprctl clients -j 2>/dev/null) || return 1
  if jq -e --arg address "$address" --argjson chrome "$chrome_addresses" '
    [.[] | select(.address == $address)] | first
    | select(. != null)
    | (.grouped // []) as $members
    | select(($members | length) > 1)
    | select(any($members[]; . as $member | $chrome | index($member) == null))
  ' <<<"$clients" &>/dev/null; then
    # Chrome may have been adopted by terminal_grouping.lua while its restored
    # windows were opening. Extract only Chrome before placing it; moving a
    # native group member directly would drag the Ghostty anchor with it.
    window_lua=$(chrome_layout_lua_string "address:$address")
    chrome_layout_dispatch \
      "hl.dsp.window.move({ out_of_group = true, window = $window_lua })" || return 1
  fi
}

chrome_layout_move_chrome_to_workspace() {
  local address="$1"
  local workspace="$2"
  local chrome_addresses="$3"

  chrome_layout_detach_from_mixed_group "$address" "$chrome_addresses" || return 1
  chrome_layout_move_to_workspace "$address" "$workspace"
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

chrome_layout_move_members_to_workspace() {
  local members="$1"
  local workspace="$2"
  local chrome_addresses="$3"
  local member
  local failures=0

  while IFS= read -r member; do
    chrome_layout_move_chrome_to_workspace \
      "$member" "$workspace" "$chrome_addresses" || ((failures += 1))
  done < <(jq -r '.[]' <<<"$members")

  ((failures == 0))
}

# Members of the group that holds $1, in tab order; empty when ungrouped.
chrome_layout_group_of() {
  local address="$1"

  hyprctl clients -j 2>/dev/null | jq -c --arg address "$address" '
    ([.[] | select(.address == $address)] | first | .grouped) // []'
}

# A group of one does not count: group_actions.lua dissolves it ~60ms after
# the next focus or move event, so it cannot be relied on to carry a join.
chrome_layout_is_grouped() {
  jq -e 'length > 1' <<<"$(chrome_layout_group_of "$1")" &>/dev/null
}

# Hyprland adds a window to a group only by direction. into_or_create_group
# joins the neighbour's group on that side, or first makes that neighbour a
# group of its own, in place -- so it is right whether or not the neighbour's
# group has been dissolved in the meantime. Tiled geometry decides who the
# neighbour is, and with binds:window_direction_monitor_fallback it can be a
# window on another monitor, so the join is verified. A wrong one is undone
# and Chrome put back on its saved workspace: joining pulled it onto the other
# group's workspace, and leaving the group keeps it there. An undone join can
# leave that window alone in a new group; group_actions.lua dissolves it.
chrome_layout_join_group_of() {
  local member="$1"
  local anchor="$2"
  local workspace="$3"
  local direction window_lua direction_lua joined

  direction=$(chrome_layout_group_direction "$member" "$anchor") || return 1
  [[ -n "$direction" ]] || return 1
  window_lua=$(chrome_layout_lua_string "address:$member")
  direction_lua=$(chrome_layout_lua_string "$direction")
  chrome_layout_dispatch \
    "hl.dsp.window.move({ into_or_create_group = $direction_lua, window = $window_lua })" ||
    return 1

  joined=$(chrome_layout_group_of "$member")
  jq -e --arg anchor "$anchor" 'index($anchor) != null' <<<"$joined" &>/dev/null && return 0
  if jq -e 'length > 0' <<<"$joined" &>/dev/null; then
    chrome_layout_dispatch \
      "hl.dsp.window.move({ out_of_group = true, window = $window_lua })" || true
    chrome_layout_move_to_workspace "$member" "$workspace" || true
  fi
  return 1
}

# Move one tab to a position in its group. Hyprland moves only the focused
# tab, and focusing a background tab does not raise it, so the tab is made the
# group's current one first and focus is checked before each step: a step
# taken with focus elsewhere would move some other window. (With follow_mouse
# off, only another IPC client or a keypress in between could take it.)
chrome_layout_move_tab_to() {
  local member="$1"
  local target="$2"
  local members index window_lua active step

  members=$(chrome_layout_group_of "$member")
  index=$(jq -r --arg member "$member" 'index($member) // empty' <<<"$members")
  [[ -n "$index" ]] || return 1
  ((index == target)) && return 0

  window_lua=$(chrome_layout_lua_string "address:$member")
  chrome_layout_dispatch \
    "hl.dsp.group.active({ index = $((index + 1)), window = $window_lua })" || return 1
  chrome_layout_dispatch "hl.dsp.focus({ window = $window_lua })" || return 1

  step=true
  ((index > target)) && step=false
  while ((index != target)); do
    active=$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty')
    [[ "$active" == "$member" ]] || return 1
    chrome_layout_dispatch "hl.dsp.group.move_window({ forward = $step })" || return 1
    if [[ "$step" == true ]]; then index=$((index + 1)); else index=$((index - 1)); fi
  done
}

# Where a rejoined tab belongs in the group as it is now: straight after its
# nearest saved predecessor that is in the group, else straight before its
# nearest saved successor. Tabs that were not in the saved group (a window
# someone tabbed in meanwhile) then cannot shift it.
chrome_layout_tab_target() {
  local group="$1"
  local member="$2"
  local now="$3"

  jq -r --arg m "$member" --argjson now "$now" '
    .members as $saved
    | ($saved | index($m)) as $i
    | ($now - [$m]) as $rest
    | ([$saved[:$i][] | select(. as $a | $rest | index($a))] | last) as $prev
    | if $prev then ($rest | index($prev)) + 1
      else ([$saved[$i + 1:][] | select(. as $a | $rest | index($a))] | first) as $next
        | if $next then ($rest | index($next)) else ($rest | length) end
      end' <<<"$group"
}

# When workspace $1 is not on screen: {owner, owner_shows, focused} -- the
# monitor it lives on, what that monitor shows now, and the focused monitor.
# Empty when it is already shown. Fails when the layout cannot be read.
chrome_layout_view_for() {
  local workspace="$1"
  local monitors workspaces

  monitors=$(hyprctl monitors -j 2>/dev/null) || return 1
  workspaces=$(hyprctl workspaces -j 2>/dev/null) || return 1
  [[ -n "$monitors" && -n "$workspaces" ]] || return 1
  jq -c --arg ws "$workspace" --argjson workspaces "$workspaces" '
    def ref: if (.id // 0) > 0 then (.id | tostring) else "name:" + (.name // "") end;
    . as $monitors
    | if any($monitors[]; (.activeWorkspace.id // 0) != 0 and (.activeWorkspace | ref) == $ws)
      then empty
      else
        ([$workspaces[] | select(ref == $ws) | .monitor] | first) as $owner
        | ([$monitors[] | select(.name == $owner) | .activeWorkspace] | first) as $shown
        | select($owner != null and $shown != null and ($shown.id // 0) != 0)
        | {
            owner: $owner,
            owner_shows: ($shown | ref),
            focused: ([$monitors[] | select(.focused) | .name] | first // $owner)
          }
      end' <<<"$monitors"
}

chrome_layout_focus_workspace() {
  chrome_layout_dispatch \
    "hl.dsp.focus({ workspace = $(chrome_layout_lua_string "$1") })"
}

chrome_layout_focus_monitor() {
  chrome_layout_dispatch \
    "hl.dsp.focus({ monitor = $(chrome_layout_lua_string "$1") })"
}

chrome_layout_rejoin_mixed_group() {
  local group="$1"
  local chrome_members="$2"
  local surviving_members="$3"
  local workspace anchor member now target visible index anchor_lua view
  local failures=0

  # Nothing of Chrome's came back for this group: leave the survivors alone.
  jq -e 'length > 0' <<<"$chrome_members" &>/dev/null || return 0
  workspace=$(jq -r '.workspace' <<<"$group")
  # A drop-down's special workspace is not a place a tab group is rebuilt.
  [[ "$workspace" == special:* ]] && return 0

  # Any survivor still in a group carries it. When none is, the group went
  # with Chrome (group_actions.lua dissolves a group down to one member), and
  # it can be rebuilt around a single survivor; with several there is no way
  # to tell which of them it was.
  anchor=""
  while IFS= read -r member; do
    if chrome_layout_is_grouped "$member"; then
      anchor="$member"
      break
    fi
  done < <(jq -r '.[]' <<<"$surviving_members")
  if [[ -z "$anchor" ]]; then
    jq -e 'length == 1' <<<"$surviving_members" &>/dev/null || return 0
    anchor=$(jq -r '.[0]' <<<"$surviving_members")
  fi

  # Hyprland's directional lookup only sees windows on a shown workspace, so a
  # group elsewhere is joined with its workspace briefly on its own monitor.
  # Only that monitor changes; it is put back through a monitor focus, so an
  # empty workspace destroyed on switch-away is recreated there and not on
  # whichever monitor has focus.
  view=$(chrome_layout_view_for "$workspace") || return 1
  if [[ -n "$view" ]]; then
    chrome_layout_focus_workspace "$workspace" || return 1
  fi

  # Join and place one tab at a time: each placement then moves a single tab
  # through tabs already in saved relative order, which settles it exactly.
  # Joining all first and placing afterwards can swap one rejoined tab past
  # another, since Hyprland inserts after the current tab.
  while IFS= read -r member; do
    if ! chrome_layout_join_group_of "$member" "$anchor" "$workspace"; then
      echo "Chrome window $member could not rejoin its tab group" >&2
      ((failures += 1))
      continue
    fi
    now=$(chrome_layout_group_of "$anchor")
    target=$(chrome_layout_tab_target "$group" "$member" "$now")
    if [[ -z "$target" ]] || ! chrome_layout_move_tab_to "$member" "$target"; then
      ((failures += 1))
    fi
  done < <(jq -r '.[]' <<<"$chrome_members")

  # Show the tab that was showing. A group of one has nothing to choose.
  visible=$(jq -r '.visible_address // empty' <<<"$group")
  index=$(chrome_layout_group_of "$anchor" |
    jq -r --arg visible "$visible" 'if length > 1 then index($visible) // empty else empty end')
  if [[ -n "$index" ]]; then
    anchor_lua=$(chrome_layout_lua_string "address:$anchor")
    chrome_layout_dispatch \
      "hl.dsp.group.active({ index = $((index + 1)), window = $anchor_lua })" ||
      ((failures += 1))
  fi

  if [[ -n "$view" ]]; then
    chrome_layout_focus_monitor "$(jq -r '.owner' <<<"$view")" &&
      chrome_layout_focus_workspace "$(jq -r '.owner_shows' <<<"$view")" &&
      chrome_layout_focus_monitor "$(jq -r '.focused' <<<"$view")" ||
      ((failures += 1))
  fi

  ((failures == 0))
}

chrome_layout_restore_group() {
  local group="$1"
  local group_number="$2"
  local chrome_addresses="$3"
  local workspace visible_address temp_workspace
  local clients available chrome_members surviving_members existing_groups
  local member anchor direction window_lua direction_lua
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
  chrome_members=$(jq -c --argjson chrome "$chrome_addresses" \
    '[.[] | select(. as $address | $chrome | index($address))]' <<<"$available")
  surviving_members=$(jq -c --argjson chrome "$chrome_addresses" \
    '[.[] | select(. as $address | $chrome | index($address) == null)]' <<<"$available")

  # A mixed group is outside the ownership boundary of a Chrome restart: the
  # surviving applications are never moved or staged. Chrome goes back to the
  # saved workspace and then rejoins the survivors' group in place, which only
  # ever moves Chrome. A failed rejoin leaves it tiled beside the group.
  if (($(jq 'length' <<<"$surviving_members") > 0)); then
    chrome_layout_move_members_to_workspace \
      "$chrome_members" "$workspace" "$chrome_addresses" || return 1
    chrome_layout_rejoin_mixed_group "$group" "$chrome_members" "$surviving_members"
    return
  fi

  available="$chrome_members"

  if (($(jq 'length' <<<"$available") < 2)); then
    member=$(jq -r 'first // empty' <<<"$available")
    [[ -z "$member" ]] || chrome_layout_move_chrome_to_workspace \
      "$member" "$workspace" "$chrome_addresses"
    return
  fi

  # A compositor-side window.open handler can group a new Chrome surface with
  # an unrelated live window before this restore sees it. Remove each Chrome
  # member from such a mixed group before inspecting Chrome-only groups below.
  while IFS= read -r member; do
    if ! chrome_layout_detach_from_mixed_group "$member" "$chrome_addresses"; then
      chrome_layout_move_members_to_workspace \
        "$available" "$workspace" "$chrome_addresses" || true
      return 1
    fi
  done < <(jq -r '.[]' <<<"$available")
  clients=$(hyprctl clients -j 2>/dev/null) || return 1

  # From this point every address is a restored Chrome window. Dissolve each
  # existing Chrome-only group once, then rebuild the original member set.
  existing_groups=$(jq -c --argjson members "$available" '[
    .[]
    | select(.address as $address | $members | index($address))
    | select(((.grouped // []) | length) > 1)
    | { key: (.grouped | join("|")), address }
  ] | unique_by(.key)' <<<"$clients")
  while IFS= read -r member; do
    window_lua=$(chrome_layout_lua_string "address:$member")
    if ! chrome_layout_dispatch "hl.dsp.group.toggle({ window = $window_lua })"; then
      chrome_layout_move_members_to_workspace \
        "$available" "$workspace" "$chrome_addresses" || true
      return 1
    fi
  done < <(jq -r '.[].address' <<<"$existing_groups")

  while IFS= read -r member; do
    if ! chrome_layout_move_chrome_to_workspace \
      "$member" "$temp_workspace" "$chrome_addresses"; then
      chrome_layout_move_members_to_workspace \
        "$available" "$workspace" "$chrome_addresses" || true
      return 1
    fi
  done < <(jq -r '.[]' <<<"$available")

  anchor=$(jq -r '.[0]' <<<"$available")
  while IFS= read -r member; do
    if ! direction=$(chrome_layout_group_direction "$member" "$anchor") \
      || [[ -z "$direction" ]]; then
      chrome_layout_move_members_to_workspace \
        "$available" "$workspace" "$chrome_addresses" || true
      return 1
    fi
    window_lua=$(chrome_layout_lua_string "address:$member")
    direction_lua=$(chrome_layout_lua_string "$direction")
    if ! chrome_layout_dispatch \
      "hl.dsp.window.move({ into_or_create_group = $direction_lua, window = $window_lua })"; then
      chrome_layout_move_members_to_workspace \
        "$available" "$workspace" "$chrome_addresses" || true
      return 1
    fi
  done < <(jq -r '.[1:][]' <<<"$available")

  # Moving one member of a native group moves the complete group.
  if ! chrome_layout_move_chrome_to_workspace \
    "$anchor" "$workspace" "$chrome_addresses"; then
    chrome_layout_move_members_to_workspace \
      "$available" "$workspace" "$chrome_addresses" || true
    return 1
  fi

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
  local assignment plan chrome_addresses grouped_addresses window group group_number
  local active_address active_lua
  local address workspace
  local restore_failures=0

  assignment=$(chrome_layout_wait_for_windows "$snapshot" "$timeout_seconds") || return 1
  plan=$(chrome_layout_resolve_snapshot "$snapshot" "$(jq '.pairs' <<<"$assignment")")
  chrome_addresses=$(jq -c '[.windows[].address]' <<<"$plan")
  grouped_addresses=$(jq -c '[.groups[].members[]] | unique' <<<"$plan")

  while IFS= read -r window; do
    address=$(jq -r '.address' <<<"$window")
    if ! jq -e --arg address "$address" 'index($address) != null' \
      <<<"$grouped_addresses" &>/dev/null; then
      workspace=$(jq -r '.workspace' <<<"$window")
      chrome_layout_move_chrome_to_workspace \
        "$address" "$workspace" "$chrome_addresses" || ((restore_failures += 1))
    fi
  done < <(jq -c '.windows[]' <<<"$plan")

  group_number=0
  while IFS= read -r group; do
    ((group_number += 1))
    chrome_layout_restore_group "$group" "$group_number" "$chrome_addresses" \
      || ((restore_failures += 1))
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
