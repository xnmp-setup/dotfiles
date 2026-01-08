# Zellij helper: `zell`
# - zell                 -> create/attach session named after current folder
# - zell -l <layout>     -> create/attach session "<folder>_<layout>" using layout <layout>
# - zell a [name]        -> attach by prefix; if none, fuzzy-pick (fzf) from all sessions
# - anything else        -> falls through to `zellij ...` unchanged

zell() {
  emulate -L zsh
  setopt pipefail no_aliases

  # ---- config knobs ----
  local -i MAX_SESS_LEN=48   # overall session name cap
  local -i MAX_PART_LEN=22   # per-part cap before hashing
  # ----------------------

  _zell_has() { command -v "$1" >/dev/null 2>&1 }

  _zell_sanitize() {
    local s="$1"
    s="${s// /_}"
    s="$(printf "%s" "$s" | tr -cs '[:alnum:]_.-' '_' )"
    s="${s##_}"; s="${s%%_}"
    printf "%s" "$s"
  }

  _zell_hash6() {
    local s="$1"
    if _zell_has shasum; then
      printf "%s" "$s" | shasum -a 1 | awk '{print substr($1,1,6)}'
    elif _zell_has sha1sum; then
      printf "%s" "$s" | sha1sum | awk '{print substr($1,1,6)}'
    else
      printf "%s" "$s" | cksum | awk '{printf "%06x",$1%0xffffff}'
    fi
  }

  _zell_shorten_part() {
    local s="$(_zell_sanitize "$1")"
    if (( ${#s} <= MAX_PART_LEN )); then
      printf "%s" "$s"
    else
      local h="$(_zell_hash6 "$s")"
      printf "%s_%s" "${s[1,MAX_PART_LEN-7]}" "$h"
    fi
  }

  _zell_shorten_session() {
    local s="$(_zell_sanitize "$1")"
    if (( ${#s} <= MAX_SESS_LEN )); then
      printf "%s" "$s"
    else
      local h="$(_zell_hash6 "$s")"
      printf "%s_%s" "${s[1,MAX_SESS_LEN-7]}" "$h"
    fi
  }

  _zell_list_sessions() {
    zellij list-sessions --no-formatting 2>/dev/null \
      | awk '{print $1}'
  }

  _zell_session_exists() {
    local target="$1"
    _zell_list_sessions | grep -Fxq -- "$target"
  }

  _zell_attach() {
    local sess="$1"
    zellij attach "$sess"
  }

  _zell_create_default() {
    local sess="$1"
    zellij --session "$sess"
  }

  _zell_create_with_layout() {
    local sess="$1" layout="$2"
    # per your note: must be --new-session-with-layout
    zellij --session "$sess" --new-session-with-layout "$layout"
  }

  _zell_prefix_matches() {
    local prefix="$1"
    # Escape special regex characters for grep -E
    local escaped="${prefix//\\/\\\\}"
    escaped="${escaped//./\\.}"
    escaped="${escaped//\*/\\*}"
    escaped="${escaped//\[/\\[}"
    escaped="${escaped//\]/\\]}"
    escaped="${escaped//\^/\\^}"
    escaped="${escaped//\$/\\$}"
    _zell_list_sessions | grep -E "^${escaped}" 2>/dev/null || true
  }

  _zell_usage() {
    cat <<'EOF'
Usage:
  zell                 # create/attach session named after current folder
  zell -l <layout>     # create/attach session "<folder>_<layout>" using layout <layout>
  zell a [name]        # attach by prefix; if none, fuzzy-pick (fzf) from all sessions
  zell kill-all        # kill all running sessions
  zell delete-all      # delete all dead sessions
  zell <anything else> # passed through to zellij unchanged
EOF
  }

  # ---- compute current folder name ----
  local dir="${PWD##*/}"
  dir="$(_zell_shorten_part "$dir")"
  dir="$(_zell_sanitize "$dir")"
  [[ -n "$dir" ]] || dir="root"

  # ---- behaviors ----
  if (( $# == 0 )); then
    local sess="$(_zell_shorten_session "$dir")"
    # Check if any session starts with this dir name
    local matches
    matches="$(_zell_prefix_matches "$dir")"
    local -a arr
    arr=(${(f)matches})

    if (( ${#arr} == 1 )); then
      _zell_attach "$arr[1]"
    elif (( ${#arr} > 1 )); then
      print -u2 "zell: multiple sessions start with '$dir'; be more specific:"
      printf "%s\n" "${arr[@]}" >&2
      return 3
    elif _zell_session_exists "$sess"; then
      _zell_attach "$sess"
    else
      _zell_create_default "$sess"
    fi
    return
  fi

  case "$1" in
    -l|--layout)
      local layout="$2"
      if [[ -z "$layout" ]]; then
        print -u2 "zell: missing layout name after $1"
        _zell_usage >&2
        return 2
      fi
      layout="$(_zell_shorten_part "$layout")"
      local sess="$(_zell_shorten_session "${dir}_${layout}")"
      if _zell_session_exists "$sess"; then
        _zell_attach "$sess"
      else
        _zell_create_with_layout "$sess" "$layout"
      fi
      ;;

    a|attach)
      local query="$2"
      if [[ -z "$query" ]]; then
        # attach to sessions beginning with dir; if none -> create; if multiple -> error
        local matches
        matches="$(_zell_prefix_matches "$dir")"
        local -a arr
        arr=(${(f)matches})

        if (( ${#arr} == 0 )); then
          local sess="$(_zell_shorten_session "$dir")"
          _zell_create_default "$sess"
        elif (( ${#arr} == 1 )); then
          _zell_attach "$arr[1]"
        else
          print -u2 "zell: multiple sessions start with '$dir'; be more specific:"
          printf "%s\n" "${arr[@]}" >&2
          return 3
        fi
      else
        # Don't sanitize query for matching - use it as-is
        local matches
        matches="$(_zell_prefix_matches "$query")"
        local -a arr
        arr=(${(f)matches})

        if (( ${#arr} == 1 )); then
          _zell_attach "$arr[1]"
        elif (( ${#arr} > 1 )); then
          if _zell_has fzf; then
            local pick
            pick="$(printf "%s\n" "${arr[@]}" | fzf --query "$query" --select-1 --exit-0)"
            if [[ -n "$pick" ]]; then
              _zell_attach "$pick"
            else
              print -u2 "zell: no selection."
              return 4
            fi
          else
            print -u2 "zell: multiple sessions start with '$query' (install fzf for fuzzy pick):"
            printf "%s\n" "${arr[@]}" >&2
            return 3
          fi
        else
          local -a all
          all=(${(f)$(_zell_list_sessions)})
          if (( ${#all} == 0 )); then
            print -u2 "zell: no existing sessions."
            return 1
          fi
          if _zell_has fzf; then
            local pick
            pick="$(printf "%s\n" "${all[@]}" | fzf --query "$query" --select-1 --exit-0)"
            if [[ -n "$pick" ]]; then
              _zell_attach "$pick"
            else
              print -u2 "zell: no selection."
              return 4
            fi
          else
            print -u2 "zell: no session starts with '$query' and fzf isn't installed; sessions are:"
            printf "%s\n" "${all[@]}" >&2
            return 1
          fi
        fi
      fi
      ;;

    kill-all)
      zellij kill-all-sessions -y
      ;;

    delete-all)
      zellij delete-all-sessions -y
      ;;

    -h|--help|help)
      _zell_usage
      ;;

    *)
      # FALL THROUGH: anything else goes straight to zellij
      zellij "$@"
      ;;
  esac
}

# If you previously had `alias zell=zellij`, remove it so the function is used:
# unalias zell 2>/dev/null
