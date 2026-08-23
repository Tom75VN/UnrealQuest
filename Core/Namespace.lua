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
UQ.version = "0.0.2"

-- Keep UnrealQuest visually aligned with UnrealUI without creating a runtime
-- dependency between the two addons. These values mirror UnrealUI's shared
-- chrome accent token (#f5ae0a / 0.96, 0.68, 0.04).
UQ.colors = {
    accentHex = "f5ae0a",
    accent = { 0.96, 0.68, 0.04, 1.00 },
}

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

UQ:DeclareFeature("mainQuestWaypoint", false,
    "the follow-one-quest layer: main quest selection, its quest log and tracker click surfaces, the "
    .. "world marker, the movement heading estimator and the brighter main-quest tiles on the world "
    .. "map. Disabled 2026-08-22 because the marker cannot be made accurate on this client -- there is "
    .. "no readable player facing and no camera getter of any kind (input.no_readable_player_facing, "
    .. "BEHAVIOR_VERIFIED). The code is kept and stays under offline test; see docs/HUD-WAYPOINT.md")

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
