#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/scripts/lib/theme-colors.sh"
source "$repo_root/scripts/lib/scrivo-theme.sh"
test_root=$(mktemp -d /tmp/scrivo-theme-test.XXXXXX)
SCRIVO_OBSIDIAN_THEMES_DIR="$test_root/obsidian"
trap 'rm -rf -- "$test_root"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

scrivo_apply_theme "$repo_root/dot_config/tauri-explorer/themes" "$test_root/config" nord dark
catalog="$test_root/config/desktop-theme.json"
jq -e '.theme == "builtin:desktop:nord" and .mode == "dark" and
  (.themes[] | select(.id == "builtin:desktop:nord") | .css | contains("--background-primary: #292e39;"))' \
  "$catalog" >/dev/null || fail 'Nord selection or palette is incorrect'
palette_count=$(find "$repo_root/dot_config/tauri-explorer/themes" -name '*.css' | wc -l)
[[ "$(jq '.themes | length' "$catalog")" == "$palette_count" ]] || fail 'catalog omits desktop palettes'
for css in "$test_root/config/themes/"*.css; do
  grep -Eq -- '--[a-z-]+:[[:space:]]*;' "$css" && fail "empty CSS token in $css"
done

# Existing stylesheets are user-editable and must survive switching.
printf ':root { --background-primary: #abcdef; }\n' >"$test_root/config/themes/mint-light.css"
scrivo_apply_theme "$repo_root/dot_config/tauri-explorer/themes" "$test_root/config" mint-light light
jq -e '.theme == "builtin:desktop:mint-light" and .mode == "light" and
  (.themes[] | select(.id == "builtin:desktop:mint-light") | .css | contains("#abcdef"))' \
  "$catalog" >/dev/null || fail 'light mode or preserved custom palette is incorrect'
cp "$catalog" "$test_root/before.json"
if scrivo_apply_theme "$repo_root/dot_config/tauri-explorer/themes" "$test_root/config" missing dark; then
  fail 'missing palette accepted'
fi
cmp -s "$catalog" "$test_root/before.json" || fail 'failure changed the current catalog'
mkdir -p "$test_root/bad"
printf '[data-theme="bad"] { --background-solid: #123456; }\n' >"$test_root/bad/bad.css"
if scrivo_apply_theme "$test_root/bad" "$test_root/config" bad dark; then
  fail 'incomplete palette accepted'
fi
cmp -s "$catalog" "$test_root/before.json" || fail 'malformed input changed the current catalog'
printf ' \n' >"$test_root/config/themes/mint-light.css"
if scrivo_apply_theme "$repo_root/dot_config/tauri-explorer/themes" "$test_root/config" nord dark; then
  fail 'blank preserved theme accepted'
fi
cmp -s "$catalog" "$test_root/before.json" || fail 'blank CSS changed the current catalog'
head -c 1048577 /dev/zero | tr '\0' x >"$test_root/config/themes/mint-light.css"
if scrivo_apply_theme "$repo_root/dot_config/tauri-explorer/themes" "$test_root/config" nord dark; then
  fail 'oversized preserved theme accepted'
fi
cmp -s "$catalog" "$test_root/before.json" || fail 'oversized CSS changed the current catalog'

# An installed Obsidian equivalent wins over the desktop approximation and
# refreshes an existing Scrivo stylesheet when its upstream palette changes.
mkdir -p "$SCRIVO_OBSIDIAN_THEMES_DIR/Nord" "$SCRIVO_OBSIDIAN_THEMES_DIR/Mint Light"
cp "$repo_root/Vaults/Technical Vault/dot_obsidian/themes/Mint Light/theme.css" \
  "$SCRIVO_OBSIDIAN_THEMES_DIR/Mint Light/theme.css"
cat >"$SCRIVO_OBSIDIAN_THEMES_DIR/Nord/theme.css" <<'EOF'
.theme-dark {
  --background-primary: #2e3440;
  --text-normal: #d8dee9;
  --h1-color: #88c0d0;
  --color-blue: #81a1c1;
  --link-color: var(--color-blue);
}
.theme-light { --background-primary: #f5f5f5; --text-normal: #222222; }
.workspace { display: none; }
EOF
scrivo_apply_theme "$repo_root/dot_config/tauri-explorer/themes" "$test_root/config" nord dark
grep -Fq -- '--background-primary: #2e3440' "$test_root/config/themes/nord.css" \
  || fail 'existing Nord stylesheet was not refreshed from Obsidian'
grep -Fq -- '--link-color: var(--color-blue)' "$test_root/config/themes/nord.css" \
  || fail 'computed Obsidian color lost its dependency'
grep -Fq -- '--background-primary: #f5f5f5' "$test_root/config/themes/nord.css" \
  || fail 'light variant lost during import'
grep -Fq 'display: none' "$test_root/config/themes/nord.css" && fail 'Obsidian layout leaked into Scrivo'
sed -i 's/#2e3440/#123456/' "$SCRIVO_OBSIDIAN_THEMES_DIR/Nord/theme.css"
scrivo_apply_theme "$repo_root/dot_config/tauri-explorer/themes" "$test_root/config" nord dark
jq -e '.themes[] | select(.id == "builtin:desktop:nord") | .css | contains("--background-primary: #123456")' \
  "$catalog" >/dev/null || fail 'catalog did not track updated Obsidian palette'
node "$repo_root/scripts/scrivo-obsidian-theme.test.cjs"
echo 'PASS: Scrivo desktop theme catalog'
