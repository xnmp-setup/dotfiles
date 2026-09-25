#!/usr/bin/env bash
# Contract tests between this repo and the installed Vicinae. They pin the
# assumptions that a Vicinae upgrade can silently break; checks that need the
# vicinae binary are skipped where it is not installed.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=${script_dir%/scripts}
failures=0

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*" >&2; failures=$((failures + 1)); }
skip() { echo "SKIP  $*"; }

major_minor() { sed -E 's/^[^0-9]*([0-9]+\.[0-9]+).*/\1/'; }

# --- settings.json ---------------------------------------------------------
# Vicinae parses JSONC; strip full-line comments so jq can read the render.
settings=$(chezmoi --source "$repo_dir" execute-template \
  <"$repo_dir/dot_config/vicinae/settings.json.tmpl" | sed -E '/^[[:space:]]*\/\//d')

if jq -e . >/dev/null <<<"$settings"; then
  pass "settings.json renders to valid JSON"
else
  fail "settings.json does not render to valid JSON"
fi

# hyprland.lua's special-workspace modal needs an ordinary toplevel window.
if [[ $(jq '.launcher_window.layer_shell.enabled' <<<"$settings") == false ]]; then
  pass "launcher opts out of layer-shell"
else
  fail "launcher_window.layer_shell.enabled must be false"
fi

# page_key_routing.lua sends eight Down presses per PageDown; wrapping would
# turn a PageDown near the end into a jump to the top.
if [[ $(jq '.wrap_navigation // false' <<<"$settings") == false ]]; then
  pass "list navigation does not wrap"
else
  fail "wrap_navigation must be false or unset"
fi

for variant in light dark; do
  if [[ -n $(jq -r ".theme.$variant.name // empty" <<<"$settings") ]]; then
    pass "theme.$variant.name is set"
  else
    fail "theme.$variant.name is missing"
  fi
done

# --- installed runtime -----------------------------------------------------
if ! command -v vicinae >/dev/null 2>&1; then
  skip "vicinae not installed; runtime checks skipped"
  exit $((failures > 0))
fi

runtime_version=$(vicinae version | head -1 | major_minor)

# The bundle is typechecked against one @vicinae/api version but runs on the
# API the installed vicinae injects; minor versions may change that surface, so
# rebuild against the matching API. The deployed package.json is copied by `vici build`.
bundle_manifest="$repo_dir/dot_local/share/vicinae/extensions/desktop-theme/package.json"
bundle_version=$(jq -r '.dependencies["@vicinae/api"]' "$bundle_manifest" | major_minor)
if [[ "$bundle_version" == "$runtime_version" ]]; then
  pass "desktop-theme bundle API $bundle_version matches vicinae $runtime_version"
else
  fail "desktop-theme bundle built for API $bundle_version, vicinae is $runtime_version (rebuild local_extensions/vicinae-desktop-theme)"
fi

for script in "$repo_dir"/dot_local/share/vicinae/scripts/*; do
  if vicinae script check "$script" >/dev/null 2>&1; then
    pass "script command $(basename "$script") is valid"
  else
    fail "vicinae rejects script command $(basename "$script")"
  fi
done

exit $((failures > 0))
