-- Lorescribe: saves quest text, books and NPC dialogue as you play.
-- Core: saved data, capture, backfill and slash commands. The window lives in UI.lua.
local ADDON, ns = ...

ns.VERSION = "0.1.3"

local DB_VERSION = 2
local MAX_TITLE_TRIES = 3     -- sessions we ask the server for a completed quest's title
local TITLES_PER_SECOND = 20  -- server title requests, spread over frames

-- All user-facing text lives here.
local L = {
    PREFIX = "|cffc8a165Lorescribe:|r ",
    SUMMARY = "saved full text for %d quests in your log, found %d completed quests (titles only), %d books.",
    SCAN_DEFERRED = "the quest log scan will run when you leave combat or close the quest log.",
    STATS = "%d quests (%d with text, %d titles only), %d books, %d dialogue. %d to read.",
    GOSSIP_ON = "NPC dialogue capture is on.",
    GOSSIP_OFF = "NPC dialogue capture is off.",
    PAGINATE_ON = "Books will be paged through automatically so every page is saved.",
    PAGINATE_OFF = "Books will only save the pages you turn to.",
    MARKREAD_ON = "Opening an entry now marks it read.",
    MARKREAD_OFF = "Opening an entry no longer marks it read.",
    MINIMAP_ON = "Minimap button shown.",
    MINIMAP_OFF = "Minimap button hidden. /ls minimap on brings it back.",
    MINIMAP_TIP = "Left-click to open your library. Drag to move.",
    MINLENGTH = "Dialogue shorter than %d characters is skipped.",
    LINKBASE = "Quest links now start with %s",
    WINDOW_RESET = "window position and size reset.",
    NO_ERRORS = "no errors recorded this session.",
    ERRORS = "%d error(s) this session:",
    HELP = {
        "/ls - open or close the library",
        "/ls scan - read your quest log and completed quest history again",
        "/ls search <text> - open the library with a search",
        "/ls export - copy the current list as plain text",
        "/ls stats - counts and unread total",
        "/ls gossip on|off - NPC dialogue capture",
        "/ls paginate on|off - page through books automatically",
        "/ls markread on|off - mark entries read when opened",
        "/ls minimap on|off|reset - minimap button",
        "/ls minlength <n> - shortest dialogue worth saving",
        "/ls link <url> - base URL for quest links",
        "/ls reset window - put the window back in the middle",
    },

    -- Window
    TITLE = "Lorescribe",
    TITLE_UNREAD = "Lorescribe (%d to read)",
    VIEW_READLATER = "Read later",
    VIEW_QUESTS = "Quests",
    VIEW_BOOKS = "Books",
    VIEW_DIALOGUE = "Dialogue",
    VIEW_STARRED = "Starred",
    VIEW_ALL = "All",
    KIND_quest = "Quest",
    KIND_book = "Book",
    KIND_gossip = "Dialogue",
    ALL_ZONES = "All zones",
    ALL_CHARACTERS = "All characters",
    SORT_NEWEST = "Newest first",
    SORT_ZONE = "By zone",
    SORT_TITLE = "By title",
    SHOW_UNTITLED = "Untitled",
    SHOW_UNTITLED_TIP = "Show completed quests whose titles the server never sent. Most are hidden tracking flags.",
    EXPORT = "Export",
    SMALLER = "A-",
    LARGER = "A+",
    MARK_READ = "Mark read",
    MARK_UNREAD = "Mark unread",
    STAR = "Star",
    UNSTAR = "Unstar",
    QUEUE_ADD = "Read later",
    QUEUE_REMOVE = "Remove from queue",
    COPY = "Copy",
    DELETE = "Delete",
    DELETE_CONFIRM = "Delete \"%s\" from Lorescribe?",
    NOTE = "Note:",
    UNTITLED_QUEST = "Quest #%d",
    UNTITLED_BOOK = "Untitled",
    UNKNOWN_NPC = "Unknown",

    EMPTY_readlater = "Nothing waiting. New quest text, books and dialogue land here as you play.",
    EMPTY_quest = "No quests yet. Use /ls scan to read your quest log.",
    EMPTY_book = "No books yet.\n\nBooks you read before installing Lorescribe can't be recovered: the game keeps no record of them. Open them again and they'll be saved.",
    EMPTY_gossip = "No dialogue yet. Talk to an NPC with something to say.",
    EMPTY_starred = "Nothing starred.",
    EMPTY_all = "Nothing saved yet.",
    EMPTY_SEARCH = "Nothing matches.",

    READER_EMPTY_TITLE = "Pick an entry",
    READER_EMPTY_HELP = "Lorescribe saves quest text, books, letters, plaques and NPC dialogue as you see them, so you can skip reading in the moment and come back here.\n\nWhat it can recover from before it was installed:\n\n- Quests in your log: full description and objectives.\n- Completed quests: titles only. The game doesn't keep their text, so these show a link to look them up instead.\n- Books: nothing. Read them again and they'll be saved.\n\nProgress and completion text is saved when you hand a quest in.",

    FROM = "From %s",
    LEVEL = "Level %d",
    CAPTURED = "Saved %s",
    SEEN_BY = "Seen by %d characters",
    FOUND_IN = "Found in %s",
    STATUS_offered = "Offered",
    STATUS_accepted = "In progress",
    STATUS_completed = "Completed",
    STATUS_abandoned = "Abandoned",
    ["STATUS_history-only"] = "Completed",
    SEC_DESCRIPTION = "Description",
    SEC_OBJECTIVES = "Objectives",
    SEC_PROGRESS = "Progress",
    SEC_COMPLETION = "Completion",
    PAGE = "Page %d",
    PAGE_MISSING = "(page %d not saved)",
    NOT_CAPTURED = "Text not captured",
    NOT_CAPTURED_HELP = "You completed this quest before Lorescribe was installed, and the game doesn't keep the text of finished quests. Copy the link below to read it online.",
    BACKFILL_NOTE = "Saved from your quest log. Progress and completion text will be added when you hand it in.",

    EXPORT_TITLE = "Export",
    EXPORT_PART = "Part %d of %d",
    EXPORT_HINT = "The text is selected. Press Ctrl+C to copy.",
    EXPORT_PREV = "Prev",
    EXPORT_NEXT = "Next",
    EXPORT_SELECT = "Select all",
    EXPORT_EMPTY = "Nothing to export.",

    COMPARTMENT_TIP = "Click to open your library.",
    BINDING_TOGGLE = "Open or close Lorescribe",
}
ns.L = L

