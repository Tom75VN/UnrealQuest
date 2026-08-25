--[[
UnrealQuest / Data/NodeIcons.lua

Per-node map icons: the object ID of a herb or a mining vein to the artwork
that draws it, so a Peacebloom pin looks like a Peacebloom and not like the
generic category icon.

The artwork and the object-to-artwork assignment both come from pfQuest
(MIT, Eric Mauser / Shagu), whose icons.lua names one anchor object per node
type and resolves the rest by localized name at runtime. That resolution is
done here at build time instead: every object ID in the bundled herbs and
mines relations that shares an anchor's name is listed outright, so the
lookup is a table read with no locale dependency. All four Copper Vein
object IDs therefore appear, not just pfQuest's anchor 1731.

Five Vanilla mining objects have no pfQuest artwork -- Incendicite,
Indurium and the two Obsidian Chunks -- and are deliberately absent; they
fall back to the category icon, exactly as they do in pfQuest.

Regenerate rather than hand-edit: the entries below are derived from
pfQuest's icons.lua, Database/meta.lua and Database/enUS/objects.lua.
]]

local UQ = UnrealQuest

-- category -> object ID -> file name under media/icons/<category>/
UQ.nodeIcons = {
    ["herbs"] = {
        [1617] = "Silverleaf", -- Silverleaf
        [1618] = "Peacebloom", -- Peacebloom
        [1619] = "Earthroot", -- Earthroot
        [1620] = "Mageroyal", -- Mageroyal
        [1621] = "Briarthorn", -- Briarthorn
        [1622] = "Bruiseweed", -- Bruiseweed
        [1623] = "WildSteelbloom", -- Wild Steelbloom
        [1624] = "Kingsblood", -- Kingsblood
        [1628] = "GraveMoss", -- Grave Moss
        [2041] = "Liferoot", -- Liferoot
        [2042] = "Fadeleaf", -- Fadeleaf
        [2043] = "KhadgarsWhisker", -- Khadgar's Whisker
        [2044] = "Wintersbite", -- Wintersbite
        [2045] = "Stranglekelp", -- Stranglekelp
        [2046] = "Goldthorn", -- Goldthorn
        [2866] = "Firebloom", -- Firebloom
        [3724] = "Peacebloom", -- Peacebloom
        [3725] = "Silverleaf", -- Silverleaf
        [3726] = "Earthroot", -- Earthroot
        [3727] = "Mageroyal", -- Mageroyal
        [3729] = "Briarthorn", -- Briarthorn
        [3730] = "Bruiseweed", -- Bruiseweed
        [142140] = "PurpleLotus", -- Purple Lotus
        [142141] = "ArthasTears", -- Arthas' Tears
        [142142] = "Sungrass", -- Sungrass
        [142143] = "Blindweed", -- Blindweed
        [142144] = "GhostMushroom", -- Ghost Mushroom
        [142145] = "Gromsblood", -- Gromsblood
        [176583] = "GoldenSansam", -- Golden Sansam
        [176584] = "Dreamfoil", -- Dreamfoil
        [176586] = "MountainSilversage", -- Mountain Silversage
        [176587] = "Plaguebloom", -- Plaguebloom
        [176588] = "Icecap", -- Icecap
        [176589] = "BlackLotus", -- Black Lotus
        [176636] = "Sungrass", -- Sungrass
        [176637] = "Gromsblood", -- Gromsblood
        [176638] = "GoldenSansam", -- Golden Sansam
        [176639] = "Dreamfoil", -- Dreamfoil
        [176640] = "MountainSilversage", -- Mountain Silversage
        [176641] = "Plaguebloom", -- Plaguebloom
        [176642] = "ArthasTears", -- Arthas' Tears
        [180164] = "Sungrass", -- Sungrass
        [180165] = "PurpleLotus", -- Purple Lotus
        [180166] = "MountainSilversage", -- Mountain Silversage
        [180167] = "GoldenSansam", -- Golden Sansam
        [180168] = "Dreamfoil", -- Dreamfoil
    },
    ["mines"] = {
        [324] = "Thorium", -- Small Thorium Vein
        [1731] = "Copper", -- Copper Vein
        [1732] = "Tin", -- Tin Vein
        [1733] = "Silver", -- Silver Vein
        [1734] = "Gold", -- Gold Vein
        [1735] = "Iron", -- Iron Deposit
        [2040] = "Mithril", -- Mithril Deposit
        [2047] = "TrueSilver", -- Truesilver Deposit
        [2054] = "Tin", -- Tin Vein
        [2055] = "Copper", -- Copper Vein
        [2653] = "LesserBloodstone", -- Lesser Bloodstone Deposit
        [3763] = "Copper", -- Copper Vein
        [3764] = "Tin", -- Tin Vein
        [73940] = "Silver", -- Ooze Covered Silver Vein
        [73941] = "Gold", -- Ooze Covered Gold Vein
        [103711] = "Tin", -- Tin Vein
        [103713] = "Copper", -- Copper Vein
        [105569] = "Silver", -- Silver Vein
        [123309] = "TrueSilver", -- Ooze Covered Truesilver Deposit
        [123310] = "Mithril", -- Ooze Covered Mithril Deposit
        [123848] = "Thorium", -- Ooze Covered Thorium Vein
        [150079] = "Mithril", -- Mithril Deposit
        [150080] = "Gold", -- Gold Vein
        [150081] = "TrueSilver", -- Truesilver Deposit
        [150082] = "Thorium", -- Small Thorium Vein
        [165658] = "DarkIron", -- Dark Iron Deposit
        [175404] = "RichThorium", -- Rich Thorium Vein
        [176643] = "Thorium", -- Small Thorium Vein
        [176645] = "Mithril", -- Mithril Deposit
        [177388] = "RichThorium", -- Ooze Covered Rich Thorium Vein
        [180215] = "Thorium", -- Hakkari Thorium Vein
        [181108] = "TrueSilver", -- Truesilver Deposit
        [181109] = "Gold", -- Gold Vein
    },
}
