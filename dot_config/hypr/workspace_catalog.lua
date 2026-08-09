-- workspace_catalog.lua — pure index operations for restorable workspaces.
--
-- session_restore.lua owns IO and compositor calls. Keeping catalog repair,
-- retention, and ordering here makes the user-visible contract testable
-- without Hyprland or a writable home.

local M = {}

M.VERSION = 1
M.RETENTION_SECONDS = 14 * 24 * 60 * 60
M.MAX_WORKSPACE_ID = 2147483647

local function non_negative_integer(value)
    value = tonumber(value)
    if not value or value % 1 ~= 0 or value < 0 then return 0 end
    return value
end

function M.workspace_id(value)
    value = tonumber(value)
    if not value or value % 1 ~= 0 or value < 1 or value > M.MAX_WORKSPACE_ID then
        return nil
    end
    return value
end

local function normalized_name(value, workspace_id)
    if type(value) ~= "string" or value == "" then return tostring(workspace_id) end
    if value:find("[%z\1-\31\127]") or not utf8.len(value) then
        return tostring(workspace_id)
    end
    return value
end

function M.empty()
    return { version = M.VERSION, workspaces = {} }
end

local function normalized_entry(value)
    if type(value) ~= "table" then return nil end
    local workspace_id = M.workspace_id(value.workspace_id)
    if not workspace_id then return nil end
    return {
        workspace_id = workspace_id,
        name = normalized_name(value.name, workspace_id),
        saved_at = non_negative_integer(value.saved_at),
        window_count = non_negative_integer(value.window_count),
        app_count = non_negative_integer(value.app_count),
        shell_count = non_negative_integer(value.shell_count),
    }
end

-- Invalid entries are repaired independently. A truncated row must not hide
-- every other restorable workspace, and duplicate IDs deterministically keep
-- the first valid row.
function M.normalize(value)
    if type(value) ~= "table" or value.version ~= M.VERSION then return M.empty() end
    local workspaces, seen = {}, {}
    local candidates = type(value.workspaces) == "table" and value.workspaces or {}
    for _, candidate in ipairs(candidates) do
        local entry = normalized_entry(candidate)
        if entry and not seen[entry.workspace_id] then
            workspaces[#workspaces + 1] = entry
            seen[entry.workspace_id] = true
        end
    end
    return { version = M.VERSION, workspaces = workspaces }
end

function M.find(value, requested_id)
    local workspace_id = M.workspace_id(requested_id)
    if not workspace_id then return nil end
    for _, entry in ipairs(M.normalize(value).workspaces) do
        if entry.workspace_id == workspace_id then return entry end
    end
    return nil
end

function M.upsert(value, metadata)
    metadata = metadata or {}
    local workspace_id = M.workspace_id(metadata.workspace_id)
    if not workspace_id then return nil, nil, "invalid workspace id" end
    local entry = normalized_entry({
        workspace_id = workspace_id,
        name = metadata.name,
        saved_at = metadata.saved_at,
        window_count = metadata.window_count,
        app_count = metadata.app_count,
        shell_count = metadata.shell_count,
    })
    local current, workspaces, replaced = M.normalize(value), {}, false
    for _, candidate in ipairs(current.workspaces) do
        if candidate.workspace_id == workspace_id then
            workspaces[#workspaces + 1], replaced = entry, true
        else
            workspaces[#workspaces + 1] = candidate
        end
    end
    if not replaced then workspaces[#workspaces + 1] = entry end
    return { version = M.VERSION, workspaces = workspaces }, entry
end

function M.remove(value, requested_id)
    local workspace_id = M.workspace_id(requested_id)
    if not workspace_id then return nil, nil, "invalid workspace id" end
    local current, workspaces, removed = M.normalize(value), {}, nil
    for _, entry in ipairs(current.workspaces) do
        if entry.workspace_id == workspace_id then
            removed = entry
        else
            workspaces[#workspaces + 1] = entry
        end
    end
    return { version = M.VERSION, workspaces = workspaces }, removed
end

function M.prune(value, now, retention_seconds)
    now = non_negative_integer(now)
    retention_seconds = non_negative_integer(retention_seconds or M.RETENTION_SECONDS)
    local threshold = math.max(0, now - retention_seconds)
    local kept, expired = {}, {}
    for _, entry in ipairs(M.normalize(value).workspaces) do
        if entry.saved_at >= threshold then
            kept[#kept + 1] = entry
        else
            expired[#expired + 1] = entry
        end
    end
    return { version = M.VERSION, workspaces = kept }, expired
end

function M.list(value)
    local entries = M.normalize(value).workspaces
    table.sort(entries, function(a, b)
        if a.saved_at ~= b.saved_at then return a.saved_at > b.saved_at end
        return a.workspace_id < b.workspace_id
    end)
    return entries
end

function M.display_name(entry)
    if not entry then return "Workspace" end
    local name = normalized_name(entry.name, entry.workspace_id)
    if name == tostring(entry.workspace_id) then
        return "Workspace " .. tostring(entry.workspace_id)
    end
    return name
end

return M
