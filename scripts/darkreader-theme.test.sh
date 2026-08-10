#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d /tmp/darkreader-theme.XXXXXX)

cleanup() {
  [[ "$test_root" == /tmp/darkreader-theme.* ]] && rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for required in jq node openssl uv zip; do
  command -v "$required" >/dev/null || fail "$required is required"
done

HOME="$test_root/home"
XDG_STATE_HOME="$test_root/state"
UV_CACHE_DIR="$test_root/uv-cache"
export HOME XDG_STATE_HOME UV_CACHE_DIR
mkdir -p "$HOME/.config/google-chrome/Default" "$XDG_STATE_HOME"

host_source="$repo_root/dot_local/share/darkreader-theme-bridge/executable_host.py"
host="$test_root/host.py"
cp "$host_source" "$host"
chmod +x "$host"

# Create a local release archive with Dark Reader's official public manifest
# key. Production uses the checksum-pinned asset from the xnmp/darkreader fork.
fixture="$test_root/fixture"
archive="$test_root/darkreader-chrome-mv3.zip"
mkdir -p "$fixture/background"
jq -n '{
  manifest_version: 3,
  name: "Dark Reader (automatic desktop themes)",
  version: "4.9.129.3",
  version_name: "4.9.129.3 desktop-theme-bridge.3",
  key: "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAqBY2tfTtJYiVMirbII2r3WofqCDaxS2zwPddSsgxUWKRm/MW/ymL2ZaP24MmwnegGIoxHkBVyi4cps4/q76c98ViyijoQvdJjAv3ZtUOwbWlYnZ5pU6gPCeZrScHxoTJdxxJJ30DZpMc6qsc3yJVQJlABG2FQFPrhPEGFLP9sCq/M7pY1xH++KsG+jYLB6cU3ItvZ4zntUXRwG2ZBx+XZelsd6FdkVXbDXj/47TNk2Qq8PAqyiK45GgQ+KJjuISAo89ip1xI4tONLCjSHPinD3nz6HiMikQzwn4L8SsB4Wy7rBhMhPRGIWbwHed+L+W3LXhB05Lhwk0YxuOb7QNWRQIDAQAB",
  permissions: ["alarms", "nativeMessaging", "storage"],
  background: {service_worker: "background/index.js"}
}' >"$fixture/manifest.json"
cat >"$fixture/background/index.js" <<'EOF'
(function () {
    const NATIVE_HOST = "com.chong.darkreader_theme";
    chrome.runtime.connectNative(NATIVE_HOST);
    const settings = {theme: {mode: 1}};
    class Extension { static changeSettings(_settings) {} }
    Extension.changeSettings(settings);
})();
EOF
(cd "$fixture" && zip -qr "$archive" .)

DARKREADER_FORK_RELEASE="test-release"
DARKREADER_FORK_RELEASE_URL="file://$archive"
DARKREADER_FORK_RELEASE_SHA256=$(sha256sum "$archive" | cut -d' ' -f1)
export DARKREADER_FORK_RELEASE DARKREADER_FORK_RELEASE_URL \
  DARKREADER_FORK_RELEASE_SHA256
# shellcheck source=lib/darkreader-theme.sh
source "$repo_root/scripts/lib/darkreader-theme.sh"

extension="$HOME/.local/share/darkreader-theme-bridge/extension"
darkreader_bridge_install_from_fork "$extension" \
  || fail "$darkreader_bridge_error"
[[ -f "$extension/manifest.json" && -f "$extension/background/index.js" ]] \
  || fail "fork release was not installed"
[[ "$(darkreader_manifest_extension_id "$extension/manifest.json")" \
    == "$DARKREADER_EXTENSION_ID" ]] \
  || fail "fork release does not retain Dark Reader's official ID"
node --check "$extension/background/index.js" >/dev/null \
  || fail "installed service worker is invalid JavaScript"
