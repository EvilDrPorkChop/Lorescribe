-- Lorescribe UI: the library window (list and reader) and the export box.
local ADDON, ns = ...
local L = ns.L

local UI = {}
ns.UI = UI

local INK = { 0.20, 0.12, 0.04 }
local MUTED = { 0.42, 0.31, 0.18 }
local ACCENT = { 0.48, 0.15, 0.03 }
local PARCHMENT = { 0.87, 0.79, 0.62 }

local LIST_W = 320
local ROW_H = 40
local EXPORT_CHUNK = 60000  -- EditBoxes get sluggish past ~100k characters

local KIND_TABLE = { quest = "quests", book = "books", gossip = "gossip" }

local VIEWS = {
    { key = "readlater", label = L.VIEW_READLATER },
    { key = "quest", label = L.VIEW_QUESTS },
    { key = "book", label = L.VIEW_BOOKS },
    { key = "gossip", label = L.VIEW_DIALOGUE },
    { key = "people", label = L.VIEW_PEOPLE },
    { key = "starred", label = L.VIEW_STARRED },
    { key = "all", label = L.VIEW_ALL },
}

local SORTS = {
    { key = "newest", label = L.SORT_NEWEST },
    { key = "zone", label = L.SORT_ZONE },
    { key = "title", label = L.SORT_TITLE },
}

local state = { view = "readlater", search = "", zone = nil, char = nil, sort = "newest" }
local current   -- the entry shown in the reader
local backTo    -- the person whose page the current entry was opened from
local frame     -- main window, built on first use
local BuildPeople, NameEntry  -- defined with the People view below

------------------------------------------------------------------------------
-- Text
------------------------------------------------------------------------------

-- Quest text normally arrives with names filled in; this covers any that don't.
local function Substitute(s)
    if not s:find("$", 1, true) then return s end
    local name = UnitName("player") or ""
    local class = UnitClass("player") or ""
    local race = UnitRace("player") or ""
    local female = UnitSex("player") == 3
    s = s:gsub("%$[Gg]%s*([^:;]*):([^;]*);", function(male, fem) return female and fem or male end)
    s = s:gsub("%$[Nn]", function() return name end)
    s = s:gsub("%$[Cc]", function() return class end)
    s = s:gsub("%$[Rr]", function() return race end)
    s = s:gsub("%$[Bb]", "\n")
    return s
end

-- Some books are stored as simple HTML.
local function StripHTML(s)
    if not s:find("^%s*<[Hh][Tt][Mm][Ll]") then return s end
    s = s:gsub("<[Bb][Rr]%s*/?>", "\n")
    s = s:gsub("</[Pp]>", "\n")
    s = s:gsub("</[Hh]%d>", "\n")
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", "\""):gsub("&nbsp;", " "):gsub("&amp;", "&")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function Display(s)
    if not s then return "" end
    return Substitute(StripHTML(s))
end

local function StripCodes(s)
    s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
    s = s:gsub("|r", "")
    s = s:gsub("|T.-|t", "")
    s = s:gsub("|A.-|a", "")
    s = s:gsub("|H.-|h(.-)|h", "%1")
    s = s:gsub("|n", "\n")
    return s
end

local function FormatDate(t)
    return t and date("%d %b %Y", t) or nil
end

local function FormatCoords(x, y)
    if not x then return nil end
    return string.format("%.1f, %.1f", x * 100, y * 100)
end

------------------------------------------------------------------------------
-- Entries
------------------------------------------------------------------------------

local function Characters(e)
    if e.kind == "book" then return e.rec.seenBy end
    return e.rec.characters
end

local function MaxPage(pages)
    local n = 0
    for p in pairs(pages) do
        if p > n then n = p end
    end
    return n
end

