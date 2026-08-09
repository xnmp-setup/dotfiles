#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d /tmp/hypr-workspace-cli.XXXXXX)
cleanup() {
  [[ "$test_root" == /tmp/hypr-workspace-cli.* ]] && rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$test_root/bin" "$test_root/config" "$test_root/state/workspaces"
ln -s "$repo_root/dot_config/hypr/workspace_catalog.lua" \
  "$test_root/config/workspace_catalog.lua"

now=$(date +%s)
cat >"$test_root/state/workspaces/2.lua" <<'SNAPSHOT'
return { ["version"] = 2, ["windows"] = { { ["class"] = "google-chrome" } } }
SNAPSHOT
cat >"$test_root/state/workspaces/index.lua" <<INDEX
return {
  ["version"] = 1,
  ["workspaces"] = {
    {
      ["workspace_id"] = 2,
      ["name"] = "Project Alpha",
      ["saved_at"] = $now,
      ["window_count"] = 5,
      ["app_count"] = 3,
      ["shell_count"] = 1
    }
  }
}
INDEX

cat >"$test_root/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_HYPRCTL_LOG"
case "$*" in
  *'session.forget_workspace(2)'*)
    cat > "$HYPR_WORKSPACE_STATE_DIR/workspaces/index.lua" <<'INDEX'
return { ["version"] = 1, ["workspaces"] = {} }
INDEX
    rm -f -- "$HYPR_WORKSPACE_STATE_DIR/workspaces/2.lua"
    ;;
esac
EOF
chmod +x "$test_root/bin/hyprctl"

run_cli() {
  TEST_HYPRCTL_LOG="$test_root/hyprctl.log" \
    HYPR_WORKSPACE_CONFIG_DIR="$test_root/config" \
    HYPR_WORKSPACE_STATE_DIR="$test_root/state" \
    HYPR_WORKSPACE_HYPRCTL="$test_root/bin/hyprctl" \
    lua "$repo_root/dot_local/bin/executable_hypr-workspace" "$@"
}

: >"$test_root/hyprctl.log"
picker=$(run_cli list --picker)
[[ "$picker" == $'Project Alpha\t5 windows · 3 apps · opened just now\t2' ]] ||
  fail "picker output did not include a consistently formatted workspace summary"

restore_output=$(run_cli restore 2)
[[ "$restore_output" == 'Restoring Project Alpha (5 windows, 3 apps).' ]] ||
  fail "restore did not report the selected workspace"
grep -Fq -- 'dispatch session.restore_workspace(2)' "$test_root/hyprctl.log" ||
  fail "restore did not dispatch the selected workspace id"

if run_cli restore '../../escape' >"$test_root/invalid.out" 2>&1; then
  fail "a malformed workspace id was accepted"
fi
grep -Fq -- 'positive integer' "$test_root/invalid.out" ||
  fail "an invalid workspace id had no useful error"

forget_output=$(run_cli forget 2)
[[ "$forget_output" == 'Forgot Project Alpha.' ]] ||
  fail "forget did not report success"
[[ -z "$(run_cli list)" ]] || fail "forgotten workspace remained in the catalog"

if run_cli restore 2 >"$test_root/missing.out" 2>&1; then
  fail "a forgotten workspace was restored"
fi
grep -Fq -- 'workspace 2 is not restorable' "$test_root/missing.out" ||
  fail "a missing workspace had no useful error"

echo "hypr-workspace CLI tests passed"