BINDING_HEADER_LORESCRIBE = L.TITLE
BINDING_NAME_LORESCRIBE_TOGGLE = L.BINDING_TOGGLE

local DEFAULTS = {
    version = DB_VERSION,
    settings = {
        autoPaginate = true,
        captureGossip = true,
        gossipMinLength = 40,
        linkBase = "https://www.wowhead.com/quest=",
        fontSize = 13,
        markReadOnOpen = false,
        showUntitled = false,
        minimapHide = false,
        minimapAngle = 140,
    },
    quests = {},
    books = {},
    gossip = {},
    ui = {},
}

-- Upgrades keyed by the version they produce: MIGRATIONS[2] turns a version 1 DB into 2.
local MIGRATIONS = {
    -- 0.1.1 put the minimap button where other addons' buttons usually sit.
    [2] = function(db)
        if db.settings.minimapAngle == 215 then db.settings.minimapAngle = 140 end
    end,
}

------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(L.PREFIX .. msg)
end
ns.Print = Print

-- Errors are kept here rather than raised: a capture failure must never interrupt play.
ns.errors = {}
local function Safe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok and #ns.errors < 50 then
        ns.errors[#ns.errors + 1] = tostring(err)
    end
    return ok
end
ns.Safe = Safe

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) and true or false
end

