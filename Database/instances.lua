-- UnrealQuest dungeon and raid entrance data.
-- Source: VMaNGOS db-sqlite-6958f26, latest records valid through Vanilla 1.12.
-- Optimized: normal map coordinates are NOT duplicated here.
-- Resolve an entrance with UnrealQuestData["areatrigger"][trigger]["coords"].
-- type: 0=dungeon, 1=raid.
-- `condition` is the VMaNGOS required_condition ID when non-zero.
-- BWL uses `access_trigger` for the exterior Blackrock Spire access point.
-- AQ20 preserves raw `world` coordinates because pfQuest rejects its off-map marker.
UnrealQuestData["instances"] = {
  [33] = {
    ["name"] = "Shadowfang Keep",
    ["type"] = 0,
    ["min"] = 10,
    ["entrances"] = {
      [1] = { ["trigger"] = 145, ["patch"] = 0 },
    },
  },
  [34] = {
    ["name"] = "The Stockade",
    ["type"] = 0,
    ["min"] = 15,
    ["entrances"] = {
      [1] = { ["trigger"] = 101, ["patch"] = 0 },
    },
  },
  [36] = {
    ["name"] = "The Deadmines",
    ["type"] = 0,
    ["min"] = 10,
    ["entrances"] = {
      [1] = { ["trigger"] = 78, ["patch"] = 0 },
    },
  },
  [43] = {
    ["name"] = "Wailing Caverns",
    ["type"] = 0,
    ["min"] = 10,
    ["entrances"] = {
      [1] = { ["trigger"] = 228, ["patch"] = 0 },
    },
  },
  [47] = {
    ["name"] = "Razorfen Kraul",
    ["type"] = 0,
    ["min"] = 15,
    ["entrances"] = {
      [1] = { ["trigger"] = 244, ["patch"] = 0 },
    },
  },
  [48] = {
    ["name"] = "Blackfathom Deeps",
    ["type"] = 0,
    ["min"] = 10,
    ["entrances"] = {
      [1] = { ["trigger"] = 257, ["patch"] = 0 },
    },
  },
  [70] = {
    ["name"] = "Uldaman",
    ["type"] = 0,
    ["min"] = 30,
    ["entrances"] = {
      [1] = { ["trigger"] = 286, ["patch"] = 0, ["label"] = "Main" },
      [2] = { ["trigger"] = 902, ["patch"] = 0, ["label"] = "Back" },
    },
  },
  [90] = {
    ["name"] = "Gnomeregan",
    ["type"] = 0,
    ["min"] = 15,
    ["entrances"] = {
      [1] = { ["trigger"] = 324, ["patch"] = 0, ["label"] = "Main" },
      [2] = { ["trigger"] = 523, ["patch"] = 0, ["label"] = "Back" },
    },
  },
  [109] = {
    ["name"] = "The Temple of Atal'Hakkar",
    ["type"] = 0,
    ["min"] = 35,
    ["entrances"] = {
      [1] = { ["trigger"] = 446, ["patch"] = 0 },
    },
  },
  [129] = {
    ["name"] = "Razorfen Downs",
    ["type"] = 0,
    ["min"] = 25,
    ["entrances"] = {
      [1] = { ["trigger"] = 442, ["patch"] = 0 },
    },
  },
  [189] = {
    ["name"] = "Scarlet Monastery",
    ["type"] = 0,
    ["min"] = 20,
    ["entrances"] = {
      [1] = { ["trigger"] = 45, ["patch"] = 0, ["label"] = "Graveyard" },
      [2] = { ["trigger"] = 610, ["patch"] = 0, ["label"] = "Cathedral" },
      [3] = { ["trigger"] = 612, ["patch"] = 0, ["label"] = "Armory" },
      [4] = { ["trigger"] = 614, ["patch"] = 0, ["label"] = "Library" },
    },
  },
  [209] = {
    ["name"] = "Zul'Farrak",
    ["type"] = 0,
    ["min"] = 35,
    ["entrances"] = {
      [1] = { ["trigger"] = 924, ["patch"] = 0 },
    },
  },
  [229] = {
    ["name"] = "Blackrock Spire",
    ["type"] = 0,
    ["min"] = 45,
    ["entrances"] = {
      [1] = { ["trigger"] = 1468, ["patch"] = 0 },
    },
  },
  [230] = {
    ["name"] = "Blackrock Depths",
    ["type"] = 0,
    ["min"] = 40,
    ["entrances"] = {
      [1] = { ["trigger"] = 1466, ["patch"] = 0 },
    },
  },
  [249] = {
    ["name"] = "Onyxia's Lair",
    ["type"] = 1,
    ["min"] = 50,
    ["condition"] = 16309,
    ["entrances"] = {
      [1] = { ["trigger"] = 2848, ["patch"] = 0 },
    },
  },
  [289] = {
    ["name"] = "Scholomance",
    ["type"] = 0,
    ["min"] = 45,
    ["entrances"] = {
      [1] = { ["trigger"] = 2567, ["patch"] = 0 },
    },
  },
  [309] = {
    ["name"] = "Zul'Gurub",
    ["type"] = 1,
    ["min"] = 50,
    ["entrances"] = {
      [1] = { ["trigger"] = 3928, ["patch"] = 5 },
    },
  },
  [329] = {
    ["name"] = "Stratholme",
    ["type"] = 0,
    ["min"] = 45,
    ["entrances"] = {
      [1] = { ["trigger"] = 2214, ["patch"] = 0, ["label"] = "Back" },
      [2] = { ["trigger"] = 2216, ["patch"] = 0, ["label"] = "Right" },
      [3] = { ["trigger"] = 2217, ["patch"] = 0, ["label"] = "Left" },
    },
  },
  [349] = {
    ["name"] = "Maraudon",
    ["type"] = 0,
    ["min"] = 30,
    ["entrances"] = {
      [1] = { ["trigger"] = 3133, ["patch"] = 0, ["label"] = "Orange" },
      [2] = { ["trigger"] = 3134, ["patch"] = 0, ["label"] = "Purple" },
    },
  },
  [389] = {
    ["name"] = "Ragefire Chasm",
    ["type"] = 0,
    ["min"] = 8,
    ["entrances"] = {
      [1] = { ["trigger"] = 2230, ["patch"] = 0 },
    },
  },
  [409] = {
    ["name"] = "Molten Core",
    ["type"] = 1,
    ["min"] = 50,
    ["condition"] = 7850,
    ["internal_trigger"] = 2886,
    ["entrances"] = {
      [1] = { ["trigger"] = 3528, ["patch"] = 1 },
    },
  },
  [429] = {
    ["name"] = "Dire Maul",
    ["type"] = 0,
    ["min"] = 45,
    ["entrances"] = {
      [1] = { ["trigger"] = 3183, ["patch"] = 1, ["label"] = "Entrance 1" },
      [2] = { ["trigger"] = 3184, ["patch"] = 1, ["label"] = "Entrance 2" },
      [3] = { ["trigger"] = 3185, ["patch"] = 1, ["label"] = "Entrance 3" },
      [4] = { ["trigger"] = 3186, ["patch"] = 1, ["label"] = "Entrance 4" },
      [5] = { ["trigger"] = 3187, ["patch"] = 1, ["label"] = "Entrance 5" },
      [6] = { ["trigger"] = 3189, ["patch"] = 1, ["label"] = "Entrance 6" },
    },
  },
  [469] = {
    ["name"] = "Blackwing Lair",
    ["type"] = 1,
    ["min"] = 50,
    ["access_trigger"] = 1468,
    ["entrances"] = {
      [1] = { ["trigger"] = 3726, ["patch"] = 4 },
    },
  },
  [509] = {
    ["name"] = "Ruins of Ahn'Qiraj",
    ["type"] = 1,
    ["min"] = 50,
    ["condition"] = 126,
    ["world"] = { 1, -8424.94000, 1508.65000, 32.01420 },
    ["entrances"] = {
      [1] = { ["trigger"] = 4008, ["patch"] = 7 },
    },
  },
  [531] = {
    ["name"] = "Temple of Ahn'Qiraj",
    ["type"] = 1,
    ["min"] = 50,
    ["condition"] = 126,
    ["entrances"] = {
      [1] = { ["trigger"] = 4010, ["patch"] = 7 },
    },
  },
  [533] = {
    ["name"] = "Naxxramas",
    ["type"] = 1,
    ["min"] = 51,
    ["condition"] = 9124,
    ["entrances"] = {
      [1] = { ["trigger"] = 4055, ["patch"] = 9 },
    },
  },
}