local function Haystack(e)
    local r = e.rec
    local parts = { e.title or "", e.zone or "", r.note or "" }
    if e.kind == "quest" then
        parts[#parts + 1] = r.giver or ""
        for _, f in ipairs(ns.QUEST_TEXT_FIELDS) do parts[#parts + 1] = r[f] or "" end
    elseif e.kind == "book" then
        for _, text in pairs(r.pages) do parts[#parts + 1] = text end
    else
        parts[#parts + 1] = r.text or ""
    end
    return table.concat(parts, "\n"):lower()
end

local function Matches(e, search)
    local v, r = state.view, e.rec
    if v == "readlater" and not ns.InQueue(r) then return false end
    if (v == "quest" or v == "book" or v == "gossip") and e.kind ~= v then return false end
    if v == "starred" and not r.starred then return false end
    if state.zone and e.zone ~= state.zone then return false end
    if state.char then
        local chars = Characters(e)
        if not (chars and chars[state.char]) then return false end
    end
    if search and not Haystack(e):find(search, 1, true) then return false end
    return true
end

local SORTERS = {
    newest = function(a, b)
        if a.time ~= b.time then return a.time > b.time end
        return a.sortTitle < b.sortTitle
    end,
    zone = function(a, b)
        local za, zb = a.zone or "~", b.zone or "~"
        if za ~= zb then return za < zb end
        return a.sortTitle < b.sortTitle
    end,
    title = function(a, b)
        if a.sortTitle ~= b.sortTitle then return a.sortTitle < b.sortTitle end
        return a.time > b.time
    end,
}

local function NewEntry(kind, key, rec, title, zone)
    return {
        id = kind .. ":" .. tostring(key), kind = kind, key = key, rec = rec,
        title = title, zone = zone, sortTitle = title:lower(),
        time = rec.firstSeen or 0,
    }
end

-- The list entry for one saved record, or nil if it's gone.
local function EntryFor(kind, key)
    local db = ns.db
    if kind == "quest" then
        local q = db.quests[key]
        return q and NewEntry("quest", key, q, q.title or L.UNTITLED_QUEST:format(key), q.zone)
    elseif kind == "book" then
        local b = db.books[key]
        local loc = b and b.locations and b.locations[1]
        return b and NewEntry("book", key, b, b.title or L.UNTITLED_BOOK, loc and loc.zone)
    elseif kind == "gossip" then
        local g = db.gossip[key]
        return g and NewEntry("gossip", key, g, g.npc or L.UNKNOWN_NPC, g.zone)
    end
end

local function AllEntries()
    local db, all = ns.db, {}
    local showUntitled = db.settings.showUntitled
    for id, q in pairs(db.quests) do
        if q.title or showUntitled then all[#all + 1] = EntryFor("quest", id) end
    end
    for key in pairs(db.books) do all[#all + 1] = EntryFor("book", key) end
    for key in pairs(db.gossip) do all[#all + 1] = EntryFor("gossip", key) end
    return all
end

-- Everything matching the current view, filters and search, sorted.
-- Also refreshes the zone and character lists the filters offer.
function UI.BuildEntries()
    if state.view == "people" then return BuildPeople() end
    local all = AllEntries()

    local search = state.search:lower()
    if search == "" then search = nil end
    local zones, chars, zoneList, charList, out = {}, {}, {}, {}, {}
    for _, e in ipairs(all) do
        if e.zone and not zones[e.zone] then
            zones[e.zone] = true
            zoneList[#zoneList + 1] = e.zone
        end
        local c = Characters(e)
        if c then
            for name in pairs(c) do
                if not chars[name] then
                    chars[name] = true
                    charList[#charList + 1] = name
                end
            end
        end
        if Matches(e, search) then out[#out + 1] = e end
    end
    table.sort(zoneList)
    table.sort(charList)
    UI.zoneList, UI.charList = zoneList, charList
    table.sort(out, SORTERS[state.sort] or SORTERS.newest)
    return out
end

local function StillExists(e)
    if e.kind == "name" then return ns.Names.Info(e.key) ~= nil end
    return ns.db[KIND_TABLE[e.kind]][e.key] == e.rec
end

-- Plain text for one entry, used by Copy and Export.
function UI.EntryText(e)
    local r, out = e.rec, {}
    local function add(s) if s then out[#out + 1] = s end end

    add("== " .. e.title .. " ==")
    if e.kind == "name" then
        local m = UI.Mentions()[e.key]
        for _, hit in ipairs(m and m.hits or {}) do
            add("- " .. hit.entry.title .. " (" .. L["KIND_" .. hit.entry.kind] .. ")")
        end
        return StripCodes(table.concat(out, "\n"))
    elseif e.kind == "quest" then
        local meta = {}
        if r.giver then meta[#meta + 1] = L.FROM:format(r.giver) end
        if r.zone then meta[#meta + 1] = r.zone end
        meta[#meta + 1] = L["STATUS_" .. (r.status or "offered")]
        add(table.concat(meta, " - "))
        local sections = {
            { "description", L.SEC_DESCRIPTION }, { "objectives", L.SEC_OBJECTIVES },
            { "progress", L.SEC_PROGRESS }, { "completion", L.SEC_COMPLETION },
        }
        local any = false
        for _, s in ipairs(sections) do
            if r[s[1]] then
                any = true
                add("")
                add(s[2] .. ":")
                add(Display(r[s[1]]))
            end
        end
        if not any then
            add(L.NOT_CAPTURED .. ": " .. ns.db.settings.linkBase .. e.key)
        end
    elseif e.kind == "book" then
        local places = {}
        for _, l in ipairs(r.locations or {}) do
            if l.zone then places[#places + 1] = l.zone end
        end
        if #places > 0 then add(L.FOUND_IN:format(table.concat(places, "; "))) end
        local last = MaxPage(r.pages)
        for p = 1, last do
            add("")
            if last > 1 then add("-- " .. L.PAGE:format(p) .. " --") end
            add(r.pages[p] and Display(r.pages[p]) or L.PAGE_MISSING:format(p))
        end
    else
        if r.zone then add(r.zone) end
        add("")
        add(Display(r.text))
    end
    if r.note and r.note ~= "" then
        add("")
        add(L.NOTE .. " " .. r.note)
    end
    return StripCodes(table.concat(out, "\n"))
end

------------------------------------------------------------------------------
-- Widgets
------------------------------------------------------------------------------

local function Parchment(f)
    local bg = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetPoint("TOPLEFT", 6, -6)
    bg:SetPoint("BOTTOMRIGHT", -6, 6)
    local hasAtlas = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("QuestBG-Parchment")
    if hasAtlas then
        bg:SetAtlas("QuestBG-Parchment")
    else
        bg:SetColorTexture(PARCHMENT[1], PARCHMENT[2], PARCHMENT[3])
    end
    f:SetBackdrop({
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
end

local function Text(parent, template, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
    fs:SetTextColor(unpack(color or INK))
    fs:SetShadowOffset(0, 0)
    fs:SetJustifyH("LEFT")
    return fs
end

local function Button(parent, label, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

local fonts = {}

local function UpdateFonts()
    local size = ns.db.settings.fontSize or 13
    local body = (QuestFont and QuestFont:GetFont()) or STANDARD_TEXT_FONT
    local head = (QuestTitleFont and QuestTitleFont:GetFont()) or body
    fonts.title = fonts.title or CreateFont("LorescribeFontTitle")
    fonts.heading = fonts.heading or CreateFont("LorescribeFontHeading")
    fonts.body = fonts.body or CreateFont("LorescribeFontBody")
    fonts.meta = fonts.meta or CreateFont("LorescribeFontMeta")
    fonts.title:SetFont(head, size + 6, "")
    fonts.heading:SetFont(head, size + 2, "")
    fonts.body:SetFont(body, size, "")
    fonts.meta:SetFont(body, math.max(9, size - 1), "")
end

------------------------------------------------------------------------------
-- Reader
------------------------------------------------------------------------------

local reader, content, linkBox
local blocks, nBlocks, cursorY, blockWidth = {}, 0, 0, 400

local function ResetBlocks()
    for i = 1, nBlocks do blocks[i]:Hide() end
    nBlocks, cursorY = 0, 0
    blockWidth = math.max(100, (reader:GetWidth() or 400) - 12)
end

local function AddBlock(text, font, color, gap)
    nBlocks = nBlocks + 1
    local fs = blocks[nBlocks]
    if not fs then
        fs = content:CreateFontString(nil, "OVERLAY")
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("TOP")
        fs:SetWordWrap(true)
        fs:SetNonSpaceWrap(true)
        fs:SetShadowOffset(0, 0)
        blocks[nBlocks] = fs
    end
    fs:SetFontObject(font)
    fs:SetTextColor(unpack(color))
    fs:SetSpacing(font == fonts.body and 3 or 1)
    fs:SetWidth(blockWidth)
    cursorY = cursorY + (gap or 0)
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -cursorY)
    fs:SetText(text)
    fs:Show()
    cursorY = cursorY + fs:GetStringHeight()
    return fs
end

-- Long text goes in several font strings so no single one gets too large.
local function AddBody(text, gap)
    if #text <= 3000 then
        AddBlock(text, fonts.body, INK, gap or 6)
        return
    end
    local buf, len, g = {}, 0, gap or 6
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if len > 0 and len + #line > 3000 then
            AddBlock(table.concat(buf, "\n"), fonts.body, INK, g)
            buf, len, g = {}, 0, 0
        end
        buf[#buf + 1] = line
        len = len + #line + 1
    end
    if len > 0 then AddBlock(table.concat(buf, "\n"), fonts.body, INK, g) end
end

-- Body text with known names made clickable. Falls back to plain text if matching fails.
local function Linked(text)
    local ok, out = pcall(ns.Names.Link, text)
    return ok and out or text
end

local function AddLink(url)
    linkBox:ClearAllPoints()
    linkBox:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -(cursorY + 10))
    linkBox:SetWidth(math.min(blockWidth - 10, 420))
    linkBox:SetText(url)
    linkBox:SetCursorPosition(0)
    linkBox.url = url
    linkBox:Show()
    cursorY = cursorY + 36
end

local function MetaLine(parts)
    local out = {}
    for _, p in ipairs(parts) do
        if p then out[#out + 1] = p end
    end
    return table.concat(out, "   ")
end

local function RenderQuest(e)
    local r = e.rec
    AddBlock(Display(e.title), fonts.title, ACCENT)
    AddBlock(MetaLine({
        r.giver and L.FROM:format(r.giver),
        r.zone,
        r.level and L.LEVEL:format(r.level),
        L["STATUS_" .. (r.status or "offered")],
        r.firstSeen and r.status ~= "history-only" and L.CAPTURED:format(FormatDate(r.firstSeen)),
    }), fonts.meta, MUTED, 4)

    local sections = {
        { "description", L.SEC_DESCRIPTION }, { "objectives", L.SEC_OBJECTIVES },
        { "progress", L.SEC_PROGRESS }, { "completion", L.SEC_COMPLETION },
    }
    local any = false
    for _, s in ipairs(sections) do
        local text = r[s[1]]
        if text then
            any = true
            AddBlock(s[2], fonts.heading, ACCENT, 16)
            AddBody(Linked(Display(text)))
        end
    end
    if not any then
        AddBlock(L.NOT_CAPTURED, fonts.heading, ACCENT, 16)
        AddBlock(L.NOT_CAPTURED_HELP, fonts.body, INK, 6)
        AddLink(ns.db.settings.linkBase .. e.key)
    elseif r.textSource == "questlog-backfill" and not r.progress and not r.completion then
        AddBlock(L.BACKFILL_NOTE, fonts.meta, MUTED, 16)
    end
end

local function RenderBook(e)
    local r = e.rec
    AddBlock(Display(e.title), fonts.title, ACCENT)
    local seen = 0
    for _ in pairs(r.seenBy or {}) do seen = seen + 1 end
    AddBlock(MetaLine({
        r.material and r.material ~= "Default" and (r.material:sub(1, 1) .. r.material:sub(2):lower()) or nil,
        r.firstSeen and L.CAPTURED:format(FormatDate(r.firstSeen)),
        seen > 1 and L.SEEN_BY:format(seen),
    }), fonts.meta, MUTED, 4)
    local places = {}
    for _, l in ipairs(r.locations or {}) do
        local c = FormatCoords(l.x, l.y)
        if l.zone then places[#places + 1] = c and (l.zone .. " (" .. c .. ")") or l.zone end
    end
    if #places > 0 then
        AddBlock(L.FOUND_IN:format(table.concat(places, "; ")), fonts.meta, MUTED, 2)
    end
    local last = MaxPage(r.pages)
    for p = 1, last do
        if last > 1 then AddBlock(L.PAGE:format(p), fonts.heading, ACCENT, 16) end
        if r.pages[p] then
            AddBody(Linked(Display(r.pages[p])), last > 1 and 6 or 16)
        else
            AddBlock(L.PAGE_MISSING:format(p), fonts.meta, MUTED, 6)
        end
    end
end

local function RenderGossip(e)
    local r = e.rec
    AddBlock(Display(e.title), fonts.title, ACCENT)
    AddBlock(MetaLine({
        r.zone,
        FormatCoords(r.x, r.y),
        r.firstSeen and L.CAPTURED:format(FormatDate(r.firstSeen)),
    }), fonts.meta, MUTED, 4)
    AddBody(Linked(Display(r.text)), 16)
end

------------------------------------------------------------------------------
-- People
------------------------------------------------------------------------------

local mentions  -- [name] = { count, hits = { { entry, text, s, e } } }; rebuilt after changes

-- The texts of an entry as displayed, which is what names are matched against.
local function EntryTexts(e)
    local r, out = e.rec, {}
    local function add(s) if s then out[#out + 1] = Display(s) end end
    if e.kind == "quest" then
        add(r.title)
        add(r.giver)
        for _, f in ipairs(ns.QUEST_TEXT_FIELDS) do add(r[f]) end
    elseif e.kind == "book" then
        add(r.title)
        for p = 1, MaxPage(r.pages) do add(r.pages[p]) end
    else
        add(r.npc)
        add(r.text)
    end
    return out
end

-- Which entries mention each known name, with where the first mention is.
function UI.Mentions()
    if mentions then return mentions end
    local out = {}
    for _, e in ipairs(AllEntries()) do
        for _, text in ipairs(EntryTexts(e)) do
            ns.Names.Scan(text, function(name, s, en)
                local m = out[name]
                if not m then
                    m = { count = 0, hits = {}, seen = {} }
                    out[name] = m
                end
                m.count = m.count + 1
                if not m.seen[e.id] then
                    m.seen[e.id] = true
                    m.hits[#m.hits + 1] = { entry = e, text = text, s = s, e = en }
                end
            end)
        end
    end
    mentions = out
    return out
end

local function SourceLabel(info)
    return L["SOURCE_" .. (info.source or "manual")]
end

NameEntry = function(name)
    local info = ns.Names.Info(name) or { source = "manual" }
    local m = UI.Mentions()[name]
    local count = m and #m.hits or 0
    return {
        id = "name:" .. name, kind = "name", key = name, rec = info,
        title = name, sortTitle = name:lower(), time = count,
        zone = MetaLine({ SourceLabel(info), info.zone }),
        label = L.MENTIONS:format(count),
    }
end

-- Everyone mentioned in saved text, plus names tracked by hand. Newest-first sorting
-- means most mentioned first here.
BuildPeople = function()
    local db, m = ns.db, UI.Mentions()
    local search = state.search:lower()
    if search == "" then search = nil end
    local out, seen = {}, {}
    local function Add(name)
        if seen[name] or db.ignoredNames[name] then return end
        seen[name] = true
        if not search or name:lower():find(search, 1, true) then out[#out + 1] = NameEntry(name) end
    end
    for name in pairs(m) do Add(name) end
    for name, info in pairs(db.names) do
        if info.source == "manual" then Add(name) end
    end
    table.sort(out, SORTERS[state.sort] or SORTERS.newest)
    return out
end

local function EntryLink(e)
    return ns.Names.LINK_COLOR .. "|Hlorescribe:e:" .. e.kind .. ":" .. tostring(e.key) .. "|h"
        .. Display(e.title) .. "|h|r"
end

-- The sentence around a mention, with the name picked out.
local function Snippet(hit)
    local text, s, e = hit.text, hit.s, hit.e
    local function Stop(c) return c == "." or c == "!" or c == "?" or c == "\n" end
    local from, cutBefore = s, false
    for i = s - 1, 1, -1 do
        if Stop(text:sub(i, i)) then break end
        if s - i > 200 then
            cutBefore = true
            break
        end
        from = i
    end
    local to, cutAfter = e, false
    for i = e + 1, #text do
        to = i
        if Stop(text:sub(i, i)) then break end
        if i - e > 200 then
            cutAfter = true
            break
        end
    end
    -- Don't end a cut part-way through a multi-byte character.
    if cutBefore then
        while from < s and text:byte(from) >= 128 and text:byte(from) < 192 do from = from + 1 end
    end
    if cutAfter then
        while to > e and text:byte(to) >= 128 do to = to - 1 end
    end
    local before = text:sub(from, s - 1):gsub("^%s+", "")
    local after = text:sub(e + 1, to):gsub("%s+$", "")
    return (cutBefore and "..." or "") .. before .. "|cff7a1f05" .. text:sub(s, e) .. "|r"
        .. after .. (cutAfter and "..." or "")
end

local function RenderName(e)
    local name, info = e.key, e.rec
    AddBlock(name, fonts.title, ACCENT)
    AddBlock(MetaLine({
        SourceLabel(info),
        info.zone,
        info.firstSeen and L.FIRST_SEEN:format(FormatDate(info.firstSeen)),
    }), fonts.meta, MUTED, 4)

    local m = UI.Mentions()[name]
    if not m then
        AddBlock(L.NO_MENTIONS, fonts.body, INK, 16)
        return
    end
    AddBlock(#m.hits == 1 and L.MENTIONED_IN_ONE or L.MENTIONED_IN:format(#m.hits), fonts.meta, MUTED, 4)

    -- Oldest first, so the mentions read in the order you came across them.
    local hits = {}
    for i, hit in ipairs(m.hits) do hits[i] = hit end
    table.sort(hits, function(a, b)
        if a.entry.time ~= b.entry.time then return a.entry.time < b.entry.time end
        return a.entry.sortTitle < b.entry.sortTitle
    end)
    for i = 1, math.min(#hits, 100) do
        local hit = hits[i]
        AddBlock(EntryLink(hit.entry), fonts.heading, ACCENT, 16)
        AddBlock(MetaLine({ L["KIND_" .. hit.entry.kind], hit.entry.zone }), fonts.meta, MUTED, 2)
        AddBlock(Snippet(hit), fonts.body, INK, 4)
    end
end

-- Opens a person's page in the People view.
function UI.ShowName(name)
    if not ns.Names.Info(name) then return end
    state.view, state.search = "people", ""
    backTo = nil
    current = NameEntry(name)
    if frame.search:GetText() ~= "" then frame.search:SetText("") end
    UI.Refresh()
    UI.RenderReader(true)
end

local function OnLink(link)
    local name = link:match("^lorescribe:n:(.+)$")
    if name then
        UI.ShowName(name)
        return
    end
    local kind, key = link:match("^lorescribe:e:(%a+):(.+)$")
    if not kind then return end
    if kind == "quest" then key = tonumber(key) end
    local e = key and EntryFor(kind, key)
    if not e then return end
    if current and current.kind == "name" then backTo = current.key end
    current = e
    UI.RenderReader(true)
end

local function OnLinkEnter(owner, link)
    local name = link:match("^lorescribe:n:(.+)$")
    if not name then return end
    local m = UI.Mentions()[name]
    local count = m and #m.hits or 0
    GameTooltip:SetOwner(owner, "ANCHOR_CURSOR")
    GameTooltip:SetText(name)
    GameTooltip:AddLine(count == 1 and L.MENTIONED_IN_ONE or L.MENTIONED_IN:format(count), 1, 1, 1)
    GameTooltip:Show()
end

local function UpdateButtons()
    local f, r = frame, current and current.rec
    local isName = current ~= nil and current.kind == "name"
    local enabled = r ~= nil and not isName
    for _, b in ipairs(f.entryButtons) do b:SetEnabled(enabled) end
    f.noteBox:SetEnabled(enabled)
    -- On a person's page the only action is hiding them.
    f.deleteBtn:SetEnabled(r ~= nil)
    f.deleteBtn:SetText(isName and L.HIDE_NAME or L.DELETE)
    if not enabled then
        f.readBtn:SetText(L.MARK_READ)
        f.starBtn:SetText(L.STAR)
        f.queueBtn:SetText(L.QUEUE_ADD)
        return
    end
    f.readBtn:SetText(r.read and L.MARK_UNREAD or L.MARK_READ)
    f.starBtn:SetText(r.starred and L.UNSTAR or L.STAR)
    f.queueBtn:SetText(ns.InQueue(r) and L.QUEUE_REMOVE or L.QUEUE_ADD)
end

function UI.RenderReader(resetScroll)
    if not frame then return end
    if current and not StillExists(current) then current = nil end
    UpdateFonts()
    ResetBlocks()
    linkBox:Hide()
    if current and current.kind ~= "name" and backTo and ns.Names.Info(backTo) then
        AddBlock(ns.Names.LinkFor(backTo, L.BACK_TO:format(backTo)), fonts.meta, MUTED)
        cursorY = cursorY + 8
    end
    if not current then
        AddBlock(L.READER_EMPTY_TITLE, fonts.title, ACCENT)
        AddBlock(L.READER_EMPTY_HELP, fonts.body, INK, 12)
    elseif current.kind == "name" then
        RenderName(current)
    elseif current.kind == "quest" then
        RenderQuest(current)
    elseif current.kind == "book" then
        RenderBook(current)
    else
        RenderGossip(current)
    end
    content:SetSize(blockWidth + 8, cursorY + 20)
    if resetScroll then
        reader:SetVerticalScroll(0)
        frame.noteBox:SetText(current and current.rec.note or "")
        frame.noteBox:SetCursorPosition(0)
    end
    UpdateButtons()
end

------------------------------------------------------------------------------
-- List
------------------------------------------------------------------------------

local function InitRow(row, e)
    if not row.made then
        row.made = true
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(0.55, 0.33, 0.10, 0.28)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 0.85, 0.5, 0.25)
        local line = row:CreateTexture(nil, "ARTWORK")
        line:SetColorTexture(0.40, 0.27, 0.10, 0.30)
        line:SetHeight(1)
        line:SetPoint("BOTTOMLEFT", 4, 0)
        line:SetPoint("BOTTOMRIGHT", -4, 0)
        row.dot = row:CreateTexture(nil, "ARTWORK")
        row.dot:SetSize(7, 7)
        row.dot:SetPoint("LEFT", 6, 0)
        row.dot:SetColorTexture(0.68, 0.16, 0.06)
        row.kind = Text(row, "GameFontHighlightSmall", MUTED)
        row.kind:SetPoint("TOPRIGHT", -8, -6)
        row.kind:SetJustifyH("RIGHT")
        row.title = Text(row, "GameFontHighlight", INK)
        row.title:SetPoint("TOPLEFT", 20, -6)
        row.title:SetPoint("RIGHT", row.kind, "LEFT", -6, 0)
        row.title:SetWordWrap(false)
        row.zone = Text(row, "GameFontHighlightSmall", MUTED)
        row.zone:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -4)
        row.zone:SetPoint("RIGHT", -8, 0)
        row.zone:SetWordWrap(false)
        row:SetScript("OnClick", function(self) UI.Select(self.entry) end)
    end
    row.entry = e
    row.title:SetText(Display(e.title))
    row.zone:SetText(e.zone or "")
    row.kind:SetText(e.label or L["KIND_" .. e.kind])
    row.dot:SetShown(ns.InQueue(e.rec))
    row.sel:SetShown(current ~= nil and current.id == e.id)
end

function UI.Select(e)
    current = e
    backTo = nil
    if e and e.kind ~= "name" and ns.db.settings.markReadOnOpen and not e.rec.read then
        e.rec.read = true
        ns:Changed()
    end
    if not frame.list.ForEachFrame then return UI.RenderReader(true) end
    frame.list:ForEachFrame(function(row)
        if row.entry then
            row.sel:SetShown(current ~= nil and row.entry.id == current.id)
            row.dot:SetShown(ns.InQueue(row.entry.rec))
        end
    end)
    UI.RenderReader(true)
end

function UI.Refresh()
    if not frame or not frame:IsShown() then return end
    local entries = UI.BuildEntries()
    UI.entries = entries
    local retain = ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition
    frame.list:SetDataProvider(CreateDataProvider(entries), retain)

    if #entries == 0 then
        local filtered = state.search ~= "" or state.zone or state.char
        frame.empty:SetText(filtered and L.EMPTY_SEARCH or L["EMPTY_" .. state.view])
        frame.empty:Show()
    else
        frame.empty:Hide()
    end

    for _, tab in ipairs(frame.tabs) do
        if tab.view == state.view then tab:LockHighlight() else tab:UnlockHighlight() end
    end

    local unread = ns:CountUnread()
    frame.titleText:SetText(unread > 0 and L.TITLE_UNREAD:format(unread) or L.TITLE)
    frame.untitled:SetChecked(ns.db.settings.showUntitled)
    -- Only show the controls that do something in this view.
    local quests = state.view == "quest" or state.view == "all"
    frame.untitled:SetShown(quests)
    frame.untitled.label:SetShown(quests)
    frame.zoneDD:SetShown(state.view ~= "people")
    frame.charDD:SetShown(state.view ~= "people")
    for _, dd in ipairs(frame.dropdowns) do dd:GenerateMenu() end
    UI.RenderReader(false)
end

local function RefreshSoon()
    C_Timer.After(0, function() ns.Safe(UI.Refresh) end)
end

ns.OnDataChanged = function()
    mentions = nil
    if frame and frame:IsShown() then UI.Refresh() end
end

------------------------------------------------------------------------------
-- Entry actions
------------------------------------------------------------------------------

local function Touch()
    ns:Changed()
    UpdateButtons()
end

local function ToggleRead()
    local r = current and current.rec
    if not r then return end
    if r.read then
        r.read, r.readLater = false, true
    else
        r.read = true
    end
    Touch()
end

local function ToggleStar()
    local r = current and current.rec
    if not r then return end
    r.starred = not r.starred
    Touch()
end

local function ToggleQueue()
    local r = current and current.rec
    if not r then return end
    if ns.InQueue(r) then
        r.readLater = false
    else
        r.readLater, r.read = true, false
    end
    Touch()
end

local function DeleteEntry(e)
    if not e or not StillExists(e) then return end
    ns.db[KIND_TABLE[e.kind]][e.key] = nil
    if current == e then current = nil end
    ns:Changed()
end

StaticPopupDialogs["LORESCRIBE_HIDE_NAME"] = {
    text = L.HIDE_NAME_CONFIRM,
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, name)
        ns.Safe(ns.Names.Hide, name)
        if current and current.kind == "name" and current.key == name then current = nil end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["LORESCRIBE_DELETE"] = {
    text = L.DELETE_CONFIRM,
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, data) ns.Safe(DeleteEntry, data) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

------------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------------

local function SavePosition()
    local ui = ns.db.ui
    local point, _, relPoint, x, y = frame:GetPoint(1)
    ui.point = { point, relPoint, x, y }
    ui.width, ui.height = frame:GetSize()
end

local function RestorePosition()
    local ui = ns.db.ui
    frame:ClearAllPoints()
    if ui.point then
        frame:SetPoint(ui.point[1], UIParent, ui.point[2], ui.point[3], ui.point[4])
    else
        frame:SetPoint("CENTER")
    end
    frame:SetSize(ui.width or 960, ui.height or 600)
end

local function MakeDropdown(parent, width, generator)
    local dd = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    dd:SetWidth(width)
    dd:SetupMenu(generator)
    return dd
end

local function SetFontSize(delta)
    local s = ns.db.settings
    s.fontSize = math.max(9, math.min(24, (s.fontSize or 13) + delta))
    UI.RenderReader(false)
end

local function Build()
    local f = CreateFrame("Frame", "LorescribeFrame", UIParent, "BackdropTemplate")
    frame = f
    f:Hide()
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:SetResizable(true)
    f:SetResizeBounds(820, 440)
    f:SetDontSavePosition(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    Parchment(f)
    tinsert(UISpecialFrames, "LorescribeFrame")  -- Escape closes it

    f.titleText = Text(f, "GameFontNormalLarge", ACCENT)
    f.titleText:SetPoint("TOP", 0, -16)
    f.titleText:SetJustifyH("CENTER")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    -- Tabs
    f.tabs = {}
    local prev
    for _, v in ipairs(VIEWS) do
        local tab = Button(f, v.label, 80, function()
            state.view = v.key
            UI.Refresh()
        end)
        tab.view = v.key
        if prev then tab:SetPoint("LEFT", prev, "RIGHT", 4, 0) else tab:SetPoint("TOPLEFT", 18, -42) end
        f.tabs[#f.tabs + 1] = tab
        prev = tab
    end

    local larger = Button(f, L.LARGER, 34, function() SetFontSize(1) end)
    larger:SetPoint("TOPRIGHT", -18, -42)
    local smaller = Button(f, L.SMALLER, 34, function() SetFontSize(-1) end)
    smaller:SetPoint("RIGHT", larger, "LEFT", -4, 0)
    local export = Button(f, L.EXPORT, 72, function() UI.ExportCurrent() end)
    export:SetPoint("RIGHT", smaller, "LEFT", -10, 0)

    -- Search and filters
    local search = CreateFrame("EditBox", nil, f, "SearchBoxTemplate")
    search:SetSize(200, 20)
    search:SetPoint("TOPLEFT", 24, -74)
    search:HookScript("OnTextChanged", function(self)
        state.search = self:GetText() or ""
        if UI.searchTimer then UI.searchTimer:Cancel() end
        UI.searchTimer = C_Timer.NewTimer(0.2, function() ns.Safe(UI.Refresh) end)
    end)
    f.search = search

    f.dropdowns = {}
    local zoneDD = MakeDropdown(f, 150, function(_, root)
        root:SetScrollMode(400)
        root:CreateRadio(L.ALL_ZONES, function() return state.zone == nil end,
            function() state.zone = nil; RefreshSoon() end)
        for _, zone in ipairs(UI.zoneList or {}) do
            root:CreateRadio(zone, function(z) return state.zone == z end,
                function(z) state.zone = z; RefreshSoon() end, zone)
        end
    end)
    zoneDD:SetPoint("LEFT", search, "RIGHT", 10, 0)

    local charDD = MakeDropdown(f, 150, function(_, root)
        root:SetScrollMode(400)
        root:CreateRadio(L.ALL_CHARACTERS, function() return state.char == nil end,
            function() state.char = nil; RefreshSoon() end)
        for _, name in ipairs(UI.charList or {}) do
            root:CreateRadio(name, function(c) return state.char == c end,
                function(c) state.char = c; RefreshSoon() end, name)
        end
    end)
    charDD:SetPoint("LEFT", zoneDD, "RIGHT", 8, 0)

    local sortDD = MakeDropdown(f, 130, function(_, root)
        for _, s in ipairs(SORTS) do
            root:CreateRadio(s.label, function(k) return state.sort == k end,
                function(k) state.sort = k; RefreshSoon() end, s.key)
        end
    end)
    sortDD:SetPoint("LEFT", charDD, "RIGHT", 8, 0)
    f.dropdowns = { zoneDD, charDD, sortDD }

    local untitled = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    untitled:SetSize(24, 24)
    untitled:SetPoint("LEFT", sortDD, "RIGHT", 8, 0)
    untitled:SetScript("OnClick", function(self)
        ns.db.settings.showUntitled = self:GetChecked() and true or false
        UI.Refresh()
    end)
    untitled:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L.SHOW_UNTITLED_TIP, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    untitled:SetScript("OnLeave", GameTooltip_Hide)
    local untitledLabel = Text(f, "GameFontHighlightSmall", INK)
    untitledLabel:SetPoint("LEFT", untitled, "RIGHT", 0, 0)
    untitledLabel:SetText(L.SHOW_UNTITLED)
    untitled.label = untitledLabel
    f.untitled = untitled
    f.zoneDD, f.charDD = zoneDD, charDD

    -- List
    local list = CreateFrame("Frame", nil, f, "WowScrollBoxList")
    list:SetPoint("TOPLEFT", 16, -104)
    list:SetPoint("BOTTOMLEFT", 16, 16)
    list:SetWidth(LIST_W)
    local bar = CreateFrame("EventFrame", nil, f, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", list, "TOPRIGHT", 4, 0)
    bar:SetPoint("BOTTOMLEFT", list, "BOTTOMRIGHT", 4, 0)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_H)
    view:SetElementInitializer("Button", InitRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(list, bar, view)
    f.list = list

    local listBg = f:CreateTexture(nil, "BACKGROUND", nil, -7)
    listBg:SetPoint("TOPLEFT", list, -2, 2)
    listBg:SetPoint("BOTTOMRIGHT", list, 2, -2)
    listBg:SetColorTexture(0.35, 0.22, 0.08, 0.12)

    f.empty = Text(f, "GameFontHighlight", MUTED)
    f.empty:SetPoint("TOPLEFT", list, "TOPLEFT", 12, -14)
    f.empty:SetPoint("RIGHT", list, "RIGHT", -12, 0)
    f.empty:SetJustifyV("TOP")

    -- Reader
    reader = CreateFrame("ScrollFrame", nil, f, "ScrollFrameTemplate")
    reader:SetPoint("TOPLEFT", list, "TOPRIGHT", 28, 0)
    reader:SetPoint("BOTTOMRIGHT", -36, 76)
    content = CreateFrame("Frame", nil, reader)
    content:SetSize(400, 10)
    reader:SetScrollChild(content)
    -- Names and entry titles in the reader are links.
    content:SetHyperlinksEnabled(true)
    content:SetScript("OnHyperlinkClick", function(_, link) ns.Safe(OnLink, link) end)
    content:SetScript("OnHyperlinkEnter", function(self, link) ns.Safe(OnLinkEnter, self, link) end)
    content:SetScript("OnHyperlinkLeave", GameTooltip_Hide)
    reader:SetScript("OnSizeChanged", function()
        if f:IsShown() then ns.Safe(UI.RenderReader, false) end
    end)

    linkBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    linkBox:SetHeight(22)
    linkBox:SetAutoFocus(false)
    linkBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    linkBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    linkBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    -- Read-only: put the link back if it's edited.
    linkBox:SetScript("OnTextChanged", function(self, userInput)
        if userInput and self.url then
            self:SetText(self.url)
            self:HighlightText()
        end
    end)
    linkBox:Hide()

    -- Note
    local noteLabel = Text(f, "GameFontHighlight", INK)
    noteLabel:SetPoint("TOPLEFT", reader, "BOTTOMLEFT", 0, -14)
    noteLabel:SetText(L.NOTE)
    local note = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    note:SetHeight(22)
    note:SetAutoFocus(false)
    note:SetMaxLetters(300)
    note:SetPoint("LEFT", noteLabel, "RIGHT", 12, 0)
    note:SetPoint("RIGHT", f, "RIGHT", -24, 0)
    note:SetScript("OnTextChanged", function(self, userInput)
        if userInput and current then current.rec.note = self:GetText() end
    end)
    note:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    note:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    f.noteBox = note

    -- Entry buttons
    f.readBtn = Button(f, L.MARK_READ, 96, ToggleRead)
    f.readBtn:SetPoint("BOTTOMLEFT", reader, "BOTTOMLEFT", -2, -62)
    f.starBtn = Button(f, L.STAR, 64, ToggleStar)
    f.starBtn:SetPoint("LEFT", f.readBtn, "RIGHT", 4, 0)
    f.queueBtn = Button(f, L.QUEUE_ADD, 124, ToggleQueue)
    f.queueBtn:SetPoint("LEFT", f.starBtn, "RIGHT", 4, 0)
    f.copyBtn = Button(f, L.COPY, 60, function()
        if current then UI.ShowExport({ UI.EntryText(current) }) end
    end)
    f.copyBtn:SetPoint("LEFT", f.queueBtn, "RIGHT", 4, 0)
    f.deleteBtn = Button(f, L.DELETE, 64, function()
        if not current then return end
        if current.kind == "name" then
            StaticPopup_Show("LORESCRIBE_HIDE_NAME", current.key, current.key, current.key)
        else
            StaticPopup_Show("LORESCRIBE_DELETE", current.title, nil, current)
        end
    end)
    f.entryButtons = { f.readBtn, f.starBtn, f.queueBtn, f.copyBtn, f.deleteBtn }

    -- Resize grip
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -6, 6)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        SavePosition()
    end)
    f.deleteBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -26, 16)

    f:SetScript("OnShow", function() ns.Safe(UI.Refresh) end)

    UpdateFonts()
    RestorePosition()
end

function UI.GetFrame()
    if not frame then Build() end
    return frame
end

function UI.Toggle()
    local f = UI.GetFrame()
    if f:IsShown() then
        f:Hide()
    else
        state.view = "readlater"
        f:Show()
    end
end

function UI.Open()
    local f = UI.GetFrame()
    if f:IsShown() then UI.Refresh() else f:Show() end
end

function UI.OpenSearch(text)
    local f = UI.GetFrame()
    state.view = "all"
    state.search = text or ""
    f.search:SetText(state.search)
    UI.Open()
end

function UI.ResetWindow()
    ns.db.ui = {}
    if frame then RestorePosition() end
end

------------------------------------------------------------------------------
-- Export
------------------------------------------------------------------------------

local exportFrame
local chunks, chunkIndex = {}, 1

local function ShowChunk()
    local ex = exportFrame
    ex.edit:SetText(chunks[chunkIndex] or "")
    ex.edit:SetCursorPosition(0)
    ex.scroll:SetVerticalScroll(0)
    ex.part:SetText(#chunks > 1 and L.EXPORT_PART:format(chunkIndex, #chunks) or "")
    ex.prev:SetShown(#chunks > 1)
    ex.next:SetShown(#chunks > 1)
    ex.prev:SetEnabled(chunkIndex > 1)
    ex.next:SetEnabled(chunkIndex < #chunks)
    ex.edit:SetFocus()
    ex.edit:HighlightText()
end

local function BuildExport()
    local ex = CreateFrame("Frame", "LorescribeExportFrame", UIParent, "BackdropTemplate")
    exportFrame = ex
    ex:Hide()
    ex:SetSize(680, 500)
    ex:SetPoint("CENTER")
    ex:SetFrameStrata("DIALOG")
    ex:SetToplevel(true)
    ex:SetClampedToScreen(true)
    ex:SetMovable(true)
    ex:EnableMouse(true)
    ex:RegisterForDrag("LeftButton")
    ex:SetScript("OnDragStart", ex.StartMoving)
    ex:SetScript("OnDragStop", ex.StopMovingOrSizing)
    Parchment(ex)
    tinsert(UISpecialFrames, "LorescribeExportFrame")

    local title = Text(ex, "GameFontNormalLarge", ACCENT)
    title:SetPoint("TOP", 0, -16)
    title:SetText(L.EXPORT_TITLE)

    local close = CreateFrame("Button", nil, ex, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    local hint = Text(ex, "GameFontHighlightSmall", MUTED)
    hint:SetPoint("TOPLEFT", 20, -40)
    hint:SetText(L.EXPORT_HINT)

    local scroll = CreateFrame("ScrollFrame", nil, ex, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 20, -60)
    scroll:SetPoint("BOTTOMRIGHT", -38, 48)
    ex.scroll = scroll

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(0)
    edit:SetFontObject(ChatFontNormal)
    edit:SetTextColor(unpack(INK))
    edit:SetWidth(600)
    edit:SetScript("OnEscapePressed", function() ex:Hide() end)
    scroll:SetScrollChild(edit)
    scroll:SetScript("OnSizeChanged", function(_, w) edit:SetWidth(w) end)
    ex.edit = edit

    ex.prev = Button(ex, L.EXPORT_PREV, 70, function()
        chunkIndex = math.max(1, chunkIndex - 1)
        ShowChunk()
    end)
    ex.prev:SetPoint("BOTTOMLEFT", 20, 16)
    ex.next = Button(ex, L.EXPORT_NEXT, 70, function()
        chunkIndex = math.min(#chunks, chunkIndex + 1)
        ShowChunk()
    end)
    ex.next:SetPoint("LEFT", ex.prev, "RIGHT", 4, 0)
    ex.part = Text(ex, "GameFontHighlight", INK)
    ex.part:SetPoint("LEFT", ex.next, "RIGHT", 12, 0)

    local select = Button(ex, L.EXPORT_SELECT, 90, function()
        edit:SetFocus()
        edit:HighlightText()
    end)
    select:SetPoint("BOTTOMRIGHT", -20, 16)
end

-- Shows the texts one after another, split into parts small enough to copy.
function UI.ShowExport(texts)
    if not exportFrame then BuildExport() end
    chunks, chunkIndex = {}, 1
    local buf, len = {}, 0
    for _, t in ipairs(texts) do
        if len > 0 and len + #t > EXPORT_CHUNK then
            chunks[#chunks + 1] = table.concat(buf, "\n\n\n")
            buf, len = {}, 0
        end
        buf[#buf + 1] = t
        len = len + #t + 3
    end
    if len > 0 then chunks[#chunks + 1] = table.concat(buf, "\n\n\n") end
    if #chunks == 0 then chunks[1] = L.EXPORT_EMPTY end
    exportFrame:Show()
    ShowChunk()
end

function UI.ExportCurrent()
    local texts = {}
    for _, e in ipairs(UI.BuildEntries()) do
        texts[#texts + 1] = UI.EntryText(e)
    end
    UI.ShowExport(texts)
end

------------------------------------------------------------------------------
-- Minimap button
------------------------------------------------------------------------------

local minimapButton

local function PlaceMinimapButton()
    local angle = math.rad(ns.db.settings.minimapAngle or 140)
    local radius = (Minimap:GetWidth() / 2) + 10
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function DragMinimapButton()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    ns.db.settings.minimapAngle = math.deg(math.atan2(py / scale - my, px / scale - mx))
    PlaceMinimapButton()
end

local function BuildMinimapButton()
    local b = CreateFrame("Button", "LorescribeMinimapButton", Minimap)
    minimapButton = b
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("AnyUp")
    b:RegisterForDrag("LeftButton")
    -- Same art and layout as most addons' minimap buttons (LibDBIcon), by file ID.
    b:SetHighlightTexture(136477)  -- Interface\Minimap\UI-Minimap-ZoomButton-Highlight

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetTexture(136467)  -- Interface\Minimap\UI-Minimap-Background
    bg:SetPoint("TOPLEFT", 7, -5)
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    icon:SetPoint("TOPLEFT", 7, -6)
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture(136430)  -- Interface\Minimap\MiniMap-TrackingBorder
    border:SetPoint("TOPLEFT")

    b:SetScript("OnClick", function() ns.Safe(UI.Toggle) end)
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function() ns.Safe(DragMinimapButton) end)
        GameTooltip:Hide()
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(L.TITLE)
        GameTooltip:AddLine(L.MINIMAP_TIP, 1, 1, 1)
        local unread = ns:CountUnread()
        if unread > 0 then GameTooltip:AddLine(L.TITLE_UNREAD:format(unread), 0.8, 0.8, 0.8) end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
end

function UI.UpdateMinimapButton()
    if ns.db.settings.minimapHide then
        if minimapButton then minimapButton:Hide() end
        return
    end
    if not minimapButton then BuildMinimapButton() end
    PlaceMinimapButton()
    minimapButton:Show()
end
