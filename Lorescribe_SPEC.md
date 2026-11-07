# Lorescribe: WoW Forever addon spec

A lightweight addon that automatically saves quest text, NPC dialogue, and books as I play, so I can skip reading in the moment and come back to it later. It should also recover as much as possible from what I've already done.

Working name: **Lorescribe** (rename freely).

---

## 1. Target client

- **WoW Forever**, which runs on the Mainline (Retail) client architecture, roughly the 12.1.x API. It is NOT a Classic client, so Classic-only APIs (old `GetQuestLogTitle` style) must not be used.
- Get the interface number from the live client before packaging: run `/dump select(4, GetBuildInfo())` in game and put the result in the TOC `## Interface:` line. (Community sources report 16001 for Forever; verify, don't assume.)
- Install path: `World of Warcraft/_forever_/Interface/AddOns/Lorescribe/`.
- No external libraries required. No Ace3 unless there's a strong reason. Plain Lua and XML-free frames created in Lua are fine.
- Forever inherits Midnight-era addon restrictions. Nothing in this addon touches combat or protected frames, so it should be unaffected, but: use events only, never hook or modify secure/protected Blizzard frames, and never call protected functions.

## 2. Goals and non-goals

**Goals**
1. Capture quest text automatically (offer text, objectives, progress text, completion text).
2. Capture book, letter, plaque, and note text automatically (all pages).
3. Optionally capture NPC gossip text.
4. Backfill as much past content as the API allows on first load (see section 6).
5. A simple in-game library to browse, search, and read entries, with a "read later" queue.
6. Export to plain text so I can read outside the game.

**Non-goals**
- No lore database shipped with the addon. Everything comes from what I see in game.
- No gamification, levels, ranks, or data sharing with other players.
- No TTS or narration.
- No quest helper, waypoints, or map pins.

## 3. Capture: quests

Store per quest ID. Update the record as more text appears; never overwrite non-empty text with empty text.

| Event | What to grab | API |
|---|---|---|
| `QUEST_DETAIL` | Title, description, objectives, quest giver name | `GetQuestID()`, `GetTitleText()`, `GetQuestText()`, `GetObjectiveText()`, `UnitName("npc")` |
| `QUEST_ACCEPTED` | Mark accepted, timestamp, zone | `questID` from event payload |
| `QUEST_PROGRESS` | Progress text (the "have you got it yet?" text) | `GetProgressText()` |
| `QUEST_COMPLETE` | Completion text | `GetRewardText()` |
| `QUEST_TURNED_IN` | Mark completed, timestamp | `questID` from event payload |
| `QUEST_REMOVED` | If not turned in, mark abandoned (keep the text) | `questID` |

Also store for each quest:
- `zone` (map name at the time of first capture) and `mapID`
- `coords` (player x, y) at first capture
- `level` (quest level if available via `C_QuestLog.GetQuestInfo`/`GetInfo`, else nil)
- `character` (name-realm) that captured it
- `firstSeen`, `lastUpdated` timestamps (`time()`)
- `status`: `offered` | `accepted` | `completed` | `abandoned` | `history-only` (see 6.2)
- `textSource`: `live` | `questlog-backfill` | `none`

Location helpers: `C_Map.GetBestMapForUnit("player")`, `C_Map.GetPlayerMapPosition(mapID, "player")`, `C_Map.GetMapInfo(mapID).name`. Guard against nil (instances often return nil position).

Quest offers I decline should still be saved (status `offered`). That's lore I saw.

## 4. Capture: books and readable objects

Events: `ITEM_TEXT_BEGIN`, `ITEM_TEXT_READY`, `ITEM_TEXT_CLOSED`.

- On `ITEM_TEXT_BEGIN`: start a new capture buffer with title (`ItemTextGetItem()`), material (`ItemTextGetMaterial()`), zone, coords, timestamp.
- On each `ITEM_TEXT_READY`: store `ItemTextGetPage()` -> `ItemTextGetText()` in the buffer.
- **Auto-pagination:** after storing a page, if `ItemTextHasNextPage()` is true and that page number isn't captured yet, call `ItemTextNextPage()` so the whole book is saved even if I close it after page 1. When done, return to page 1 (`ItemTextPrevPage()` repeatedly, or simply leave it), so the UI doesn't feel hijacked. Make auto-pagination a setting, default ON.
- On `ITEM_TEXT_CLOSED`: commit the buffer.
- Key books by a hash of `title + page1 text`, so the same book read on two characters is one entry, while different editions with changed text are separate entries. Keep a `seenBy` list of characters and a `locations` list (dedupe nearby coords).

## 5. Capture: NPC gossip (optional, default ON)

- On `GOSSIP_SHOW`: `C_GossipInfo.GetText()` plus `UnitName("npc")`, zone, coords.
- Dedupe by `npcName + text` hash. Skip empty text and the generic "What can I do for you?" type greetings if they're very short (under ~40 chars, configurable).
- Setting to turn this off entirely, since it can get noisy.

## 6. Backfill: recovering what I've already done

This is the important part. Be honest in the UI about what can and can't be recovered.

### 6.1 Current quest log: FULL recovery (run on first load, and on demand)

Every quest currently in my log still has its description and objectives available client-side.

- Iterate `C_QuestLog.GetNumQuestLogEntries()` / `C_QuestLog.GetInfo(i)`, skip headers.
- For each quest: `C_QuestLog.SetSelectedQuest(questID)` then `GetQuestLogQuestText()` returns `description, objectives`. Restore the previously selected quest afterwards.
- Save with `textSource = "questlog-backfill"`. Zone should come from the quest log header/zone if available, not the player's current location (mark coords nil).
- Trigger automatically on `PLAYER_ENTERING_WORLD` (first login per character, and again whenever the quest log changes) so nothing in the log is ever missed. Also a manual `/ls scan`.
- Progress and completion text can't be backfilled. They'll be captured live when I hand the quest in.

### 6.2 Completed quests: titles and IDs only

The client knows which quests I've completed, but NOT their text.

- `C_QuestLog.GetAllCompletedQuestIDs()` gives every completed quest ID for the character.
- For each ID with no existing record, create a `history-only` entry with the title from `C_QuestLog.GetTitleForQuestID(questID)`.
- Titles may be nil until cached. Use `C_QuestLog.RequestLoadQuestByID(questID)` and listen for `QUEST_DATA_LOAD_RESULT`, throttled (e.g. 20 requests per second, spread over frames via `C_Timer`) so login doesn't hitch. Retry nil titles on later sessions.
- In the library these show as "Text not captured" with:
  - the quest ID
  - a copyable Wowhead-style link (`https://www.wowhead.com/quest=<ID>`, base URL configurable in settings in case Forever has its own database site)
- Many completed IDs are hidden/tracking flags with no title. Hide entries with no title after a few retries, behind a "show untitled" toggle.

### 6.3 Books already read: not recoverable

There's no API for "books I've read". The library should simply say so in its empty state or help text. The fix is to reread them; the addon captures them on reopening.

### 6.4 First-run summary

After the first backfill, print one chat line, e.g.:
`Lorescribe: saved full text for 18 quests in your log, found 142 completed quests (titles only), 0 books.`

## 7. Data model (SavedVariables)

- `## SavedVariables: LorescribeDB` (account-wide; one library across characters)
- `## SavedVariablesPerCharacter: LorescribeCharDB` (only for per-character UI state, if needed)

```lua
LorescribeDB = {
  version = 1,
  settings = { autoPaginate = true, captureGossip = true, gossipMinLength = 40,
               linkBase = "https://www.wowhead.com/quest=", fontSize = 13 },
  quests = {
    [questID] = {
      title, giver, description, objectives, progress, completion,
      zone, mapID, coords = {x, y}, level,
      status, textSource, characters = { ["Name-Realm"] = true },
      firstSeen, lastUpdated, readLater = false, read = false, starred = false, note = "",
    },
  },
  books = {
    [hash] = { title, material, pages = { [1] = "...", [2] = "..." },
               locations = { {zone, mapID, x, y} }, seenBy = {}, firstSeen,
               readLater, read, starred, note },
  },
  gossip = {
    [hash] = { npc, text, zone, mapID, x, y, firstSeen, readLater, read, starred },
  },
}
```

Include a `version` field and a migration function from day one.

**Read-later default:** every newly captured entry with text gets `readLater = true` and `read = false`. That's the whole point: I skip it now and it lands in my queue. History-only entries default to `readLater = false`.

## 8. UI

One movable, resizable window (remember position and size). Close with Escape (add to `UISpecialFrames`).

- **Left pane:** list of entries
  - Tabs or a dropdown: **Read later** (default view) | Quests | Books | Dialogue | Starred | All
  - Search box: matches title, zone, NPC, and full text (case-insensitive, plain find, no patterns)
  - Filter by zone and by character
  - Sort: newest first (default), zone, title
  - Each row: title, zone, small type icon/label, unread dot
- **Right pane:** reader
  - Quest layout: title, giver, zone, then Description, Objectives, Progress, Completion as labelled sections; empty sections hidden
  - Book layout: all pages in one scroll, with page separators
  - History-only quests: "Text not captured" message plus a copyable link box
  - Buttons: Mark read/unread, Star, Remove from queue, Copy (opens export box), Delete
  - Optional one-line personal note field
- Opening an entry does NOT auto-mark it read; there's an explicit button (so skimming doesn't empty the queue). Setting to change this.
- Font size control (A- / A+) for the reader.
- Entry points: `/ls` (toggle), Addon Compartment entry (`## AddonCompartmentFunc` in the TOC, so no minimap library is needed), optional keybinding via `Bindings.xml`.
- Unread count shown in the window title, e.g. "Lorescribe (37 to read)".

