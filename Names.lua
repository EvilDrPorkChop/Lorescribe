-- Lorescribe Names: the people and bosses Lorescribe knows about, and finding them in saved text.
-- Names come from NPCs you deal with, notable units you target, boss fights, the Dungeon
-- Journal and names you track yourself. Matching is done against saved text whenever it's
-- needed, so a newly learned name links up with everything saved before it.
local ADDON, ns = ...
local L = ns.L

local Names = {}
ns.Names = Names

-- Words that start or end many NPC names but don't identify anyone on their own,
-- so they're never used as a short form of a longer name.
local TITLES = {}
for w in ([[Lord Lady King Queen Prince Princess Baron Baroness Count Countess Duke Duchess
    Archmage Magister Captain Commander General Lieutenant Sergeant Corporal Private Marshal
    Overlord Warlord Warchief Chieftain Elder High Grand Arch Brother Sister Father Mother
    Master Mistress Old Young Great Dark Shadow Deathstalker Apothecary Magistrate Warden Guard
    Scout Ranger Priest Priestess Bishop Archbishop Inquisitor Highlord Admiral Doctor Professor
    Sir Dame Uncle Aunt Grandmother Grandfather Little Big Mister Miss Chief Keeper Watcher
    Seer Shaman Farseer Thane Ambassador Emissary Herald Champion Scarlet Defias Crimson
    Battlemaster Quartermaster Innkeeper Trainer Vendor Merchant Banker Steward Foreman
    Bloodmage Huntsman Huntress Sentinel Druid Paladin Warlock Mage Rogue Hunter Warrior]]):gmatch("%S+") do
    TITLES[w] = true
end

-- Sources in order of how much they say about someone; a name keeps its best one.
local SOURCE_RANK = { npc = 1, target = 2, boss = 3 }

local index, dirty = nil, true
local journal  -- [name] = { source = "journal", zone = instance name }, read once per session

function Names.MarkDirty()
    dirty = true
end

------------------------------------------------------------------------------
-- Words
------------------------------------------------------------------------------

-- Trims quotes, dashes and possessives ("Hamuul's", "Hamuul’s") from a word.
local function Clip(w, s, e)
    while #w >= 3 and w:sub(1, 2) == "\226\128" do w, s = w:sub(4), s + 3 end
    while #w > 0 and w:sub(1, 1):find("['%-]") do w, s = w:sub(2), s + 1 end
    local changed = true
    while changed and #w > 0 do
        changed = false
        if #w >= 4 and w:sub(-4) == "\226\128\153s" then
            w, e, changed = w:sub(1, -5), e - 4, true
        elseif #w >= 3 and w:sub(-3, -2) == "\226\128" then
            w, e, changed = w:sub(1, -4), e - 3, true
        elseif w:sub(-2) == "'s" then
            w, e, changed = w:sub(1, -3), e - 2, true
        elseif w:sub(-1):find("['%-]") then
            w, e, changed = w:sub(1, -2), e - 1, true
        end
    end
    return w, s, e
end

-- Splits text into words with their byte positions: { { w = "Arugal", s = 10, e = 15 }, ... }.
-- Letters, apostrophes and hyphens make up a word, and any non-ASCII byte counts as a
-- letter so accented names stay whole.
local function Tokens(text)
    local out = {}
    for s, w, e in text:gmatch("()([%a\128-\255][%a\128-\255'%-]*)()") do
        w, s, e = Clip(w, s, e - 1)
        if #w > 0 then out[#out + 1] = { w = w, s = s, e = e } end
    end
    return out
end
Names.Tokens = Tokens

