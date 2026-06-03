local micro = import("micro")
local buffer = import("micro/buffer")

local snippets = {
    python = {
        qq = "# %% ━━━━━━━━  ━━━━━━━━",
    },
}

function preInsertTab(bp)
    if bp.Cursor:HasSelection() then
        return false
    end

    local filetype = bp.Buf.Settings["filetype"]
    local ftSnippets = snippets[filetype]
    if not ftSnippets then return false end

    local line = bp.Buf:Line(bp.Cursor.Y)
    local cx = bp.Cursor.X

    local x = cx
    while x > 0 do
        local ch = line:sub(x, x)
        if ch:match("[%w_]") then
            x = x - 1
        else
            break
        end
    end
    local word = line:sub(x + 1, cx)

    if word == "" then return false end

    local expansion = ftSnippets[word]
    if not expansion then return false end

    local loc1 = buffer.Loc(x, bp.Cursor.Y)
    local loc2 = buffer.Loc(cx, bp.Cursor.Y)
    bp.Buf:Replace(loc1, loc2, expansion)
    bp.Cursor:Relocate()
    return true
end
