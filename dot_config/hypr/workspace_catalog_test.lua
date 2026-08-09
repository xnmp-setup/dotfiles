-- Offline tests for recent Hyprland workspace catalog behavior.
-- Run: lua workspace_catalog_test.lua

package.path = (arg[0]:match("^(.*)/") or ".") .. "/?.lua;" .. package.path

local catalog = require("workspace_catalog")

local checks, failures = 0, 0
local function check(label, value)
    checks = checks + 1
    if value then return end
    failures = failures + 1
    io.write("FAIL  " .. label .. "\n")
end
local function equal(label, got, want)
    check(("%s (got %s, want %s)"):format(label, tostring(got), tostring(want)), got == want)
end

do
    equal("numeric workspace ids are accepted", catalog.workspace_id("42"), 42)
    check("null ids are rejected", catalog.workspace_id(nil) == nil)
    check("zero ids are rejected", catalog.workspace_id(0) == nil)
    check("fractional ids are rejected", catalog.workspace_id(1.5) == nil)
    check("huge ids are rejected", catalog.workspace_id(2147483648) == nil)
end

do
    local original = catalog.empty()
    local first, work = assert(catalog.upsert(original, {
        workspace_id = 2, name = "Project Alpha", saved_at = 20,
        window_count = 8, app_count = 4, shell_count = 2,
    }))
    equal("entries are keyed by workspace id", work.workspace_id, 2)
    equal("the source catalog is immutable", #original.workspaces, 0)
    equal("named workspaces keep their display name",
        catalog.display_name(work), "Project Alpha")

    local second, plain = assert(catalog.upsert(first, {
        workspace_id = 3, name = "3", saved_at = 30, window_count = 2,
    }))
    equal("numeric names get a useful label", catalog.display_name(plain), "Workspace 3")
    local overwritten, updated = assert(catalog.upsert(second, {
        workspace_id = 2, name = "Renamed", saved_at = 40, window_count = 9,
    }))
    equal("reopening a workspace overwrites its one snapshot", #overwritten.workspaces, 2)
    equal("an updated workspace name is retained", updated.name, "Renamed")
    equal("updated metadata replaces the old values",
        catalog.find(overwritten, 2).window_count, 9)
    equal("the newest workspace is listed first", catalog.list(overwritten)[1].workspace_id, 2)

    local without_work, removed = assert(catalog.remove(overwritten, "2"))
    equal("remove returns the removed workspace", removed.workspace_id, 2)
    check("the removed workspace is absent", catalog.find(without_work, 2) == nil)
    equal("unrelated workspaces remain", catalog.find(without_work, 3).workspace_id, 3)
end

do
    local retention = catalog.RETENTION_SECONDS
    local current = catalog.normalize({
        version = catalog.VERSION,
        workspaces = {
            { workspace_id = 1, name = "1", saved_at = 100 },
            { workspace_id = 2, name = "Two", saved_at = 99 },
            { workspace_id = 3, name = "Three", saved_at = 101 },
        },
    })
    local pruned, expired = catalog.prune(current, 100 + retention, retention)
    equal("exactly two weeks old remains restorable", #pruned.workspaces, 2)
    equal("older than two weeks expires", expired[1].workspace_id, 2)
    equal("pruning leaves its input unchanged", #current.workspaces, 3)
end

do
    local repaired = catalog.normalize({
        version = catalog.VERSION,
        workspaces = {
            { workspace_id = 4, name = "Good", saved_at = 1 },
            { workspace_id = 4, name = "Duplicate id" },
            { workspace_id = "../../escape", name = "Unsafe" },
            { workspace_id = 5, name = "bad\nname" },
            false,
        },
    })
    equal("malformed rows do not hide valid rows", #repaired.workspaces, 2)
    equal("unsafe names fall back to the numeric workspace name",
        repaired.workspaces[2].name, "5")
    equal("unsupported catalogs degrade to empty",
        #catalog.normalize({ version = 999, workspaces = {} }).workspaces, 0)
    equal("a malformed workspace list degrades to empty",
        #catalog.normalize({ version = catalog.VERSION, workspaces = "bad" }).workspaces, 0)
end

io.write(("%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
