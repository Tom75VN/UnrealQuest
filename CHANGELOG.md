# Changelog

## 0.2.3

- Fixed "only show quests from the current zone" showing your whole quest log whenever you stood somewhere none of your quests were. The rule that stops the tracker going blank was listing everything as soon as nothing matched, so walking into a capital, crossing a zone or finishing a zone's quests left the window full of quests from everywhere. It now tells the two cases apart: when the zone is one the client or the bundled data can actually name, the filter stands and the window says "No quests in this zone" in a single row; the whole log is listed only when the zone itself could not be identified, which is what that rule was for.
- An item a quest has you *use* on something is no longer treated as an objective you have to farm, so the quest's real target stops being buried. "Frostmaw" is the case that showed it: the map drew 73 dots in Alterac and 99 in Hillsbrad for the four Mountain Lion species that drop the Fresh Carcass, with Frostmaw's own single summon coordinate lost among them. The map now shows where to get the carcass while you still need one, and once it is in your bags shows only Frostmaw and the cave you place it at. It applies to all 57 quests built this way, "Marla's Last Wish" included, and a quest that genuinely counts the item -- its log line still unfinished -- keeps showing you where to get the rest.
- Objective rows in the tracker now draw a progress bar under any objective that counts something, alongside the numbers. A checkbox in the tracker settings turns them off.
- "Show" in the quest log, and Ctrl+click in the tracker, now open the map on the zone you actually have to go to instead of the one you are standing in. For a finished quest that is where it is handed in, for an unfinished one where its objectives are -- so a quest looted in Ashenvale and handed in at Sun Rock Retreat opens the Stonetalon Mountains, crossing to the other continent when it has to. The map is put back on your own zone once you travel, or shortly after, because the minimap pins, the quest arrow and the rare alert all need it there; a zone you pick yourself from the map's own dropdown is left alone. If the client will not show the zone at all, it is still named in chat the way it was before.
- The quest tracker now marks a completed quest with the complete-quest icon in front of its name instead of turning the title white, and sinks it below the quests you still have to finish in its zone. The title keeps its usual level-difficulty colour. This updates the instant a quest completes, and again on login or /reload.
- Fixed hovering a quest creature showing two tooltips at once: the client's own tooltip and, under it, a second panel with the quest progress. The creature's name, level and classification are now printed inside the single tooltip that carries the progress, the way a one-line world object already was.
- Patrol routes on the world map for one-of-a-kind quest targets, and on hover for service, rare and quest-vendor pins.
- Fixed the quest tracker emptying itself whenever you walked indoors. This client answers with the room you are standing in -- "Echo Ridge Mine", "Brill Town Hall" -- through both of its zone calls, which matched no quest and hid the whole log until you stepped back outside. The tracker now recognises a name that is not one of the zones the client itself lists, and recovers the zone the mine or building sits in: from the bundled area table where it knows a parent, otherwise from the zone you walked in from, otherwise from the zone the world map is showing. It never filters on a name it cannot place. The tracker also refuses the outcome outright now, not just the causes it knows about: if "only show quests from the current zone" would hide every quest in your log, the filter is dropped for that refresh and the whole log is listed. A filter that is too strict can narrow the window; it can no longer empty it, whatever the client answers when you step through a door.
- Quests filed in the log under a subzone of where you are standing -- "Northshire Valley" while you are in Elwynn Forest -- now stay in the tracker's current-zone view instead of depending on the map having something to draw for them.
- Fixed right-click doing nothing on a quest whose objectives were folded automatically because it had no progress yet. Right-click now always toggles the row you are looking at, and no fold outlives the quest's next update: killing a mob, looting a quest item or finishing an objective reopens that quest so you see what moved. A quest that already has progress is never left folded when you log in either.
- Bundled 75 reviewed Rare/Elite/Boss creature-zone exclusions across 16 outdoor zones, suppressing dungeon-approach records from both maps and proximity alerts.
- Proximity alerts are now disabled throughout Stormwind, Ironforge, Darnassus, Orgrimmar, Thunder Bluff and Undercity.
- The option that hid quests until progress started now defaults on, keeps their titles visible and automatically folds only their objectives. Progress unfolds them again unless the player folded the quest manually.
- The NPC finder can now draw dungeon and raid entrances from the bundled instance database on both maps, using a distinct icon for each type.
- "Only show quests from the current zone" now keeps a quest whose objectives are here even when the quest log files it under another zone. The tracker asks the map: if a dot, a turn-in marker or a vendor pin for that quest would be drawn on the zone you are standing in, the quest stays in the window.
- Hovering any minimap quest dot, quest marker, service/node marker or quest vendor now opens its tooltip, matching pfQuest's minimap behavior.
- Fixed the quest tracker's text and controls drawing over unit frames or the minimap when the tracker was placed beneath them.
- Added a disabled-by-default "Show low-level quests" setting. When enabled, offerable grey/trivial quests appear on the world map and minimap with the low-level quest-giver icon; CLUCK! remains hidden because its chicken spawn cloud is map clutter.
- Exploration quests now show their destination on the world map and minimap. "The Jasperlode Mine" now points to both recorded mine-entry exploration locations instead of displaying no objective dots.
- Finished creature objectives now remove their own map and minimap dots while the quest remains in progress. For example, completing the Young Forest Bear objective in "Protect the Frontier" leaves only the Prowler locations.
- Rare, elite and boss pins, quest giver markers and turn-in markers now ease smoothly into and out of their enlarged hover size.
- A card and a sound now warn you when you come within 150 yards of a rare, rare elite or boss creature's known spawn, naming it, its rank, its level and how far away it is. This is proximity to a spawn point in the world data, not a live sighting: this client gives an addon no way to see the creatures around you. It covers the same creatures the NPC finder's rare-mob layer draws -- 409 curated rares and rare elites -- plus open-world bosses, and one checkbox turns the whole thing on or off. Ordinary elites are not included: they are every elite camp in the game plus parked NPCs like the level 61 Darkmoon Faire barker standing in Goldshire. /uq rare sets the range and auditions the alert sound.
- City guards, faction officers and leaders no longer appear as elites on the map: Orgrimmar alone was drawing 33 of them, Thrall and Vol'jin included. Anything the world data marks as belonging to a player faction is treated as an NPC rather than a mob, unless it is a known rare.
- The Darkmoon Faire's staff no longer appears either, so the level 61 barker standing in Goldshire stops showing up in a starter zone.
- The rare/elite alert card can be dragged anywhere on the screen by grabbing it, and stays where you put it. /uq rare reset moves it back under the top edge.
- The proximity alert now opens with "A rare creature is nearby" above the name, so it says what happened before it says who, and the distance on it counts down live as you walk instead of freezing at the value it had when it appeared.
- Hovering a rare, elite or boss pin on the map now grows it 1.5x, the same way a quest giver or turn-in marker does.
- Each rare, elite or boss is drawn once per zone instead of once per recorded spawn point: Hogger has five coordinates in Elwynn Forest and took five pins. The pin sits on whichever of his real spawns is closest to the middle of them all, and its tooltip names the creature's own classification -- Rare, Rare Elite, Elite or Boss -- rather than the name of the filter row.
- Dungeon interiors no longer show up as a crowd of elites outside the entrance. Wailing Caverns put nine elite pins on its Barrens door and Maraudon thirteen on its Desolace one: those creatures are inside the instance and reach the outdoor map only because the world data records the spawns standing in the entrance cave. An ordinary elite whose pin lands within 250 yards of a dungeon or raid entrance is no longer drawn, on the map or the minimap. Rares, rare elites and bosses still are, wherever they happen to stand.
- The NPC finder's "Rare Mobs" row is now "Rare/Elite/Boss" and shows every ranked creature in the zone, not just the 409 curated rares: elites and world bosses are drawn too, each pin wearing one of three icons for its rank.
- The dragon frames around rare, elite and boss pins are replaced by stars: a silver star for a rare, a gold one for a rare elite or elite, and a red one for a boss, so a pin's rank reads at a glance without the frame swallowing the icon underneath.
- The quest log now shows each quest's level in brackets before its name, the way the tracker window already did.
- Fixed standalone quest-log tracking marks jumping to the end of differently sized quest titles after Shift-click. UnrealQuest now owns a fixed accent on each row and restores level prefixes in the same click.
- Quests that ask you to buy something now show the traders selling it, on the world map and the minimap, with the NPC finder's vendor icon and a tooltip naming the quest, the item and your progress. The points disappear once you have the item; /uq map vendors off turns them off.
- A completed quest now takes a single green line in the tracker window: its "Ready to turn in" line and its finished objectives are no longer listed under it.
- Fixed a Lua error thrown by the client's own tracked-objectives panel ("attempt to concatenate local 'text'" in QuestLogFrame.lua) on quests whose objectives that panel cannot read. Such a quest is kept out of the client's five watch slots and still tracks normally in UnrealQuest's own tracker window.
- Translated the whole interface into French, Russian and Simplified Chinese: the settings page, the tracker, every map, minimap and NPC tooltip, the quest log buttons and all /uq output.
- French is written without accents ("quete", not the accented spelling), the way unrealUI writes it: the client's font draws accented letters as blank boxes, and no font this addon could ship changes that.
- Pick the language with the flag row in the top-right of the settings window. With unrealUI installed the language follows the one set there instead, and no second selector is shown.
- Quest markers and dots now follow the map you have open, not the zone you are standing in: open Westfall's map from Elwynn Forest and Westfall's quest points are drawn. The minimap markers and the HUD waypoint still follow your own zone, which is the only one they can measure from.
- Fixed the map and minimap showing nothing at all in Westfall, whose name is carried by two different areas in the world data.
- Use different colors for map points from different quests.
- Show a path for quest-giver NPCs with patrol waypoints.
- Add nodes such as treasures, mining nodes, rares, and more.
- Automatically track accepted quests and add them to the tracker window.
- Add icons to the NPC Finder instead of colored squares.
- Fixed accepted quests sometimes not disappearing from the map.
- Turn the "?" map marker orange when a quest is complete.
- Make map quest markers smaller and add an option to choose their size.
- Reduce the opacity of other markers when hovering over a quest on the map.
- Hovering a quest on the map now also enlarges the marker it is linked to, the same way hovering that marker does, so the point where it is handed in stands out among the markers left lit.
- Improved filtering to prevent some quests from being duplicated on the map due to the database.
- Remove arrow scrolling from the tracker windows.
- Truncate quest names when they do not fit the window now improved, no more blank space.
- Remove the limit on the number of map dots displayed.
- Quests given by NPCs from the other faction no longer display on the map.
- Fixed the limit of 5 in tracker windows; now unlimited.
- Improved world-map frame rate with many quest points on screen.
- Fixed the map showing nothing while standing inside a building, such as Brill Town Hall.
- Minimap markers are now withheld indoors, where this client gives no way to establish the map scale, instead of drifting along with the player.
- Added /uq minimap span to dial in the minimap scale for a zoom step, and /uq minimap indoors on|off.

