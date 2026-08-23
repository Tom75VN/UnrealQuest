# Changelog

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
