-- UnrealQuest bundled world data.
-- Content originates from the VMaNGOS world database and was packaged by
-- pfQuest (MIT, Eric Mauser / Shagu). Full Vanilla dataset; TBC data excluded.
-- See Database/CREDITS.md and LICENSE in the addon root.
--
-- Loads before every data file and owns the global they populate. The tables
-- are plain data: they describe the game world, never the client API.
UnrealQuestData = UnrealQuestData or {}
