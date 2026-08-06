local micro = import("micro")
local buffer = import("micro/buffer")
local util = import("micro/util")

function toggleWrap(bp)
    local on = not bp.Buf.Settings["softwrap"]
    bp.Buf:SetOptionNative("softwrap", on)
    bp.Buf:SetOptionNative("wordwrap", on)
    micro.InfoBar():Message("word wrap: " .. (on and "on" or "off"))
    return true
end

-- Expand the selection to the nearest enclosing bracket pair, VSCode
-- expand-region style: cursor -> inside the brackets -> including the
-- brackets -> inside the next pair out -> ...
local OPENERS = { ["("] = ")", ["["] = "]", ["{"] = "}" }
local CLOSERS = { [")"] = "(", ["]"] = "[", ["}"] = "{" }
local QUOTES = { ['"'] = true, ["'"] = true, ["`"] = true }
local SCAN_BUDGET = 200000

-- Split a line into runes so indices line up with Loc.X (which counts runes,
-- not bytes). Rune index i corresponds to Loc.X == i - 1.
local function runesOf(buf, st, y)
    local cached = st.cache[y]
    if cached then return cached end

    local line = buf:Line(y)
    local runes = {}
    local b = 1
    while b <= #line do
        local lead = line:byte(b)
        local size = 1
        if lead >= 0xf0 then size = 4
        elseif lead >= 0xe0 then size = 3
        elseif lead >= 0xc0 then size = 2 end
        runes[#runes + 1] = line:sub(b, b + size - 1)
        b = b + size
    end

    st.cache[y] = runes
    return runes
end

-- Walk backwards from rune index x on line y looking for an unmatched opener.
local function findOpener(buf, st, y, x)
    local depth = 0
    while y >= 0 do
        local runes = runesOf(buf, st, y)
        if x == nil then x = #runes end
        for i = x, 1, -1 do
            local ch = runes[i]
            if CLOSERS[ch] then
                depth = depth + 1
            elseif OPENERS[ch] then
                if depth == 0 then return y, i end
                depth = depth - 1
            end
            st.budget = st.budget - 1
            if st.budget <= 0 then return nil end
        end
        y, x = y - 1, nil
    end
    return nil
end

-- Walk forwards from the opener at (y, x) looking for its matching closer.
local function findCloser(buf, st, y, x)
    local depth = 0
    local numLines = buf:LinesNum()
    local i = x + 1
    while y < numLines do
        local runes = runesOf(buf, st, y)
        for j = i, #runes do
            local ch = runes[j]
            if OPENERS[ch] then
                depth = depth + 1
            elseif CLOSERS[ch] then
                if depth == 0 then return y, j end
                depth = depth - 1
            end
            st.budget = st.budget - 1
            if st.budget <= 0 then return nil end
        end
        y, i = y + 1, 1
    end
    return nil
end

-- Innermost bracket pair strictly enclosing the span [(sy,sx), (ey,ex)).
local function enclosingPair(buf, st, sy, sx, ey, ex)
    local y, x = sy, sx
    while true do
        local oy, ox = findOpener(buf, st, y, x)
        if oy == nil then return nil end

        local cy, cx = findCloser(buf, st, oy, ox)
        if cy == nil then return nil end

        -- The pair may close before the span ends (unbalanced brackets in
        -- between); if so keep looking further out.
        if cy > ey or (cy == ey and cx - 1 >= ex) then return oy, ox, cy, cx end
        y, x = oy, ox - 1
    end
end

-- Quotes are their own opener and closer, so they can't be matched by depth
-- counting. Pair them off left to right within a single line instead.
local function quotePairs(buf, st, y)
    local runes = runesOf(buf, st, y)
    local found = {}
    local openIdx, openCh = nil, nil
    local i = 1
    while i <= #runes do
        local ch = runes[i]
        if ch == "\\" and openIdx ~= nil then
            i = i + 1                       -- escaped char, never a delimiter
        elseif QUOTES[ch] then
            if openIdx == nil then
                openIdx, openCh = i, ch
            elseif ch == openCh then        -- a different quote is just content
                found[#found + 1] = { openIdx, i }
                openIdx, openCh = nil, nil
            end
        end
        i = i + 1
    end
    return found
end

-- Innermost quote pair on line y enclosing the span [sx, ex).
local function enclosingQuote(buf, st, y, sx, ex)
    local best = nil
    for _, p in ipairs(quotePairs(buf, st, y)) do
        if p[1] <= sx and p[2] - 1 >= ex then
            if best == nil or p[1] > best[1] then best = p end
        end
    end
    return best
end

function expandSelection(bp)
    local c = bp.Cursor
    local sy, sx, ey, ex
    if c:HasSelection() then
        local a, b = c.CurSelection[1], c.CurSelection[2]
        if a.Y > b.Y or (a.Y == b.Y and a.X > b.X) then a, b = b, a end
        sy, sx, ey, ex = a.Y, a.X, b.Y, b.X
    else
        sy, sx, ey, ex = c.Y, c.X, c.Y, c.X
    end

    local st = { budget = SCAN_BUDGET, cache = {} }
    local oy, ox, cy, cx = enclosingPair(bp.Buf, st, sy, sx, ey, ex)

    -- A quote pair only counts when it beats the bracket pair, i.e. when it
    -- opens later and so encloses the span more tightly.
    if sy == ey then
        local q = enclosingQuote(bp.Buf, st, sy, sx, ex)
        if q ~= nil and (oy == nil or sy > oy or (sy == oy and q[1] > ox)) then
            oy, ox, cy, cx = sy, q[1], sy, q[2]
        end
    end

    -- Cursor parked directly on a delimiter: use the pair it opens rather than
    -- the one around it.
    if not c:HasSelection() then
        local atCursor = runesOf(bp.Buf, st, sy)[sx + 1]
        if atCursor ~= nil and OPENERS[atCursor] then
            local ncy, ncx = findCloser(bp.Buf, st, sy, sx + 1)
            if ncy ~= nil then oy, ox, cy, cx = sy, sx + 1, ncy, ncx end
        elseif atCursor ~= nil and QUOTES[atCursor] then
            for _, p in ipairs(quotePairs(bp.Buf, st, sy)) do
                if p[1] == sx + 1 then oy, ox, cy, cx = sy, p[1], sy, p[2] end
            end
        end
    end

    if oy == nil or cy == nil then
        micro.InfoBar():Message("expand: no enclosing bracket or quote")
        return true
    end

    local inner = { oy, ox, cy, cx - 1 }      -- between the delimiters
    local outer = { oy, ox - 1, cy, cx }      -- including the delimiters

    -- Already on the inner span (or the pair is empty, so the inner span is a
    -- no-op selection): take the brackets too.
    local onInner = sy == inner[1] and sx == inner[2] and ey == inner[3] and ex == inner[4]
    local empty = inner[1] == inner[3] and inner[2] == inner[4]
    local target = (onInner or empty) and outer or inner

    c:SetSelectionStart(buffer.Loc(target[2], target[1]))
    c:SetSelectionEnd(buffer.Loc(target[4], target[3]))
    c:GotoLoc(buffer.Loc(target[4], target[3]))
    c:Relocate()
    bp:Relocate()
    return true
end

-- VSCode-style find: Ctrl-f opens the prompt, Enter jumps to the next match
-- while the prompt stays open, Esc leaves it with the cursor on the current
-- match. Micro's built-in Find closes the prompt on Enter, but DonePrompt
-- resets the infobar state before invoking the done-callback, so the callback
-- can re-open the prompt with the same query and keep the loop going.

-- Loc fields reached through the cursor alias live Go state; copy before
-- storing across callbacks.
local function locCopy(l)
    return buffer.Loc(l.X, l.Y)
end

local function selectMatch(bp, match)
    bp.Cursor:SetSelectionStart(match[1])
    bp.Cursor:SetSelectionEnd(match[2])
    bp:GotoLoc(match[2])
end

local function findPrompt(bp, pattern, origin, selectInput)
    local lastText = pattern

    -- Fires on every edit of the prompt text: incremental search anchored at
    -- origin, with all matches highlighted while the prompt is open.
    local eventcb = function(resp)
        lastText = resp
        bp.Buf.LastSearch = resp
        bp.Buf.LastSearchRegex = false
        bp.Buf.HighlightSearch = resp ~= ""
        local match, found = bp.Buf:FindNext(resp, bp.Buf:Start(), bp.Buf:End(), origin, true, false)
        if found then
            selectMatch(bp, match)
        else
            bp:GotoLoc(origin)
            bp.Cursor:ResetSelection()
        end
    end

    local donecb = function(resp, canceled)
        if canceled or resp == "" then
            -- Keep the cursor on the current match; highlights revert to the
            -- hlsearch setting once the prompt closes. LastSearch stays
            -- committed so FindNext (Alt-f) continues from here.
            bp.Buf.LastSearch = lastText
            bp.Buf.LastSearchRegex = false
            bp.Buf.HighlightSearch = bp.Buf.Settings["hlsearch"] == true and lastText ~= ""
            return
        end
        -- Enter: advance to the next match, searching from the end of the
        -- current one, then re-open the prompt (wraps around like FindNext).
        local from = locCopy(bp.Cursor.Loc)
        if bp.Cursor:HasSelection() then
            from = locCopy(bp.Cursor.CurSelection[2])
        end
        local match, found = bp.Buf:FindNext(resp, bp.Buf:Start(), bp.Buf:End(), from, true, false)
        local nextOrigin = origin
        if found then
            selectMatch(bp, match)
            nextOrigin = locCopy(match[1])
        end
        findPrompt(bp, resp, nextOrigin, false)
    end

    micro.InfoBar():Prompt("Find: ", pattern, "Find", eventcb, donecb)
    if selectInput and pattern ~= "" then
        micro.InfoBar():SelectAll()
    end
end

function vsFind(bp)
    local pattern = ""
    local origin = locCopy(bp.Cursor.Loc)
    if bp.Cursor:HasSelection() then
        pattern = util.String(bp.Cursor:GetSelection())
        origin = locCopy(bp.Cursor.CurSelection[1])
    end
    findPrompt(bp, pattern, origin, true)
    return true
end

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
