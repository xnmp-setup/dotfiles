__ghostty_set_tab_title() {
  local title=${1//$'\e'/}
  title=${title//$'\a'/}
  title=${title//$'\r'/ }
  title=${title//$'\n'/ }
  # The identity tag goes last: see ghostty-title-tags.zsh for why the ordering
  # matters to the status bar's title parsing.
  printf '\e]2;%s%s\e\\' "$title" "$__ghostty_pid_tag"
}

# Mirror WezTerm's foreground-app markers. These are Hack Nerd Font private-use
# glyphs; Ghostty/Pango resolves them through the installed system font fallback.
typeset -gA __ghostty_app_icons=(
  # editors
  micro             $'\ueae9'
  nano              $'\ueae9'
  vim               $'\ue62b'
  nvim              $'\ue62b'
  vi                $'\ue62b'
  hx                $'\uf0e7'
  helix             $'\uf0e7'
  emacs             $'\ue632'
  # git / version control
  keifu             $'\ue725'
  gg                $'\ue725'
  git               $'\ue702'
  lazygit           $'\ue702'
  gitui             $'\ue702'
  tig               $'\ue702'
  # file managers
  yazi              $'\uea83'
  ranger            $'\uea83'
  nnn               $'\uea83'
  lf                $'\uea83'
  broot             $'\uea83'
  # multiplexers / sessions
  zellij            $'\uf489'
  tmux              $'\uebc7'
  screen            $'\uebc7'
  # containers / infrastructure
  docker            $'\uf308'
  docker-compose    $'\uf308'
  kubectl           $'\U000f10fe'
  k9s               $'\U000f10fe'
  # languages / runtimes
  cargo             $'\ue7a8'
  rustc             $'\ue7a8'
  bun               $'\ue76f'
  node              $'\ue718'
  deno              $'\ue718'
  python            $'\ue606'
  uv                $'\ue606'
  go                $'\ue626'
  ruby              $'\ue739'
  lua               $'\ue620'
  # AI CLIs without a running agent animation
  openclaw          $'\U000f0ea0'
  # remote / network
  ssh               $'\U000f08c0'
  mosh              $'\U000f08c0'
  ping              $'\U000f0200'
  curl              $'\uf0ee'
  wget              $'\uf0ee'
  # monitors
  htop              $'\uf0e4'
  btop              $'\uf0e4'
  top               $'\uf0e4'
  btm               $'\uf0e4'
  # common tools
  fzf               $'\uf422'
  rg                $'\uf422'
  make              $'\ue673'
  bat               $'\uf0e7'
  less              $'\uf15c'
  man               $'\uf02d'
  brew              $'\uf0f4'
  psql              $'\ue76e'
  redis             $'\ue76d'
  sqlite3           $'\ue7c4'
)

# Resolve the first executable from a zsh command line without executing it.
# Handle the command modifiers and privilege/environment wrappers used commonly
# in interactive shells; unknown commands retain the unmarked shell title.
__ghostty_command_name() {
  emulate -L zsh
  setopt local_options extended_glob

  local command_line=$1
  local token
  local -a words
  integer index=1

  words=(${(z)command_line}) 2>/dev/null || {
    REPLY=
    return 1
  }

  while (( index <= $#words )); do
    token=${(Q)words[$index]}

    if [[ $token == [A-Za-z_][A-Za-z0-9_]#=* ]]; then
      (( index++ ))
      continue
    fi

    case $token in
      command|exec|noglob|nocorrect|time|builtin)
        (( index++ ))
        continue
        ;;
      env)
        (( index++ ))
        while (( index <= $#words )); do
          token=${(Q)words[$index]}
          if [[ $token == -- ]]; then
            (( index++ ))
            break
          fi
          [[ $token == -* || $token == [A-Za-z_][A-Za-z0-9_]#=* ]] || break
          (( index++ ))
        done
        continue
        ;;
      sudo)
        (( index++ ))
        while (( index <= $#words )); do
          token=${(Q)words[$index]}
          if [[ $token == -- ]]; then
            (( index++ ))
            break
          fi
          [[ $token == -* ]] || break
          case $token in
            -C|-D|-g|-h|-p|-r|-t|-u)
              (( index += 2 ))
              ;;
            *)
              (( index++ ))
              ;;
          esac
        done
        continue
        ;;
    esac

    REPLY=${token:t}
    REPLY=${REPLY%.exe}
    REPLY=${REPLY:l}
    [[ $REPLY == python[0-9.]# ]] && REPLY=python
    return 0
  done

  REPLY=
  return 1
}

__ghostty_set_shell_tab_title() {
  __ghostty_page_scroll_title "❯ ${PWD:t}"
  __ghostty_set_tab_title "$REPLY"
}

__ghostty_preexec_tab_title() {
  emulate -L zsh

  # Stop compositor-level interception before the child process can consume
  # input. Known apps replace this title below; unknown commands keep the
  # unmarked shell title and receive PageUp/PageDown unchanged.
  __ghostty_set_tab_title "❯ ${PWD:t}"

  # The third hook argument contains the fully expanded command when zsh
  # provides it; keep the typed command as a portable fallback.
  local command_line=${3:-$1}
  __ghostty_command_name "$command_line" || return 0

  local icon=${__ghostty_app_icons[$REPLY]-}
  [[ -n $icon ]] || return 0
  __ghostty_set_tab_title "$icon ${PWD:t}"
}

# Re-sourcing this file is safe: replace, rather than duplicate, our hooks.
add-zsh-hook -d preexec __ghostty_preexec_tab_title 2>/dev/null
add-zsh-hook -d precmd __ghostty_set_shell_tab_title 2>/dev/null
add-zsh-hook preexec __ghostty_preexec_tab_title
add-zsh-hook precmd __ghostty_set_shell_tab_title
