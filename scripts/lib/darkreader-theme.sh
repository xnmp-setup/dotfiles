# Dark Reader native-messaging registration and install detection.

DARKREADER_EXTENSION_ID="${DARKREADER_EXTENSION_ID:-eimadpbcbfnmbkopoojfekhnkhdbieeh}"
DARKREADER_NATIVE_HOST="com.chong.darkreader_theme"
DARKREADER_FORK_RELEASE="${DARKREADER_FORK_RELEASE:-desktop-theme-bridge-v4.9.129.3}"
DARKREADER_FORK_RELEASE_URL="${DARKREADER_FORK_RELEASE_URL:-https://github.com/xnmp/darkreader/releases/download/$DARKREADER_FORK_RELEASE/darkreader-chrome-mv3.zip}"
DARKREADER_FORK_RELEASE_SHA256="${DARKREADER_FORK_RELEASE_SHA256:-1261713c7e7204626a7638c8fd3f56b9e6a9c4505af9927f71077f310c779db0}"
DARKREADER_FORK_MANIFEST_VERSION="${DARKREADER_FORK_MANIFEST_VERSION:-4.9.129.3}"
DARKREADER_FORK_VERSION_NAME="${DARKREADER_FORK_VERSION_NAME:-4.9.129.3 desktop-theme-bridge.3}"

