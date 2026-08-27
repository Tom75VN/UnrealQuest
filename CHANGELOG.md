# Changelog

## 0.1.0

- A card and a sound now warn you when you come within 120 yards of a rare, rare elite or boss creature's known spawn, naming it, its rank, its level and how far away it is. This is proximity to a spawn point in the world data, not a live sighting: this client gives an addon no way to see the creatures around you. Ordinary elites are off by default; /uq rare turns the alert on or off, sets the range and auditions the alert sound.
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
