-- UnrealQuest bundled world data.
--
-- Faction id -> name, for the reputation rewards recorded in quests.lua.
--
-- PROVENANCE, and it is weaker than every other file in this folder: these
-- names are the standard Vanilla (1.12.1) Faction.dbc names, transcribed
-- rather than extracted from the VMaNGOS/pfQuest pipeline the rest of
-- Database/ comes from. Nothing available to the addon can check them: the
-- client's whole Faction surface is indexed off the player's own reputation
-- pane (GetFactionInfo(index) walks the factions THAT character has met and
-- never reports an id), so an id cannot be resolved to a name at runtime.
--
-- Only ids that appear in quests.lua's "rep" lists are listed, and only the
-- ones whose name is not in doubt. SEVEN IDS ARE DELIBERATELY ABSENT -- 83,
-- 86, 471, 549, 550, 551 and 893, together about 25 of the ~5300 reputation
-- entries -- because a wrong faction name is worse than none: the reward line
-- falls back to showing the amount alone for an id that is not here. Fill them
-- in from a Faction.dbc dump rather than from a guess.
--
-- This is game data and is therefore not translated; see docs/LOCALIZATION.md.
-- A localized set may be added later as factions_<locale>, which
-- Data/Database.lua already prefers when present.
UnrealQuestData["factions"] = {
  [21] = "Booty Bay",
  [47] = "Ironforge",
  [54] = "Gnomeregan Exiles",
  [59] = "Thorium Brotherhood",
  [67] = "Horde",
  [68] = "Undercity",
  [69] = "Darnassus",
  [70] = "Syndicate",
  [72] = "Stormwind",
  [76] = "Orgrimmar",
  [81] = "Thunder Bluff",
  [87] = "Bloodsail Buccaneers",
  [92] = "Gelkis Clan Centaur",
  [93] = "Magram Clan Centaur",
  [169] = "Steamwheedle Cartel",
  [270] = "Zandalar Tribe",
  [349] = "Ravenholdt",
  [369] = "Gadgetzan",
  [469] = "Alliance",
  [470] = "Ratchet",
  [509] = "The League of Arathor",
  [510] = "The Defilers",
  [529] = "Argent Dawn",
  [530] = "Darkspear Trolls",
  [576] = "Timbermaw Hold",
  [577] = "Everlook",
  [589] = "Wintersaber Trainers",
  [609] = "Cenarion Circle",
  [729] = "Frostwolf Clan",
  [730] = "Stormpike Guard",
  [749] = "Hydraxian Waterlords",
  [809] = "Shen'dralar",
  [889] = "Warsong Outriders",
  [890] = "Silverwing Sentinels",
  [909] = "Darkmoon Faire",
  [910] = "Brood of Nozdormu",
}
