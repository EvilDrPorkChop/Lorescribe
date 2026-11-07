# Lorescribe

A World of Warcraft addon for WoW Forever that saves quest text, books and NPC dialogue as you play, so you can skip reading in the moment and come back to it later.

Everything new lands in a "Read later" queue. Open the library with `/ls` and read at your own pace.

## What it saves

- **Quests:** the description and objectives when a quest is offered (including quests you decline), the progress text when you return, and the completion text when you hand it in. All of it goes into one entry per quest.
- **Books, letters, plaques and notes:** every page. Books are paged through automatically when you open them, so closing one on page 1 still saves the whole thing. The same book read on two characters is saved once.
- **NPC dialogue:** the greeting text when you talk to an NPC. Short generic greetings are skipped. You can turn this off with `/ls gossip off`.

It also notes the zone, coordinates, date and which character saw it.

## What it can recover from before you installed it

The first time you log in, Lorescribe reads what the game still knows:

- **Quests in your log:** full description and objectives.
- **Completed quests:** titles only. The game keeps a list of which quests you've finished but not their text. These show as "Text not captured" with a link to look the quest up online.
- **Books:** nothing. The game keeps no record of what you've read. Open them again and they'll be saved.

Progress and completion text can't be recovered for quests already in your log; it's saved when you hand them in.

## Install

1. Download the latest zip from the [releases page](https://github.com/EvilDrPorkChop/Lorescribe/releases), or install it with WowUp from this repository.
2. Extract it into `World of Warcraft/_forever_/Interface/AddOns/`, so you end up with `.../AddOns/Lorescribe/Lorescribe.toc`.
3. Restart the game or type `/reload`.

## Using the library

Open it with `/ls`, the book button on the minimap (drag it to move it), or a key bound under Key Bindings > AddOns.

- Tabs along the top: Read later, Quests, Books, Dialogue, Starred, All.
- The search box looks through titles, zones, NPC names and the full text.
- Filter by zone or character, and sort by date, zone or title.
- Opening an entry doesn't mark it read. Use **Mark read** when you're done, or `/ls markread on` to have opening do it.
- **Copy** opens the entry as plain text, ready for Ctrl+C. **Export** does the same for the whole list you're looking at.
- A- and A+ change the reading text size.

## Commands

| Command | What it does |
|---|---|
| `/ls` | Open or close the library |
| `/ls scan` | Read your quest log and completed quest history again |
| `/ls search <text>` | Open the library with a search filled in |
| `/ls export` | Copy the current list as plain text |
| `/ls stats` | Counts by type and how many are waiting to be read |
| `/ls gossip on\|off` | NPC dialogue capture |
| `/ls paginate on\|off` | Page through books automatically |
| `/ls markread on\|off` | Mark entries read when you open them |
| `/ls minimap on\|off\|reset` | Show, hide or move back the minimap button |
| `/ls minlength <n>` | Shortest dialogue worth saving (default 40 characters) |
| `/ls link <url>` | Base URL for quest links (default `https://www.wowhead.com/quest=`) |
| `/ls reset window` | Put the window back in the middle of the screen |
| `/ls errors` | Show any errors caught this session |

## Your data

Everything is stored in one file shared by all your characters:

`World of Warcraft/_forever_/WTF/Account/<ACCOUNT>/SavedVariables/Lorescribe.lua`

It's a plain Lua table. Back it up, or read it with your own tools outside the game. Addons can't write other files, so export inside the game is copy and paste only.

## Notes

- Lorescribe only listens to game events. It doesn't touch combat or protected frames.
- If a capture ever fails, the error is recorded instead of interrupting play. `/ls errors` shows them, which is useful for bug reports.
