#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d /tmp/chrome-theme.XXXXXX)
original_home=$HOME

cleanup() {
  [[ "$test_root" == /tmp/chrome-theme.* ]] && rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v jq >/dev/null || fail "jq is required"
command -v openssl >/dev/null || fail "openssl is required"

HOME="$test_root/home"
export HOME
mkdir -p "$HOME/.config/google-chrome/Default" "$HOME/.local/state/chrome-theme"

# shellcheck source=lib/chrome-theme.sh
source "$repo_root/scripts/lib/chrome-theme.sh"

key="$HOME/.local/state/chrome-theme/key.pem"
chrome_theme_generate_key "$key" || fail "could not generate a Chrome theme key"
id=$(chrome_theme_extension_id "$key")
[[ ${#id} -eq 32 && "$id" != *[^a-p]* ]] \
  || fail "generated Chrome extension ID is invalid: $id"

preferences="$HOME/.config/google-chrome/Default/Preferences"
printf '{"extensions":{"external_uninstalls":null}}\n' >"$preferences"
if chrome_theme_profile_blocklists_id "$id"; then
  fail "a null external uninstall list blocklisted the theme"
fi

printf '{malformed\n' >"$preferences"
if chrome_theme_profile_blocklists_id "$id"; then
  fail "malformed preferences produced a false blocklist match"
fi

jq -n --arg id "$id" \
  '{extensions: {external_uninstalls:
    ([range(0; 10000) | ("aaaaaaaaaaaaaaaaaaaaaaaaaaaa" + (. | tostring))] + [$id])}}' \
  >"$preferences"
chrome_theme_profile_blocklists_id "$id" \
  || fail "the theme ID was missed at the end of a large blocklist"

previous_id=$id
chrome_theme_generate_key "$key" || fail "could not rotate a Chrome theme key"
id=$(chrome_theme_extension_id "$key")
[[ "$id" != "$previous_id" ]] || fail "key rotation did not change the extension ID"
if chrome_theme_profile_blocklists_id "$id"; then
  fail "a fresh Chrome theme identity was already blocklisted"
fi

HOME=$original_home
echo "Chrome theme helper tests passed"
