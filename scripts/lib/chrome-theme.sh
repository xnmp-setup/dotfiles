# Chrome theme extension identity and profile discovery helpers.

chrome_theme_extension_id() {
  local key="$1"

  [[ -f "$key" ]] || return 1
  openssl rsa -in "$key" -pubout -outform DER 2>/dev/null \
    | openssl dgst -sha256 -binary \
    | head -c 16 \
    | od -An -vtx1 \
    | tr -d ' \n' \
    | tr '0-9a-f' 'a-p'
}

chrome_theme_profile_roots() {
  printf '%s\n' \
    "$HOME/.config/google-chrome" \
    "$HOME/.config/chromium" \
    "$HOME/.config/vivaldi" \
    "$HOME/.config/microsoft-edge" \
    "$HOME/.config/BraveSoftware/Brave-Browser" \
    "$HOME/Library/Application Support/Google/Chrome" \
    "$HOME/Library/Application Support/Chromium" \
    "$HOME/Library/Application Support/Vivaldi" \
    "$HOME/Library/Application Support/Microsoft Edge" \
    "$HOME/Library/Application Support/BraveSoftware/Brave-Browser"
}

# Linux Google Chrome does not scan a per-user External Extensions directory.
# Chromium-family builds and every supported macOS browser profile do.
chrome_theme_user_external_roots() {
  printf '%s\n' \
    "$HOME/.config/chromium" \
    "$HOME/.config/vivaldi" \
    "$HOME/.config/microsoft-edge" \
    "$HOME/.config/BraveSoftware/Brave-Browser" \
    "$HOME/Library/Application Support/Google/Chrome" \
    "$HOME/Library/Application Support/Chromium" \
    "$HOME/Library/Application Support/Vivaldi" \
    "$HOME/Library/Application Support/Microsoft Edge" \
    "$HOME/Library/Application Support/BraveSoftware/Brave-Browser"
}

chrome_theme_profile_blocklists_id() {
  local id="$1"
  local profile_root preferences

  while IFS= read -r profile_root; do
    [[ -d "$profile_root" ]] || continue
    for preferences in "$profile_root"/*/Preferences; do
      [[ -f "$preferences" ]] || continue
      if command -v jq >/dev/null 2>&1; then
        jq -e --arg id "$id" \
          '(.extensions.external_uninstalls // []) | index($id) != null' \
          "$preferences" >/dev/null 2>&1 && return 0
      elif tr -d '\n' <"$preferences" \
        | grep -Eq '"external_uninstalls"[[:space:]]*:[[:space:]]*\[[^]]*"'"$id"'"'; then
        return 0
      fi
    done
  done < <(chrome_theme_profile_roots)

  return 1
}

chrome_theme_generate_key() {
  local key="$1"
  local replacement

  replacement=$(mktemp "${key}.XXXXXX") || return 1
  if ! openssl genrsa -out "$replacement" 2048 >/dev/null 2>&1; then
    rm -f -- "$replacement"
    return 1
  fi
  chmod 600 "$replacement"
  mv -f -- "$replacement" "$key"
}