jq -e --arg url "$DARKREADER_FORK_RELEASE_URL" \
  '.tag == "test-release" and .url == $url' \
  "$HOME/.local/share/darkreader-theme-bridge/release.json" >/dev/null \
  || fail "fork release metadata was not recorded"

darkreader_bridge_register "$extension" "$host" \
  || fail "$darkreader_bridge_error"
[[ "$darkreader_bridge_loaded" == 0 ]] \
  || fail "an extension not present in Preferences was reported as loaded"

native_manifest="$HOME/.config/google-chrome/NativeMessagingHosts/com.chong.darkreader_theme.json"
jq -e --arg host "$host" --arg origin "chrome-extension://$DARKREADER_EXTENSION_ID/" '
  .path == $host and .allowed_origins == [$origin]
' "$native_manifest" >/dev/null || fail "native host manifest is invalid"

jq -n \
  --arg id "$DARKREADER_EXTENSION_ID" \
  --arg path "$extension" \
  --arg version "$DARKREADER_FORK_MANIFEST_VERSION" \
  '{extensions: {settings: {($id): {
    path: $path,
    manifest: {
      version: $version,
      permissions: ["alarms", "nativeMessaging", "storage"]
    }
  }}}}' \
  >"$HOME/.config/google-chrome/Default/Preferences"
darkreader_bridge_register "$extension" "$host"
[[ "$darkreader_bridge_loaded" == 1 ]] \
  || fail "loaded fork extension was not detected"

# The unpacked path alone is insufficient when Chrome retained the Web Store
# manifest in Preferences.
jq --arg id "$DARKREADER_EXTENSION_ID" \
  'del(.extensions.settings[$id].manifest.permissions[] |
    select(. == "nativeMessaging"))' \
  "$HOME/.config/google-chrome/Default/Preferences" \
  >"$test_root/stale-preferences"
mv "$test_root/stale-preferences" \
  "$HOME/.config/google-chrome/Default/Preferences"
darkreader_bridge_register "$extension" "$host"
[[ "$darkreader_bridge_loaded" == 0 ]] \
  || fail "a stale Web Store manifest was reported as the loaded fork"

# A failed future update must preserve a working installed release.
DARKREADER_FORK_VERSION_NAME="future release"
DARKREADER_FORK_RELEASE_SHA256="$(printf '0%.0s' {1..64})"
darkreader_bridge_install_from_fork "$extension" \
  || fail "failed update removed the working release"
[[ "$darkreader_bridge_warning" == *"using the existing patched build"* ]] \
  || fail "failed update did not report its fallback"
[[ -f "$extension/manifest.json" ]] || fail "failed update removed the extension"

# Assert the native framing and validation contract on representative valid,
# malformed, null, and oversized inputs.
settings="$test_root/settings.json"
printf '{"enabled":true,"theme":{"mode":1}}\n' >"$settings"
uv run "$host" --once "$settings" "chrome-extension://$DARKREADER_EXTENSION_ID/" \
  >"$test_root/frame"
frame_size=$(od -An -N4 -tu4 "$test_root/frame" | tr -d ' ')
payload=$(tail -c +5 "$test_root/frame")
[[ "$frame_size" -eq ${#payload} ]] || fail "native frame length is wrong"
jq -e '.enabled == true and .theme.mode == 1' <<<"$payload" >/dev/null \
  || fail "native frame payload changed"

printf '{malformed\n' >"$settings"
if uv run "$host" --once "$settings" >/dev/null 2>&1; then
  fail "malformed settings were accepted"
fi
printf 'null\n' >"$settings"
if uv run "$host" --once "$settings" >/dev/null 2>&1; then
  fail "null settings were accepted"
fi
truncate -s 1048577 "$settings"
if uv run "$host" --once "$settings" >/dev/null 2>&1; then
  fail "oversized settings were accepted"
fi

echo "Dark Reader theme bridge tests passed"
