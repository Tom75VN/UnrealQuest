# Database Credits

UnrealQuest bundles the complete **Vanilla** database from **pfQuest**, excluding all Burning Crusade (`*-tbc.lua`) data.

The database content originates from the VMaNGOS world database and is packaged by pfQuest.

- pfQuest — Eric Mauser / Shagu — MIT License
- VMaNGOS — world database source used by pfQuest

UnrealQuest changes only the Lua table namespace/packaging so the data can be loaded through `UnrealQuestData`. The underlying Vanilla data and all available pfQuest locales are retained.

Included locales: deDE, enUS, esES, frFR, koKR, ptBR, ruRU, zhCN, zhTW.

## VMaNGOS trainer and patrol additions

Trainer classification and permanent patrol data were extracted from
`db-sqlite-6958f26`.

The optimized layout is locale-independent:
- `trainers.lua`: trainer metadata only; localized names and NPC positions are reused.
- `waypoint_index.lua`: lightweight NPC-to-route lookup.
- `Waypoints/*.lua`: deduplicated patrol routes split by world region.

`creature_movement_special` and `script_waypoint` are intentionally excluded because
they describe triggered/scripted/escort movement rather than normal permanent patrols.

## Patrol scope

Battleground and instance patrols are intentionally not shipped in the optimized
quest database. Only Eastern Kingdoms and Kalimdor permanent patrol routes are kept.