darkreader_browser_roots() {
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

darkreader_manifest_extension_id() {
  local manifest="$1"

  jq -er '.key' "$manifest" 2>/dev/null \
    | base64 --decode 2>/dev/null \
    | openssl dgst -sha256 -binary 2>/dev/null \
    | head -c 16 \
    | od -An -vtx1 \
    | tr -d ' \n' \
    | tr '0-9a-f' 'a-p'
}

darkreader_bridge_is_loaded() {
  local extension_dir="$1" browser_root preferences configured_path

  while IFS= read -r browser_root; do
    [[ -d "$browser_root" ]] || continue
    while IFS= read -r -d '' preferences; do
      configured_path=$(jq -r --arg id "$DARKREADER_EXTENSION_ID" \
        '.extensions.settings[$id].path // empty' "$preferences" 2>/dev/null) \
        || continue
      [[ -n "$configured_path" ]] || continue
      if [[ "$configured_path" != /* ]]; then
        configured_path="$(dirname "$preferences")/$configured_path"
      fi
      [[ "$(realpath -m "$configured_path")" == "$(realpath -m "$extension_dir")" ]] \
        || continue
      jq -e \
        --arg id "$DARKREADER_EXTENSION_ID" \
        --arg version "$DARKREADER_FORK_MANIFEST_VERSION" '
        .extensions.settings[$id].manifest as $manifest |
        $manifest.version == $version and
        ($manifest.permissions | index("nativeMessaging") != null)
      ' "$preferences" >/dev/null 2>&1 && return 0
    done < <(find "$browser_root" -maxdepth 3 -type f -name Preferences \
      -print0 2>/dev/null)
  done < <(darkreader_browser_roots)

  return 1
}

darkreader_write_native_manifests() {
  local host_executable="$1" browser_root manifest_dir manifest_file tmp

  [[ -x "$host_executable" ]] || return 1
  while IFS= read -r browser_root; do
    [[ -d "$browser_root" ]] || continue
    manifest_dir="$browser_root/NativeMessagingHosts"
    mkdir -p "$manifest_dir" || return 1
    manifest_file="$manifest_dir/$DARKREADER_NATIVE_HOST.json"
    tmp=$(mktemp "$manifest_file.XXXXXX") || return 1
    if jq -n \
      --arg name "$DARKREADER_NATIVE_HOST" \
      --arg path "$host_executable" \
      --arg origin "chrome-extension://$DARKREADER_EXTENSION_ID/" \
      '{
        name: $name,
        description: "Apply desktop palettes to Dark Reader",
        path: $path,
        type: "stdio",
        allowed_origins: [$origin]
      }' >"$tmp"; then
      mv -f "$tmp" "$manifest_file"
    else
      rm -f "$tmp"
      return 1
    fi
  done < <(darkreader_browser_roots)
}

darkreader_bridge_install_from_fork() {
  local extension_dir="$1" install_dir manifest archive staging previous tmp

  darkreader_bridge_warning=""
  install_dir=$(dirname "$extension_dir")
  manifest="$extension_dir/manifest.json"
  if jq -e \
    --arg manifest_version "$DARKREADER_FORK_MANIFEST_VERSION" \
    --arg version_name "$DARKREADER_FORK_VERSION_NAME" \
    '.version == $manifest_version and .version_name == $version_name' \
    "$manifest" >/dev/null 2>&1; then
    return 0
  fi

  for required in base64 curl jq openssl sha256sum unzip; do
    if ! command -v "$required" >/dev/null 2>&1; then
      darkreader_bridge_error="$required is required to install the Dark Reader fork"
      return 1
    fi
  done
  mkdir -p "$install_dir" || return 1
  archive=$(mktemp "$install_dir/release.XXXXXX.zip") || return 1
  staging=$(mktemp -d "$install_dir/extension.XXXXXX") || {
    rm -f "$archive"
    return 1
  }

  if ! curl --fail --location --silent --show-error \
      "$DARKREADER_FORK_RELEASE_URL" --output "$archive" \
    || ! printf '%s  %s\n' "$DARKREADER_FORK_RELEASE_SHA256" "$archive" \
      | sha256sum --check --status \
    || ! unzip -q "$archive" -d "$staging"; then
    rm -f "$archive"
    rm -rf -- "$staging"
    if [[ -f "$manifest" ]]; then
      darkreader_bridge_warning="fork update unavailable; using the existing patched build"
      return 0
    fi
    darkreader_bridge_error="could not download or verify $DARKREADER_FORK_RELEASE_URL"
    return 1
  fi
  rm -f "$archive"

  if [[ "$(darkreader_manifest_extension_id "$staging/manifest.json")" \
      != "$DARKREADER_EXTENSION_ID" ]] \
    || ! jq -e \
      --arg manifest_version "$DARKREADER_FORK_MANIFEST_VERSION" \
      --arg version_name "$DARKREADER_FORK_VERSION_NAME" '
      .version == $manifest_version and
      .version_name == $version_name and
      (.permissions | index("nativeMessaging") != null)
    ' "$staging/manifest.json" >/dev/null 2>&1; then
    rm -rf -- "$staging"
    darkreader_bridge_error="downloaded fork release failed validation"
    return 1
  fi

  previous="$install_dir/extension.previous"
  rm -rf -- "$previous"
  [[ ! -d "$extension_dir" ]] || mv "$extension_dir" "$previous"
  mv "$staging" "$extension_dir"
  rm -rf -- "$previous"

  tmp=$(mktemp "$install_dir/release.XXXXXX.json") || return 1
  jq -n \
    --arg tag "$DARKREADER_FORK_RELEASE" \
    --arg url "$DARKREADER_FORK_RELEASE_URL" \
    --arg sha256 "$DARKREADER_FORK_RELEASE_SHA256" \
    '{tag: $tag, url: $url, sha256: $sha256}' >"$tmp" \
    && mv -f "$tmp" "$install_dir/release.json"
}

# Validate and register the pinned release downloaded from the Dark Reader fork.
# The fork retains Dark Reader's Web Store manifest key, so loading it once
# reuses the existing extension ID and chrome.storage data.
darkreader_bridge_register() {
  local extension_dir="$1" host_executable="$2" manifest background required

  darkreader_bridge_error=""
  darkreader_bridge_extension_dir="$extension_dir"
  manifest="$extension_dir/manifest.json"
  background="$extension_dir/background/index.js"

  for required in jq openssl base64 realpath; do
    if ! command -v "$required" >/dev/null 2>&1; then
      darkreader_bridge_error="$required is required"
      return 1
    fi
  done
  if [[ ! -f "$manifest" || ! -f "$background" ]]; then
    darkreader_bridge_error="patched extension is not installed; run chezmoi apply"
    return 1
  fi
  if [[ ! -x "$host_executable" ]]; then
    darkreader_bridge_error="native host is not installed; run chezmoi apply"
    return 1
  fi
  if [[ "$(darkreader_manifest_extension_id "$manifest")" \
      != "$DARKREADER_EXTENSION_ID" ]]; then
    darkreader_bridge_error="patched extension identity is invalid"
    return 1
  fi
  if ! jq -e '
    (.permissions | index("nativeMessaging") != null) and
    (.background.service_worker == "background/index.js")
  ' "$manifest" >/dev/null 2>&1 \
    || ! grep -q 'com\.chong\.darkreader_theme' "$background" \
    || ! grep -q 'connectNative' "$background"; then
    darkreader_bridge_error="patched extension is missing its native bridge"
    return 1
  fi
  if ! darkreader_write_native_manifests "$host_executable"; then
    darkreader_bridge_error="could not register the native messaging host"
    return 1
  fi

  darkreader_bridge_loaded=0
  darkreader_bridge_is_loaded "$extension_dir" && darkreader_bridge_loaded=1
  return 0
}
