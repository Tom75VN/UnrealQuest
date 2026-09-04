--[[
UnrealQuest / Core/Namespace.lua

Addon namespace, module registry and logging.

Dialect note: this addon is written in the conservative Vanilla Lua subset
(table.getn, string.gfind, table.insert, no `#`, no `select`, no `gmatch`).
The client documentation describes the environment as "Lua 5.1-compatible",
but that is DOCUMENTED_NOT_RUNTIME_VERIFIED, whereas the conservative subset is
demonstrably running on this client in UnrealRuntimeProbe. Do not widen the
dialect without runtime evidence.

Frame naming note: the client replaces every "-" in a widget name with a filler
string, so UnrealQuest widget names must never contain a hyphen.
]]

UnrealQuest = {}

local UQ = UnrealQuest

UQ.name = "UnrealQuest"
UQ.version = "0.3.2"

-- Keep UnrealQuest visually aligned with UnrealUI without creating a runtime
-- dependency between the two addons. These values mirror UnrealUI's shared
-- chrome accent token (#f5ae0a / 0.96, 0.68, 0.04).
UQ.colors = {
    accentHex = "f5ae0a",
    accent = { 0.96, 0.68, 0.04, 1.00 },
}

-- Quest colours -------------------------------------------------------------
-- One colour per quest, shared by every objective-dot surface (world map,
-- minimap, HUD) and by the tracker swatch beside the quest name.
--
-- The point of the colour is telling two dots apart at a glance, so the
-- palette is not a hand-picked list of pretty colours and the assignment is
-- not a hash: a hash produces collisions -- two quests on screen wearing the
-- same colour -- long before the palette runs out.
--
-- Palette: 20 colours (the largest quest log this client allows) chosen by
-- farthest-point sampling in OKLab over the sRGB colours bright enough to
-- read as a small dot (HSV s >= 0.6, v >= 0.78, OKLab L >= 0.60), seeded on
-- the sky blue this addon has always used first. Farthest-point ordering is
-- prefix-optimal: for any count k the first k entries are the k that stay
-- furthest apart, so the fewer quests are on screen the more separated their
-- colours are. Measured minimum pairwise OKLab distance is 0.34 at 4 quests,
-- 0.19 at 8, 0.13 at 12 and 0.11 at 20 -- against 0.018 for a plain
-- evenly-spaced hue wheel, which is below the just-noticeable difference.
--
-- Each row is r, g, b followed by that colour's OKLab L, a, b. The OKLab
-- coordinates are baked in rather than computed at load because the runtime
-- allocator below compares distances on every new quest and the cube roots
-- have no business running on this client.
UQ.questColors = {
    { 0.133, 0.740, 1.000, 0.7525, -0.0886, -0.1222 }, -- #22BDFF sky
    { 1.000, 0.000, 0.000, 0.6280,  0.2249,  0.1258 }, -- #FF0000 red
    { 1.000, 1.000, 0.000, 0.9680, -0.0714,  0.1986 }, -- #FFFF00 yellow
    { 0.800, 0.000, 1.000, 0.6273,  0.2221, -0.2116 }, -- #CC00FF violet
    { 0.000, 0.780, 0.338, 0.7240, -0.1753,  0.1056 }, -- #00C756 green
    { 0.853, 0.631, 0.341, 0.7479,  0.0351,  0.1077 }, -- #DAA157 sand
    { 0.420, 0.400, 1.000, 0.6016,  0.0343, -0.2176 }, -- #6B66FF blue
    { 1.000, 0.400, 0.740, 0.7279,  0.2014, -0.0416 }, -- #FF66BD pink
    { 0.400, 1.000, 0.880, 0.9101, -0.1369,  0.0060 }, -- #66FFE0 ice
    { 0.400, 1.000, 0.000, 0.8815, -0.2060,  0.1823 }, -- #66FF00 lime
    { 0.780, 0.390, 0.312, 0.6154,  0.1105,  0.0708 }, -- #C76350 brick
    { 0.728, 0.780, 0.000, 0.7920, -0.0742,  0.1626 }, -- #BAC700 olive
    { 0.312, 0.530, 0.780, 0.6141, -0.0334, -0.1088 }, -- #5087C7 steel
    { 0.312, 0.780, 0.702, 0.7566, -0.1107, -0.0006 }, -- #50C7B3 teal
    { 0.853, 0.000, 0.711, 0.6022,  0.2449, -0.0984 }, -- #DA00B5 magenta
    { 1.000, 0.820, 0.400, 0.8805,  0.0091,  0.1345 }, -- #FFD166 amber
    { 0.649, 0.341, 0.853, 0.6072,  0.1257, -0.1531 }, -- #A557DA purple
    { 0.853, 0.228, 0.478, 0.6039,  0.2007,  0.0040 }, -- #DA3A7A rose
    { 0.920, 0.400, 1.000, 0.7306,  0.1903, -0.1480 }, -- #EB66FF orchid
    { 1.000, 0.433, 0.000, 0.7069,  0.1367,  0.1430 }, -- #FF6F00 orange
}

-- Lightness counts a little less than chroma: on a six-pixel dot a hue step
-- reads faster than a brightness step does. The same weight produced the
-- palette above, so runtime and generator agree on what "far apart" means.
local COLOR_LIGHTNESS_WEIGHT = 0.8

-- titleKey -> palette slot, and the reverse. A quest keeps its slot for as
-- long as it is in the log, so its colour never moves under the player; the
-- slot returns to the pool when the quest leaves (see UQ.ReleaseQuestColor).
local questColorSlot = {}
local questColorOwner = {}

-- The assignment outlives the session. Without this the palette is re-dealt
-- from scratch on every login and a quest the player has been following for
-- days changes colour under them after a /reload -- which is exactly the one
-- thing the allocator above is built to prevent while the session lasts.
--
-- What is stored is the SLOT NUMBER, never the r,g,b triple: the palette is
-- code and the assignment is state, so editing a colour here must repaint the
-- quests that hold it rather than resurrect the old value out of a saved file.
--
-- The section holds live assignments only. ReleaseQuestColor drops a quest's
-- entry as it leaves the log, and PruneQuestColors drops whatever a complete
-- log scan no longer knows about, so the file stays the size of the quest log
-- instead of growing with every quest the character has ever carried.
local COLOR_SECTION = "questColorSlots"
-- The section table this seeded from, not a bare "done" flag: Config rebuilds
-- the store into a fresh table every time it initialises, so comparing the
-- table itself re-seeds from a store that was replaced underneath and skips
-- the walk on every call that follows.
local colorStoreSeeded = nil

-- Config is a module like any other and may not have run its OnInit yet when
-- an early caller asks for a colour, so this is resolved per call and simply
-- answers nil until the store exists. Nothing here is required for correct
-- colours -- persistence is an accelerator over an allocator that already
-- works from an empty table.
local function QuestColorSection()
    local config = UQ.modules and UQ.modules.Config
    if not config or not config.GetSection then
        return nil, nil
    end
    local section = config:GetSection(COLOR_SECTION)
    if not section then
        return nil, nil
    end
    return section, config
end

-- Seeds the two runtime tables from the saved section, once, on the first
-- colour request that finds a store. A saved slot is ignored when it is out of
-- range or already taken (a hand-edited or half-written file): the quest then
-- allocates a fresh slot and overwrites its entry, rather than two quests
-- sharing one colour.
local function LoadQuestColors()
    local section = QuestColorSection()
    if not section or section == colorStoreSeeded then
        return
    end
    colorStoreSeeded = section
    local total = table.getn(UQ.questColors)
    for key, slot in pairs(section) do
        if type(key) == "string" and key ~= ""
            and type(slot) == "number"
            and slot == math.floor(slot)
            and slot >= 1 and slot <= total
            and not questColorSlot[key] and not questColorOwner[slot] then
            questColorSlot[key] = slot
            questColorOwner[slot] = key
        end
    end
end

local function RememberQuestColor(key, slot)
    local section, config = QuestColorSection()
    if not section then
        return
    end
    config:SetSectionEntry(COLOR_SECTION, key, slot)
end

local function ForgetQuestColor(key)
    local section, config = QuestColorSection()
    if not section then
        return
    end
    config:SetSectionEntry(COLOR_SECTION, key, nil)
end

local function ColorDistanceSquared(first, second)
    local lightness = (first[4] - second[4]) * COLOR_LIGHTNESS_WEIGHT
    local greenRed = first[5] - second[5]
    local blueYellow = first[6] - second[6]
    return lightness * lightness + greenRed * greenRed + blueYellow * blueYellow
end

-- Picks the free slot that sits furthest from every slot currently in use --
-- the same greedy rule that ordered the palette, replayed against whatever
-- holes earlier turn-ins left behind. On an empty board it walks the palette
-- in order, so a fresh set of N quests gets exactly the prefix-optimal N.
local function AllocateQuestColorSlot()
    local total = table.getn(UQ.questColors)
    local bestSlot = nil
    local bestDistance = nil
    local slot = 1
    while slot <= total do
        if not questColorOwner[slot] then
            local nearest = nil
            local other = 1
            while other <= total do
                if questColorOwner[other] then
                    local distance = ColorDistanceSquared(
                        UQ.questColors[slot], UQ.questColors[other])
                    if not nearest or distance < nearest then
                        nearest = distance
                    end
                end
                other = other + 1
            end
            if not nearest then
                -- Nothing is in use: the palette's own order is the answer.
                return slot
            end
            if not bestDistance or nearest > bestDistance then
                bestSlot = slot
                bestDistance = nearest
            end
        end
        slot = slot + 1
    end
    return bestSlot
end

-- Only reached when every slot is taken, which needs more live quests than
-- the palette has colours. A hash keeps the duplicate at least stable.
local function HashSlot(key)
    -- djb2 reduced on every byte so the arithmetic stays exact in Lua's
    -- number type even for a long UTF-8 quest title.
    local hash = 5381
    local index = 1
    local length = string.len(key)
    while index <= length do
        hash = (hash * 33 + string.byte(key, index)) % 2147483647
        index = index + 1
    end
    return (hash % table.getn(UQ.questColors)) + 1
end

function UQ.GetQuestColor(questOrKey)
    local key = questOrKey
    if type(questOrKey) == "table" then
        key = questOrKey.titleKey or questOrKey.title
    end
    local color
    if type(key) ~= "string" or key == "" then
        color = UQ.questColors[1]
        return color[1], color[2], color[3]
    end

    LoadQuestColors()

    local slot = questColorSlot[key]
    if not slot then
        slot = AllocateQuestColorSlot()
        if slot then
            questColorOwner[slot] = key
            RememberQuestColor(key, slot)
        else
            -- The palette is exhausted, so this slot is shared and derived
            -- rather than owned. It is reproduced from the title on every
            -- login already, and saving it would claim an owner the allocator
            -- must be free to hand to a real quest later.
            slot = HashSlot(key)
        end
        questColorSlot[key] = slot
    end
    color = UQ.questColors[slot]
    return color[1], color[2], color[3]
end

-- Called when a quest leaves the log. Returning the slot is what keeps the
-- colours on screen spread out over a whole play session instead of drifting
-- into whatever the palette's tail happens to hold.
function UQ.ReleaseQuestColor(questOrKey)
    local key = questOrKey
    if type(questOrKey) == "table" then
        key = questOrKey.titleKey or questOrKey.title
    end
    if type(key) ~= "string" or key == "" then
        return
    end
    -- Unconditionally, and before the in-memory check: a saved entry can
    -- outlive its runtime slot (a duplicate the loader refused to seed), and
    -- that is precisely the entry a prune has to be able to clear.
    ForgetQuestColor(key)
    local slot = questColorSlot[key]
    if not slot then
        return
    end
    questColorSlot[key] = nil
    if questColorOwner[slot] == key then
        questColorOwner[slot] = nil
    end
end

-- Drops every remembered assignment the quest log no longer contains.
--
-- ReleaseQuestColor already handles a quest leaving while the addon watches,
-- so this only catches what changed while it was not: quests abandoned or
-- turned in under a previous build, or with the addon disabled. The caller
-- must pass the live set from a COMPLETE log scan -- a partial scan would read
-- collapsed headers as an empty log and free every colour on screen.
function UQ.PruneQuestColors(liveKeys)
    if type(liveKeys) ~= "table" then
        return
    end
    LoadQuestColors()
    local stale = {}
    for key in pairs(questColorSlot) do
        if not liveKeys[key] then
            table.insert(stale, key)
        end
    end
    local section = QuestColorSection()
    if section then
        for key in pairs(section) do
            if type(key) == "string" and not liveKeys[key]
                and not questColorSlot[key] then
                table.insert(stale, key)
            end
        end
    end
    local index = 1
    local total = table.getn(stale)
    while index <= total do
        UQ.ReleaseQuestColor(stale[index])
        index = index + 1
    end
end

-- Module registry -----------------------------------------------------------
-- Modules are plain tables with optional OnInit and OnEnable methods.
-- OnInit runs once the addon file set has loaded; OnEnable runs after the
-- player is in the world (or immediately, if that point already passed).

UQ.modules = {}
UQ.moduleOrder = {}

function UQ:NewModule(name)
    if self.modules[name] then
        return self.modules[name]
    end
    local module = {}
    module.name = name
    module.enabled = false
    self.modules[name] = module
    table.insert(self.moduleOrder, name)
    return module
end

function UQ:GetModule(name)
    return self.modules[name]
end

function UQ:ForEachModule(callback)
    local index = 1
    local total = table.getn(self.moduleOrder)
    while index <= total do
        local module = self.modules[self.moduleOrder[index]]
        if module then
            callback(module)
        end
        index = index + 1
    end
end

-- Capability registry -------------------------------------------------------
-- Every runtime capability UnrealQuest depends on is declared here by the
-- compatibility layer with an honest state, so /uq status can report what the
-- addon actually established on this client rather than what it assumed.
--
-- state values:
--   "verified"     backed by measured runtime evidence in the compact DB
--   "documented"   present in the client's own API reference, not runtime-probed
--   "detected"     the symbol/frame was found to exist at load time
--   "missing"      looked for at load time and not found
--   "unverified"   needed, but neither probed nor detectable at load time

UQ.capabilities = {}
UQ.capabilityOrder = {}

function UQ:DeclareCapability(key, state, note)
    if not self.capabilities[key] then
        table.insert(self.capabilityOrder, key)
    end
    self.capabilities[key] = { state = state, note = note }
end

function UQ:GetCapability(key)
    local capability = self.capabilities[key]
    if not capability then
        return nil
    end
    return capability.state, capability.note
end

function UQ:HasCapability(key)
    local capability = self.capabilities[key]
    if not capability then
        return false
    end
    return capability.state == "verified"
        or capability.state == "documented"
        or capability.state == "detected"
end

-- Feature gates -------------------------------------------------------------
-- A feature gate switches a whole layer of the addon off at the source, before
-- anything that layer owns is registered.
--
-- It is deliberately NOT a setting. There is no SavedVariables entry and no
-- slash command to flip it, because a layer that was disabled for a
-- correctness reason must not be able to come back on by accident.
--
-- A gated layer keeps its files, its module tables and all of its logic, so
-- nothing is lost and re-enabling it is one boolean. What it must not keep is
-- runtime cost. A gate is therefore checked inside OnInit/OnEnable -- before
-- any driver job is scheduled, before any event is registered, and above all
-- before any native script is chained. That last one is not a style
-- preference: SetScript(type, nil) does not detach a script on this client, so
-- a chain installed once can never be removed, and a gate checked after
-- installation would be no gate at all.
--
-- The offline test in tools/smoke.py turns a disabled layer back on and
-- exercises it, so gated code stays covered and cannot rot while it waits.

UQ.features = {}
UQ.featureOrder = {}

function UQ:DeclareFeature(key, enabled, note)
    if not self.features[key] then
        table.insert(self.featureOrder, key)
    end
    self.features[key] = { enabled = (enabled and true or false), note = note }
end

-- An unknown key reports ENABLED. A typo in a gate check should leave a
-- working layer working; silently switching one off would be the worse of the
-- two failures, and the harder to notice.
function UQ:IsFeatureEnabled(key)
    local feature = self.features[key]
    if not feature then
        return true
    end
    return feature.enabled
end

UQ:DeclareFeature("hudWorldMarker", false,
    "the screen-space marker that projects the followed quest's position onto the 3D world "
    .. "(HUD/Waypoint.lua). Disabled 2026-09-01 and replaced by the navigator, because only HALF of "
    .. "that projection can be built on this client and the missing half is not the half that was "
    .. "missing before. The yaw half works now that GetPlayerFacing exists. The vertical half cannot "
    .. "be built at all, for two independent reasons: there is no camera pitch, position or FOV getter "
    .. "(cameraProjection is `missing`), and the bundled world data carries no Z at all -- "
    .. "units[id].coords entries are {x%, y%, areaId, respawn}, so even a complete camera API would "
    .. "have no target elevation to project. A marker that is right horizontally and fixed on a "
    .. "horizon band vertically reads as broken rather than as partial. The code is kept and stays "
    .. "under offline test; re-enable it when the client publishes a camera getter. See "
    .. "docs/HUD-WAYPOINT.md")

UQ:DeclareFeature("mainQuestWaypoint", true,
    "the follow-one-quest layer: main quest selection, its quest log and tracker click surfaces, the "
    .. "navigator, the facing reader with its movement fallback and the brighter main-quest tiles on "
    .. "the world map. Disabled 2026-08-22 because nothing could be aimed without a readable player "
    .. "facing; re-enabled 2026-09-01 because the updated client documents GetPlayerFacing() as "
    .. "returning character rotation in radians, which is exactly the input that was missing. What "
    .. "the layer SHOWS changed with it: the projected world marker is gated off separately "
    .. "(hudWorldMarker) and the arc-and-arrow navigator took its place, because a bearing relative "
    .. "to the player is the whole of what this client can support. The remaining limit is the "
    .. "camera, not the character: there is still no camera getter, so a free-look player sees a "
    .. "direction anchored to where the CHARACTER faces. See docs/HUD-NAVIGATOR.md")

-- Logging -------------------------------------------------------------------

UQ.debug = false

local function Output(text)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(text)
    end
end

local ADDON_PREFIX = "|cff" .. UQ.colors.accentHex .. "UnrealQuest|r"

function UQ:Print(text)
    Output(ADDON_PREFIX .. ": " .. tostring(text))
end

function UQ:Debug(text)
    if self.debug then
        Output(ADDON_PREFIX .. " |cff888888debug|r: " .. tostring(text))
    end
end

function UQ:Warn(text)
    Output(ADDON_PREFIX .. " |cffff6666warning|r: " .. tostring(text))
end

-- Small shared helpers ------------------------------------------------------

function UQ.Trim(text)
    if type(text) ~= "string" then
        return nil
    end
    return string.gsub(string.gsub(text, "^%s+", ""), "%s+$", "")
end

-- Normalizes a quest/NPC/zone name into a comparison key. Quest titles are the
-- only join between the client's quest log and the static database, so the key
-- has to survive punctuation and spacing differences between the two sources.
--
-- Deliberately does not use string.lower or the %a/%d/%u pattern classes.
-- Those are backed by the C library's locale-dependent ctype functions, and
-- were confirmed (via a Lua runtime under a non-C locale) to reclassify and
-- corrupt UTF-8 continuation bytes -- string.lower("Кобольдов") came back as
-- invalid UTF-8, silently mangling the key for every Cyrillic, CJK or other
-- non-Latin title. Walking the string one byte at a time and folding only the
-- ASCII range (65-90) by hand is locale-independent: any byte >= 128, i.e.
-- every byte of a multi-byte UTF-8 character, is passed through unchanged and
-- untouched, while ASCII letters/digits keep the exact old behaviour.
function UQ.NameKey(text)
    if type(text) ~= "string" then
        return nil
    end
    local length = string.len(text)
    local parts = {}
    local count = 0
    local index = 1
    while index <= length do
        local byte = string.byte(text, index)
        if byte >= 65 and byte <= 90 then
            count = count + 1
            parts[count] = string.char(byte + 32)
        elseif (byte >= 97 and byte <= 122) or (byte >= 48 and byte <= 57) or byte >= 128 then
            count = count + 1
            parts[count] = string.char(byte)
        end
        index = index + 1
    end
    if count == 0 then
        return nil
    end
    return table.concat(parts)
end

function UQ.Count(list)
    if type(list) ~= "table" then
        return 0
    end
    return table.getn(list)
end