-- A usable piece of text, or nil. WoW Forever can return "secret" values, which error
-- when concatenated, compared or used as table keys, so they count as nothing.
local function Clean(s)
    if s == nil or IsSecret(s) or type(s) ~= "string" then return nil end
    if not s:find("%S") then return nil end
    return s
end
ns.Clean = Clean

-- djb2 over the bytes, plus the length to make collisions even less likely.
local function Hash(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967296
    end
    return string.format("%08x%x", h, #s)
end

-- The name a character is stored under. WoW Forever has no realms and two-part
-- names ("Slim Steaky"), which UnitName returns as two values; elsewhere it's Name-Realm.
local function CharKey()
    if ns.charKey then return ns.charKey end
    local first, second = UnitName("player")
    first, second = Clean(first), Clean(second)
    if not first then return "Unknown" end
    if second then
        ns.charKey = first .. " " .. second
    else
        local realm = GetNormalizedRealmName()
        if not realm then return first end -- not loaded yet; try again later
        ns.charKey = first .. "-" .. realm
    end
    return ns.charKey
end
ns.CharKey = CharKey

local function NpcName()
    return Clean((UnitName("npc")))
end

local function GetLocation()
    local mapID = C_Map.GetBestMapForUnit("player")
    if IsSecret(mapID) then mapID = nil end
    local zone, x, y
    if mapID then
        local info = C_Map.GetMapInfo(mapID)
        zone = info and Clean(info.name)
        local pos = C_Map.GetPlayerMapPosition(mapID, "player")
        if pos then
            x, y = pos:GetXY()
            if IsSecret(x) or IsSecret(y) or not x or not y or (x == 0 and y == 0) then x, y = nil, nil end
        end
    end
    zone = zone or Clean(GetRealZoneText())
    return zone, mapID, x, y
end

local function CopyDefaults(dst, src)
    for k, v in pairs(src) do
        if dst[k] == nil then
            if type(v) == "table" then
                dst[k] = {}
                CopyDefaults(dst[k], v)
            else
                dst[k] = v
            end
        end
    end
end

local function Migrate(db)
    local from = db.version or 1
    for target = from + 1, DB_VERSION do
        if MIGRATIONS[target] then MIGRATIONS[target](db) end
        db.version = target
    end
end

-- The UI listens for this. Many changes in a burst cause one refresh.
function ns:Changed()
    if self.changePending then return end
    self.changePending = true
    C_Timer.After(0.3, function()
        self.changePending = false
        if self.OnDataChanged then Safe(self.OnDataChanged) end
    end)
end

local function InQueue(rec)
    return rec.readLater and not rec.read
end
ns.InQueue = InQueue

function ns:CountUnread()
    local n = 0
    for _, t in ipairs({ self.db.quests, self.db.books, self.db.gossip }) do
        for _, rec in pairs(t) do
            if InQueue(rec) then n = n + 1 end
        end
    end
    return n
end

------------------------------------------------------------------------------
-- Quests
------------------------------------------------------------------------------

local TEXT_FIELDS = { "description", "objectives", "progress", "completion" }
ns.QUEST_TEXT_FIELDS = TEXT_FIELDS

-- Later states win; a completed quest is never demoted.
local STATUS_RANK = { ["history-only"] = 0, offered = 1, accepted = 2, abandoned = 2, completed = 3 }

local function SetStatus(q, status)
    if (STATUS_RANK[status] or 0) >= (STATUS_RANK[q.status] or 0) then
        q.status = status
    end
end

local function GetQuestRecord(questID)
    local q = ns.db.quests[questID]
    if not q then
        q = {
            status = "offered", textSource = "none", characters = {},
            firstSeen = time(), readLater = false, read = false, starred = false, note = "",
        }
        ns.db.quests[questID] = q
    end
    q.characters = q.characters or {}
    q.characters[CharKey()] = true
    return q
end

local function SetMeta(q, field, value)
    value = Clean(value)
    if value then q[field] = value end
end

-- Merges quest text into a record without ever replacing text with nothing.
-- A section seen for the first time puts the quest back in the read-later queue.
local function ApplyText(q, fields, source)
    local added, changed = false, false
    for _, f in ipairs(TEXT_FIELDS) do
        local v = Clean(fields[f])
        if v and q[f] ~= v then
            if not q[f] then added = true end
            q[f] = v
            changed = true
        end
    end
    if changed then
        if source == "live" or q.textSource ~= "live" then q.textSource = source end
        q.lastUpdated = time()
    end
    if added then
        q.readLater, q.read = true, false
        q.firstSeen = q.firstSeen or time()
    end
    return changed
end

local function StampLocation(q)
    if q.zone then return end
    local zone, mapID, x, y = GetLocation()
    q.zone, q.mapID = zone, mapID
    if x then q.coords = { x = x, y = y } end
end

local function QuestLevel(questID)
    local index = C_QuestLog.GetLogIndexForQuestID(questID)
    local info = index and C_QuestLog.GetInfo(index)
    local level = info and info.level
    if level and not IsSecret(level) and level > 0 then return level end
end

local H = {}  -- event handlers

function H.QUEST_DETAIL(questStartItemID)
    local id = GetQuestID()
    if not id or id == 0 then return end
    local q = GetQuestRecord(id)
    SetMeta(q, "title", GetTitleText())
    if questStartItemID and questStartItemID ~= 0 and C_Item and C_Item.GetItemNameByID then
        SetMeta(q, "giver", C_Item.GetItemNameByID(questStartItemID))
    else
        SetMeta(q, "giver", NpcName())
    end
    ApplyText(q, { description = GetQuestText(), objectives = GetObjectiveText() }, "live")
    StampLocation(q)
    q.lastUpdated = time()
    ns:Changed()
end

function H.QUEST_ACCEPTED(a, b)
    local id = b or a  -- older clients sent (questLogIndex, questID)
    if type(id) ~= "number" or IsSecret(id) or id == 0 then return end
    local q = GetQuestRecord(id)
    SetMeta(q, "title", C_QuestLog.GetTitleForQuestID(id))
    SetStatus(q, "accepted")
    q.acceptedAt = time()
    q.level = q.level or QuestLevel(id)
    StampLocation(q)
    q.lastUpdated = time()
    ns:ScheduleLogScan(1)  -- picks up text for quests that skip the detail screen
    ns:Changed()
end

function H.QUEST_PROGRESS()
    local id = GetQuestID()
    if not id or id == 0 then return end
    local q = GetQuestRecord(id)
    SetMeta(q, "title", GetTitleText())
    if not q.giver then SetMeta(q, "giver", NpcName()) end
    ApplyText(q, { progress = GetProgressText() }, "live")
    StampLocation(q)
    ns:Changed()
end

function H.QUEST_COMPLETE()
    local id = GetQuestID()
    if not id or id == 0 then return end
    local q = GetQuestRecord(id)
    SetMeta(q, "title", GetTitleText())
    if not q.giver then SetMeta(q, "giver", NpcName()) end
    ApplyText(q, { completion = GetRewardText() }, "live")
    StampLocation(q)
    ns:Changed()
end

function H.QUEST_TURNED_IN(questID)
    if type(questID) ~= "number" or IsSecret(questID) then return end
    local q = GetQuestRecord(questID)
    SetStatus(q, "completed")
    q.completedAt = time()
    q.lastUpdated = time()
    ns:Changed()
end

-- Also fires on turn-in, sometimes first, so wait and check before calling it abandoned.
function H.QUEST_REMOVED(questID)
    if type(questID) ~= "number" or IsSecret(questID) then return end
    C_Timer.After(2, function()
        Safe(function()
            local q = ns.db.quests[questID]
            if not q or q.status ~= "accepted" then return end
            if C_QuestLog.IsQuestFlaggedCompleted(questID) then
                q.status = "completed"
            elseif not C_QuestLog.GetLogIndexForQuestID(questID) then
                q.status = "abandoned"
            end
            q.lastUpdated = time()
            ns:Changed()
        end)
    end)
end

------------------------------------------------------------------------------
-- Backfill: quest log (full text) and completed quests (titles only)
------------------------------------------------------------------------------

-- Reads description and objectives for every quest in the log that we don't have yet.
-- Returns how many log quests have their text saved, or nil if it had to wait.
function ns:ScanQuestLog()
    if InCombatLockdown() then
        self.scanAfterCombat = true
        return nil
    end
    -- Selecting quests would change what an open quest log shows.
    if QuestMapFrame and QuestMapFrame:IsVisible() then
        self:ScheduleLogScan(10)
        return nil
    end

    local n = C_QuestLog.GetNumQuestLogEntries() or 0
    local previous = C_QuestLog.GetSelectedQuest()
    local selected = false
    local header, count, changed = nil, 0, false

    for i = 1, n do
        local info = C_QuestLog.GetInfo(i)
        if info then
            if info.isHeader then
                header = Clean(info.title)
            elseif info.questID and info.questID > 0 and not info.isHidden then
                local id = info.questID
                local q = GetQuestRecord(id)
                if not q.title then SetMeta(q, "title", info.title); changed = true end
                if not q.level and info.level and info.level > 0 then q.level = info.level end
                if not q.zone and header then q.zone = header end
                if q.status ~= "accepted" then SetStatus(q, "accepted") end
                if not q.description or not q.objectives then
                    C_QuestLog.SetSelectedQuest(id)
                    selected = true
                    local desc, obj = GetQuestLogQuestText(i)
                    if ApplyText(q, { description = desc, objectives = obj }, "questlog-backfill") then
                        changed = true
                    end
                end
                if q.description then count = count + 1 end
            end
        end
    end

    if selected and previous and previous ~= 0 then
        C_QuestLog.SetSelectedQuest(previous)
    end
    self.lastLogScan = GetTime()
    if changed then self:Changed() end
    return count
end

function ns:ScheduleLogScan(delay)
    if self.logScanPending then return end
    self.logScanPending = true
    C_Timer.After(delay or 2, function()
        self.logScanPending = false
        Safe(self.ScanQuestLog, self)
    end)
end

local titleQueue, titleQueued, titleHead = {}, {}, 1

local function QueueTitle(id)
    if titleQueued[id] then return end
    titleQueued[id] = true
    titleQueue[#titleQueue + 1] = id
end

-- Works through quests with no title: cached titles are free, uncached ones cost one
-- server request each, at most TITLES_PER_SECOND.
local function TitleTick()
    local quests, resolved = ns.db.quests, false
    local budget = 100
    while titleHead <= #titleQueue and budget > 0 do
        local id = titleQueue[titleHead]
        titleHead = titleHead + 1
        budget = budget - 1
        local q = quests[id]
        if q and not q.title then
            local title = Clean(C_QuestLog.GetTitleForQuestID(id))
            if title then
                q.title = title
                resolved = true
            elseif (q.titleTries or 0) < MAX_TITLE_TRIES then
                q.titleTries = (q.titleTries or 0) + 1
                C_QuestLog.RequestLoadQuestByID(id)
                break
            end
        end
    end
    if resolved then ns:Changed() end
    if titleHead > #titleQueue then
        ns.titleTicker:Cancel()
        ns.titleTicker = nil
        titleQueue, titleQueued, titleHead = {}, {}, 1
    end
end

local function StartTitleQueue()
    if ns.titleTicker or #titleQueue == 0 then return end
    ns.titleTicker = C_Timer.NewTicker(1 / TITLES_PER_SECOND, function() Safe(TitleTick) end)
end

function H.QUEST_DATA_LOAD_RESULT(questID, success)
    if not success or type(questID) ~= "number" or IsSecret(questID) then return end
    local q = ns.db.quests[questID]
    if q and not q.title then
        local title = Clean(C_QuestLog.GetTitleForQuestID(questID))
        if title then
            q.title = title
            ns:Changed()
        end
    end
end

-- Records every completed quest the character has. Returns how many there are.
function ns:ScanHistory()
    local ids = C_QuestLog.GetAllCompletedQuestIDs()
    if not ids then return 0 end
    local quests, char = self.db.quests, CharKey()
    for _, id in ipairs(ids) do
        local q = quests[id]
        if not q then
            q = {
                status = "history-only", textSource = "none", characters = {},
                readLater = false, read = false, starred = false, note = "",
            }
            quests[id] = q
        elseif q.status ~= "completed" and q.status ~= "history-only" then
            q.status = "completed"
        end
        q.characters = q.characters or {}
        q.characters[char] = true
        if not q.title then QueueTitle(id) end
    end
    StartTitleQueue()
    self:Changed()
    return #ids
end

local function CountBooks()
    local n = 0
    for _ in pairs(ns.db.books) do n = n + 1 end
    return n
end

-- Quest log, then history. announce prints the summary line.
function ns:RunBackfill(announce)
    local logCount = self:ScanQuestLog()
    if not logCount then
        if announce then Print(L.SCAN_DEFERRED) end
        -- Try again shortly; history waits so the summary covers both.
        C_Timer.After(5, function() Safe(self.RunBackfill, self, false) end)
        if announce then self.announcePending = true end
        return
    end
    local historyCount = self:ScanHistory()
    if announce or self.announcePending then
        Print(L.SUMMARY:format(logCount, historyCount, CountBooks()))
        self.announcePending = nil
        self.cdb.backfilled = true
    end
end

------------------------------------------------------------------------------
-- Books, letters, plaques
------------------------------------------------------------------------------

local book  -- the item text being read right now

local function AddLocation(list, zone, mapID, x, y)
    for _, l in ipairs(list) do
        if l.mapID == mapID and l.zone == zone then
            if not x or not l.x then
                if not x and not l.x then return end
            elseif math.abs(l.x - x) < 0.02 and math.abs(l.y - y) < 0.02 then
                return
            end
        end
    end
    if #list < 20 then
        list[#list + 1] = { zone = zone, mapID = mapID, x = x, y = y }
    end
end

-- Saves whatever pages we have. Keyed by title and first page, so the same book read
-- on two characters is one entry and a changed edition is another.
local function CommitBook(b)
    local first = b.pages[1]
    if not first then return end
    local key = Hash((b.title or "") .. "\n" .. first)
    local rec = ns.db.books[key]
    local isNew = not rec
    if isNew then
        rec = {
            title = b.title, material = b.material, pages = {}, locations = {}, seenBy = {},
            firstSeen = time(), readLater = true, read = false, starred = false, note = "",
        }
        ns.db.books[key] = rec
    end
    local added = false
    for page, text in pairs(b.pages) do
        if not rec.pages[page] then
            rec.pages[page] = text
            added = true
        end
    end
    if added and not isNew then rec.readLater, rec.read = true, false end
    if added then rec.lastUpdated = time() end
    rec.seenBy[CharKey()] = true
    if not b.placed then
        AddLocation(rec.locations, b.zone, b.mapID, b.x, b.y)
        b.placed = true
    end
    ns:Changed()
end

function H.ITEM_TEXT_BEGIN()
    local zone, mapID, x, y = GetLocation()
    book = {
        title = Clean(ItemTextGetItem()), material = Clean(ItemTextGetMaterial()),
        pages = {}, zone = zone, mapID = mapID, x = x, y = y,
        auto = ns.db.settings.autoPaginate, phase = "forward",
    }
end

-- Turns pages after a short delay so the default frame has drawn the current one.
local function Turn(b, forward)
    C_Timer.After(0, function()
        if book ~= b then return end
        Safe(forward and ItemTextNextPage or ItemTextPrevPage)
    end)
end

function H.ITEM_TEXT_READY()
    local b = book
    if not b then return end
    local page = ItemTextGetPage() or 1
    if IsSecret(page) then return end
    local text = Clean(ItemTextGetText())
    if text and not b.pages[page] then b.pages[page] = text end
    CommitBook(b)

    -- Auto-pagination: read ahead to the last page, then walk back to page 1.
    -- Stops for good if the reader turns a page themselves.
    if not b.auto then return end
    if b.expect and page ~= b.expect then
        b.auto = false
        return
    end
    if b.phase == "forward" and ItemTextHasNextPage() and not b.pages[page + 1] then
        b.expect = page + 1
        Turn(b, true)
    elseif page > 1 then
        b.phase = "back"
        b.expect = page - 1
        Turn(b, false)
    else
        b.auto = false
    end
end

function H.ITEM_TEXT_CLOSED()
    book = nil
end

------------------------------------------------------------------------------
-- NPC dialogue
------------------------------------------------------------------------------

local function SaveGossip(text)
    local settings = ns.db.settings
    if not settings.captureGossip then return end
    text = Clean(text)
    if not text or #text < (settings.gossipMinLength or 40) then return end
    local npc = NpcName() or L.UNKNOWN_NPC
    local key = Hash(npc .. "\n" .. text)
    local g = ns.db.gossip[key]
    if not g then
        local zone, mapID, x, y = GetLocation()
        g = {
            npc = npc, text = text, zone = zone, mapID = mapID, x = x, y = y,
            firstSeen = time(), characters = {},
            readLater = true, read = false, starred = false, note = "",
        }
        ns.db.gossip[key] = g
        ns:Changed()
    end
    g.characters = g.characters or {}
    g.characters[CharKey()] = true
end

function H.GOSSIP_SHOW()
    SaveGossip(C_GossipInfo.GetText())
end

function H.QUEST_GREETING()
    SaveGossip(GetGreetingText())
end

------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------

function H.PLAYER_ENTERING_WORLD(isLogin, isReload)
    CharKey()
    if isLogin or isReload then
        local announce = not ns.cdb.backfilled
        C_Timer.After(4, function() Safe(ns.RunBackfill, ns, announce) end)
    else
        ns:ScheduleLogScan(2)
    end
end

function H.QUEST_LOG_UPDATE()
    -- Selecting quests during a scan can itself fire this; ignore the echo.
    if ns.lastLogScan and GetTime() - ns.lastLogScan < 3 then return end
    ns:ScheduleLogScan(2)
end

function H.PLAYER_REGEN_ENABLED()
    if ns.scanAfterCombat then
        ns.scanAfterCombat = nil
        ns:ScheduleLogScan(2)
    end
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, ...)
    local handler = H[event]
    if handler then Safe(handler, ...) end
end)

events:RegisterEvent("ADDON_LOADED")
H.ADDON_LOADED = function(name)
    if name ~= ADDON then return end
    events:UnregisterEvent("ADDON_LOADED")

    LorescribeDB = LorescribeDB or {}
    LorescribeCharDB = LorescribeCharDB or {}
    CopyDefaults(LorescribeDB, DEFAULTS)
    Migrate(LorescribeDB)
    ns.db, ns.cdb = LorescribeDB, LorescribeCharDB

    for event in pairs(H) do
        if event ~= "ADDON_LOADED" then
            -- pcall: an event this client doesn't know shouldn't stop the rest.
            pcall(events.RegisterEvent, events, event)
        end
    end
    Safe(ns.UI.UpdateMinimapButton)
end

------------------------------------------------------------------------------
-- Slash commands and entry points
------------------------------------------------------------------------------

local function OnOff(arg, current)
    if arg == "on" then return true elseif arg == "off" then return false end
    return not current
end

local function Stats()
    local withText, titlesOnly, quests = 0, 0, 0
    for _, q in pairs(ns.db.quests) do
        if q.title then
            quests = quests + 1
            local hasText = false
            for _, f in ipairs(TEXT_FIELDS) do
                if q[f] then hasText = true break end
            end
            if hasText then withText = withText + 1 else titlesOnly = titlesOnly + 1 end
        end
    end
    local gossip = 0
    for _ in pairs(ns.db.gossip) do gossip = gossip + 1 end
    Print(L.STATS:format(quests, withText, titlesOnly, CountBooks(), gossip, ns:CountUnread()))
end

local function HandleSlash(msg)
    local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    local arg = (rest or ""):lower()
    local s = ns.db.settings

    if cmd == "" then
        ns.UI.Toggle()
    elseif cmd == "scan" then
        ns:RunBackfill(true)
    elseif cmd == "search" then
        ns.UI.OpenSearch(rest)
    elseif cmd == "export" then
        ns.UI.ExportCurrent()
    elseif cmd == "stats" then
        Stats()
    elseif cmd == "gossip" then
        s.captureGossip = OnOff(arg, s.captureGossip)
        Print(s.captureGossip and L.GOSSIP_ON or L.GOSSIP_OFF)
    elseif cmd == "paginate" then
        s.autoPaginate = OnOff(arg, s.autoPaginate)
        Print(s.autoPaginate and L.PAGINATE_ON or L.PAGINATE_OFF)
    elseif cmd == "markread" then
        s.markReadOnOpen = OnOff(arg, s.markReadOnOpen)
        Print(s.markReadOnOpen and L.MARKREAD_ON or L.MARKREAD_OFF)
    elseif cmd == "minimap" and arg == "reset" then
        s.minimapAngle, s.minimapHide = 140, false
        ns.UI.UpdateMinimapButton()
        Print(L.MINIMAP_ON)
    elseif cmd == "minimap" then
        s.minimapHide = not OnOff(arg, not s.minimapHide)
        ns.UI.UpdateMinimapButton()
        Print(s.minimapHide and L.MINIMAP_OFF or L.MINIMAP_ON)
    elseif cmd == "minlength" and tonumber(arg) then
        s.gossipMinLength = math.max(0, math.floor(tonumber(arg)))
        Print(L.MINLENGTH:format(s.gossipMinLength))
    elseif cmd == "link" and rest ~= "" then
        s.linkBase = rest
        Print(L.LINKBASE:format(rest))
        ns:Changed()
    elseif cmd == "reset" then
        ns.UI.ResetWindow()
        Print(L.WINDOW_RESET)
    elseif cmd == "errors" then
        if #ns.errors == 0 then
            Print(L.NO_ERRORS)
        else
            Print(L.ERRORS:format(#ns.errors))
            for _, e in ipairs(ns.errors) do DEFAULT_CHAT_FRAME:AddMessage(e) end
        end
    else
        for _, line in ipairs(L.HELP) do Print(line) end
    end
end

SLASH_LORESCRIBE1 = "/ls"
SLASH_LORESCRIBE2 = "/lorescribe"
SlashCmdList.LORESCRIBE = function(msg)
    Safe(HandleSlash, msg or "")
end

function Lorescribe_Toggle()
    Safe(ns.UI.Toggle)
end

function Lorescribe_OnAddonCompartmentClick()
    Safe(ns.UI.Toggle)
end

function Lorescribe_OnAddonCompartmentEnter(_, button)
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:SetText(L.TITLE)
    GameTooltip:AddLine(L.COMPARTMENT_TIP, 1, 1, 1)
    local unread = ns.db and ns:CountUnread() or 0
    if unread > 0 then GameTooltip:AddLine(L.TITLE_UNREAD:format(unread), 0.8, 0.8, 0.8) end
    GameTooltip:Show()
end

function Lorescribe_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end