## 0.0.2

- Added RU and CN client support.
- Added ES client support.
- Added a custom quest tracker, no longer limited to the native 5-quest watch list.
- Fixed quests not always appearing when opening the map.
- Improved quest tracking with roughly 80% fewer ambiguously flagged quests.
- Added a settings window.
- Added a UQ settings menu, standalone and unrealUI-compatible.
- Added an option to show quest objectives as an area or a point.
- Added a tooltip listing every marker when two or more collide on the map, with an option to disable it.
- Added an experimental pfQuest import for already-completed quests.
- Added an NPC tracker.
- Added trainers as trackable NPCs.
- Added trainers and waypoint patrols extracted from vMangos.

## 0.0.1

- Developed from scratch exclusively for the Unreal Azeroth / Emberveil client.
- Added a movable quest tracker window listing every quest in the log, with objectives and progress.
- Added a maximum height for the quest tracker window; a shorter log now shrinks it to fit.
- Added a live background-opacity slider for the quest tracker window.
- Fixed the quest tracker not scrolling to its last lines when limited by height.
- Fixed the client's own quest watch panel reappearing whenever a quest was tracked or untracked.
- Added Show and Track/Untrack buttons above the quest log's description pane.
- Added persistent quest tracking across interface reloads.
- Added world-map objective areas, quest-giver markers and turn-in markers.
- Added minimap pins for nearby quest objectives and quest givers.
- Added a movable HUD selector for service NPCs and objects on the world map and minimap,
  with automatic current-class filtering for class trainers.