Visual style: match Blizzard's parchment look loosely or go clean dark; pick one and keep it readable. Text must be selectable or copyable via the export box.

## 9. Export

- "Copy" on a single entry: opens a multi-line EditBox with the full text pre-selected so I can Ctrl+C.
- `/ls export` (and a button): exports the current filtered list as plain text, one entry after another with headers. Addons can't write files, so this is copy-paste only. Chunk it if it's huge (EditBoxes struggle past ~100k characters) with Next/Prev chunk buttons.
- Note in the README: SavedVariables live at `WTF/Account/<ACCOUNT>/SavedVariables/Lorescribe.lua` and can be backed up or parsed outside the game.

## 10. Slash commands

| Command | Action |
|---|---|
| `/ls` | Toggle window (opens on Read later) |
| `/ls scan` | Rerun quest log backfill and completed-quest history |
| `/ls search <text>` | Open with search filled in |
| `/ls export` | Open export for the current view |
| `/ls stats` | Chat summary: counts by type, unread count |
| `/ls gossip on/off` | Toggle gossip capture |
| `/ls reset window` | Reset position and size |

## 11. Robustness

- Wrap every event handler in `pcall` (or guard nils carefully). A capture failure must never throw a Lua error mid-quest.
- Never overwrite captured text with nil or empty strings.
- Strip or keep WoW escape codes? Keep the raw text in the DB; replace `$N`, `$C`, `$R` style tokens only at display time if they show up unreplaced (the APIs normally return substituted text, so this is a fallback).
- Throttle all bulk work (backfill, title loading) across frames.
- Performance: list rendering should use a scroll box with recycled rows (`ScrollBox` / `CreateScrollBoxListLinearView` from the modern UI) so thousands of entries stay smooth.
- Localisation: English only for now, but keep user-facing strings in one table.

## 12. Acceptance tests (manual, in game)

1. Fresh install with 10+ quests in log: on login, all of them appear in Quests with description and objectives, and the chat summary line prints.
2. Completed quests appear as history-only with titles (after a short delay) and a working copy link.
3. Take a new quest: offer text saved on the detail screen, even if I decline it.
4. Hand in a quest: progress and completion text added to the same entry; status `completed`.
5. Open a 4-page book and close it on page 1: all 4 pages are saved.
6. Reopen the same book on an alt: no duplicate; alt added to `seenBy`.
7. Talk to an NPC with gossip: entry saved; generic short greetings skipped.
8. Search for a word that only appears inside a book's page 3: the book is found.
9. `/reload`: everything persists; window position persists.
10. No Lua errors with BugSack installed across a full play session, including dungeons and combat.

## 13. Deliverables

- `Lorescribe/Lorescribe.toc`
- `Lorescribe/Core.lua` (events, capture, backfill, DB, migrations)
- `Lorescribe/UI.lua` (window, list, reader, export)
- `Lorescribe/README.md` (install, commands, what backfill can and can't recover)
- Zip with the `Lorescribe` folder at the root (not double-nested).
