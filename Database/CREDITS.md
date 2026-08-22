# Bundled world data

The files in this directory are not original to UnrealQuest. They describe the
game world: which quests exist, who gives and takes them, what satisfies their
objectives, and where those creatures and objects stand.

## Where it comes from

```
VMaNGOS world database        open-source 1.12 server project; the source of record
        |
        v
pfQuest                       Eric Mauser (Shagu), MIT; packages that data into Lua tables
        |
        v
UnrealQuest Database/         reduced to quest-relevant records, renamed onto our own global
```

The **data tables** and the small `media/QuestDot.tga` minimap marker are
reused. No pfQuest source code is used, copied or adapted, and UnrealQuest does
not require pfQuest to be installed. The full license text and attribution are
in `LICENSE` at the addon root.

## What was reduced

The pfQuest tables carry far more than a quest helper needs. This copy keeps
only quest-relevant records:

| Removed | Why |
| --- | --- |
| All TBC data | this client is 1.12 |
| All non-English localizations | this build is English only |
| Profession tables, and quest skill/profession restriction fields | not quest routing data |
| Vendor item-source relations, and vendor-only NPCs | a vendor is not a quest objective |
| Creatures, objects, items, reference loot and area triggers not reachable from a quest | unreferenced weight |
| Dangling references with no matching source record | would resolve to nothing at runtime |

Zone, minimap and English zone-name tables are kept intact — they are small
coordinate-support tables that the map layer will need in full.

Retained record counts:

| Table | Records |
| --- | --- |
| Quests | 4433 |
| Quest text (title, objectives, description) | 4433 |
| Creatures | 5621 |
| Objects | 1035 |
| Items | 2342 |
| Reference loot groups | 77 |
| Quest item-use targets | 180 |
| Area triggers | 48 |

## Table shapes

Everything hangs off the global `UnrealQuestData`, created by `init.lua`.

```
quests[id]        lvl, min, race, class, pre, event, close, and the relation
                  tables start / end / obj, each shaped
                  { U = { creatureId, ... }, O = { objectId, ... }, I = { itemId, ... } }
quests_enUS[id]   T title, O objectives text, D description
units[id]         coords = { { x, y, areaId, respawn }, ... }, lvl
objects[id]       coords = { { x, y, areaId, respawn }, ... }, fac
items[id]         U = { creatureId = dropRate }, O = { objectId = dropRate }
refloot[id]       shared loot groups referenced by items
quests-itemreq    quest item-use targets
zones[areaId]     parentAreaOrContinent, width, height, xOffset, yOffset
zones_enUS[id]    area name
minimap[areaId]   area width and height in yards
areatrigger[id]   coords = { { x, y, areaId }, ... }
```

Coordinates are percentages within an area, and areas are keyed by **WoW area
IDs**. `end` is a Lua keyword, so that relation can only be reached by string
index — `Data/Database.lua` wraps the three relations so callers never have to.

## Two caveats that matter

1. **This data is never evidence about the client API.** It says what exists in
   the game world, not what the client's Lua environment can do. Client
   capability questions go to `query_compat.py`. See
   `docs/CLIENT-COMPATIBILITY.md`.

2. **This is Vanilla data and Emberveil is a modified server.** Quests the
   server added, renamed or reworked will not match these records, and the
   extraction already contains visibly server-edited titles. Unmatched quests
   are an expected outcome, not a bug — `Data/QuestMatch.lua` reports them
   honestly and records them, and `/uq db` shows the count.

## Access

Read this data through `Data/Database.lua`, never by touching `UnrealQuestData`
directly. The adapter owns the table shapes, the lazily built title index, and
the `end`-keyword problem, so a change to the data layout lands in one file.