- Added a second world-map presentation for quest objectives: one dot per target position,
  in the same style as the minimap pins, now the default. The shaded blue areas are still
  there -- pick either one in the options window, or with `/uq map dots|areas`.
- Added live quest names and objective progress to creature tooltips.
- Added detailed world-map tooltips for quests and quest givers.
- Added clustered world-map tooltips: hovering markers that sit too close together to be
  picked apart now describes every one of them in a single tooltip. Can be turned off in
  the options window.
- Added quest eligibility filtering for level, race, class and seasonal requirements.
- Added support for item-use quest objectives.
- Added optional quest-creature marks where the client permits them.
- Fixed every quest losing its map pins, minimap pins and waypoint on setups where the
  quest log hands back titles with the level prefixed to them (`[24] Weapons of Choice`),
  reported on a Russian client.
- Added an options window, opened with `/uq config` or a settings button beside the minimap.
  When unrealUI is installed the same page is drawn inside its settings window instead, and the
  button is left to unrealUI's own; both addons stay usable on their own.
- Added an import for pfQuest's completed-quest history. This client cannot report which
  quests a character already finished, so a fresh install shows a quest-giver marker for every
  quest they completed before installing the addon. pfQuest kept that record, and it can now be
  copied in: press **Import from pfQuest** under Quest history in the options window, or use
  `/uq pfquest`. `/uq pfquest undo` takes the import back without touching completions the
  addon worked out for itself.
- Made that import work for the normal case, where pfQuest has already been disabled. Its
  saved history is only in memory while it is enabled, so the button switches pfQuest on,
  asks for one `/reload`, imports by itself on the next load, and switches pfQuest back off.
  It is put back even if the import finds nothing or the history never appears.
- Fixed the quest completion record being shared by every character on the account. It is now
  stored per character, which is what a completed quest actually is. An existing record is
  inherited once by each character rather than being lost.
- Fixed the quest completion record silently refusing entries past the 250th, which a
  long-lived character reaches on their own.
- Added `/uq` commands for controls and diagnostics.