local function Words(name)
    local out = {}
    for _, t in ipairs(Tokens(name)) do out[#out + 1] = t.w end
    return out
end

------------------------------------------------------------------------------
-- The Dungeon Journal
------------------------------------------------------------------------------

-- Every boss the client's Dungeon Journal lists. Read once per session; nothing is saved.
local function LoadJournal()
    if journal then return journal end
    if not (EJ_GetNumTiers and EJ_SelectTier and EJ_GetInstanceByIndex and EJ_GetEncounterInfoByIndex) then
        journal = {}
        return journal
    end
    -- Reading it changes the journal's selected tier, so wait until it's closed.
    if EncounterJournal and EncounterJournal:IsShown() then return {} end

    local found = {}
    pcall(function()
        local previous = EJ_GetCurrentTier and EJ_GetCurrentTier()
        for tier = 1, EJ_GetNumTiers() do
            EJ_SelectTier(tier)
            for _, isRaid in ipairs({ false, true }) do
                for i = 1, 300 do
                    local instanceID, instanceName = EJ_GetInstanceByIndex(i, isRaid)
                    if not instanceID then break end
                    for j = 1, 60 do
                        local name = ns.Clean((EJ_GetEncounterInfoByIndex(j, instanceID)))
                        if not name then break end
                        found[name] = { source = "journal", zone = ns.Clean(instanceName) }
                    end
                end
            end
        end
        if previous then EJ_SelectTier(previous) end
    end)
    journal = found
    return journal
end

------------------------------------------------------------------------------
-- Known names
------------------------------------------------------------------------------

-- What we know about a name, or nil if it's unknown or hidden.
function Names.Info(name)
    local db = ns.db
    if db.ignoredNames[name] then return nil end
    return db.names[name] or LoadJournal()[name]
end

function Names.Add(name, source, zone)
    name = ns.Clean(name)
    if not name or #name < 3 or name == L.UNKNOWN_NPC then return end
    local names = ns.db.names
    local info = names[name]
    if not info then
        names[name] = { source = source, zone = zone, firstSeen = time() }
        dirty = true
        ns:Changed()
    elseif info.source ~= "manual" and (SOURCE_RANK[source] or 0) > (SOURCE_RANK[info.source] or 0) then
        info.source = source
        info.zone = info.zone or zone
    end
end

-- Follows a name the addon hasn't picked up itself, or brings back a hidden one.
function Names.Track(name)
    name = ns.Clean(name)
    if not name then return nil end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    local db = ns.db
    db.ignoredNames[name] = nil
    if not db.names[name] then
        db.names[name] = { source = "manual", firstSeen = time() }
    end
    dirty = true
    ns:Changed()
    return name
end

function Names.Hide(name)
    if not name or name == "" then return end
    ns.db.ignoredNames[name] = true
    dirty = true
    ns:Changed()
end

------------------------------------------------------------------------------
-- Matching
------------------------------------------------------------------------------

local function AddKey(idx, words, name)
    local list = idx[words[1]]
    if not list then
        list = {}
        idx[words[1]] = list
    end
    list[#list + 1] = { words = words, name = name }
end

-- Word lists for every known name, keyed by first word. A two-word name like
-- "Hamuul Runetotem" also matches "Hamuul" or "Runetotem" alone, as long as no
-- other name shares that word and it isn't a title like "Lord".
function Names.Index()
    if index and not dirty then return index end
    local db = ns.db
    local fromJournal = LoadJournal()
    local idx, short = {}, {}

    local function Consider(name)
        if db.ignoredNames[name] then return end
        local words = Words(name)
        if #words == 0 then return end
        AddKey(idx, words, name)
        if #words >= 2 then
            for _, w in ipairs({ words[1], words[#words] }) do
                if #w >= 4 and not TITLES[w] and w:find("^%u") then
                    short[w] = short[w] or {}
                    short[w][name] = true
                end
            end
        end
    end

    for name in pairs(db.names) do Consider(name) end
    for name in pairs(fromJournal) do
        if not db.names[name] then Consider(name) end
    end

    for w, owners in pairs(short) do
        local only, count = nil, 0
        for name in pairs(owners) do
            only, count = name, count + 1
        end
        if count == 1 and not db.names[w] and not fromJournal[w] then
            AddKey(idx, { w }, only)
        end
    end

    for _, list in pairs(idx) do
        table.sort(list, function(a, b) return #a.words > #b.words end)
    end
    index, dirty = idx, false
    return index
end

-- Calls fn(name, startByte, endByte) for each known name in text, preferring the
-- longest match ("Lord Godfrey" over "Godfrey").
function Names.Scan(text, fn)
    if not text or text == "" then return end
    local idx = Names.Index()
    local toks = Tokens(text)
    local i, n = 1, #toks
    while i <= n do
        local list = idx[toks[i].w]
        local hit
        if list then
            for _, c in ipairs(list) do
                local k = #c.words
                if i + k - 1 <= n then
                    local ok = true
                    for m = 2, k do
                        if toks[i + m - 1].w ~= c.words[m] then
                            ok = false
                            break
                        end
                    end
                    if ok then
                        hit = c
                        break
                    end
                end
            end
        end
        if hit then
            local last = i + #hit.words - 1
            fn(hit.name, toks[i].s, toks[last].e)
            i = last + 1
        else
            i = i + 1
        end
    end
end

Names.LINK_COLOR = "|cff1d4f91"

function Names.LinkFor(name, label)
    return Names.LINK_COLOR .. "|Hlorescribe:n:" .. name .. "|h" .. (label or name) .. "|h|r"
end

-- Text with every known name turned into a clickable link.
function Names.Link(text)
    local parts, last = {}, 1
    Names.Scan(text, function(name, s, e)
        parts[#parts + 1] = text:sub(last, s - 1)
        parts[#parts + 1] = Names.LinkFor(name, text:sub(s, e))
        last = e + 1
    end)
    if last == 1 then return text end
    parts[#parts + 1] = text:sub(last)
    return table.concat(parts)
end

------------------------------------------------------------------------------
-- Collecting names as you play
------------------------------------------------------------------------------

local NOTABLE = { elite = true, rareelite = true, rare = true, worldboss = true }

-- True only for a value that's both known and true; secret values count as unknown.
local function Yes(v)
    return not ns.IsSecret(v) and v and true or false
end

-- Named NPCs you target out of combat: friendly ones, and hostile ones that are
-- elite, rare or bosses. Ordinary mobs ("Bristleback Quilboar") are left out.
local function OnTargetChanged()
    if InCombatLockdown() or not Yes(UnitExists("target")) then return end
    local isPlayer = UnitIsPlayer("target")
    local controlled = UnitPlayerControlled("target")
    if ns.IsSecret(isPlayer) or isPlayer or ns.IsSecret(controlled) or controlled then return end
    local class = UnitClassification("target")
    if ns.IsSecret(class) then return end
    local hostile = UnitCanAttack("player", "target")
    if ns.IsSecret(hostile) then return end
    if hostile and not NOTABLE[class] then return end
    local zone = ns.GetLocation()
    Names.Add(UnitName("target"), class == "worldboss" and "boss" or "target", zone)
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, ...)
    if not ns.db then return end
    ns.Safe(function(...)
        if event == "PLAYER_TARGET_CHANGED" then
            OnTargetChanged()
        elseif event == "ENCOUNTER_START" or event == "BOSS_KILL" then
            local _, encounterName = ...
            Names.Add(encounterName, "boss", (ns.GetLocation()))
        end
    end, ...)
end)
for _, event in ipairs({ "PLAYER_TARGET_CHANGED", "ENCOUNTER_START", "BOSS_KILL" }) do
    pcall(events.RegisterEvent, events, event)
end
