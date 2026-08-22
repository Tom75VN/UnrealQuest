"""Offline smoke test for UnrealQuest v0.0.1.

Loads the real addon files, bundled world data included, into a Lua runtime
with a mocked Vanilla-shaped client API, drives the bootstrap, and asserts the
module wiring works end to end. This is a wiring/logic check only; it proves
nothing about the actual client and is not runtime evidence.
"""
import lupa, os, sys

ADDONS = r"C:\Games\Azeroth Launcher\Azeroth\Binaries\Win64\Games\Emberveil\live\Azeroth\Interface\AddOns"

rt = lupa.LuaRuntime(unpack_returned_tuples=True)
G = rt.globals()

PRELUDE = r"""
-- Vanilla-era shims the modern host runtime no longer provides.
table.getn = function(t) local n = 0; for _ in ipairs(t) do n = n + 1 end; return n end
if not string.gfind then string.gfind = string.gmatch end
-- Vanilla has unpack as a global; newer Lua moved it to table.unpack. The addon
-- never calls it, but frameMeta:GetChildren below does -- a real client returns
-- a frame's children as a vararg.
if not unpack then unpack = table.unpack end

_ENV = _ENV or _G
local env = _G

function getglobal(name) return env[name] end
function setglobal(name, value) env[name] = value end

SlashCmdList = {}

local messages = {}
UQ_TEST_MESSAGES = messages
DEFAULT_CHAT_FRAME = { AddMessage = function(self, text) messages[#messages+1] = text end }

-- Frames -------------------------------------------------------------------
local frames = {}
UQ_TEST_FRAMES = frames

local frameMeta = {}
frameMeta.__index = frameMeta

function frameMeta:SetScript(kind, handler) self.scripts[kind] = handler end
function frameMeta:GetScript(kind) return self.scripts[kind] end
function frameMeta:SetWidth(value) self.width = value end
function frameMeta:SetHeight(value) self.height = value end
function frameMeta:GetWidth() return self.width or 0 end
function frameMeta:GetHeight() return self.height or 0 end
function frameMeta:GetObjectType() return self.frameType end
function frameMeta:GetParent() return self.parent end
function frameMeta:GetFrameLevel() return self.frameLevel or 0 end
function frameMeta:SetFrameLevel(value) self.frameLevel = value end
function frameMeta:GetAlpha() return self.alpha or 1 end
function frameMeta:GetLeft() return self.point and self.point[4] or 0 end
function frameMeta:GetTop() return self.point and -self.point[5] or 0 end
function frameMeta:IsShown() return self.shown and true or false end
function frameMeta:IsVisible()
    if not self.shown then return false end
    if self.parent and self.parent.IsVisible then return self.parent:IsVisible() end
    return true
end
function frameMeta:Show() self.shown = true end
function frameMeta:Hide() self.shown = false end
function frameMeta:EnableMouse(enable) self.mouseEnabled = enable end
function frameMeta:RegisterForClicks(a, b, c, d)
    self.clickTokens = self.clickTokens or {}
    for _, token in ipairs({a, b, c, d}) do table.insert(self.clickTokens, token) end
end
function frameMeta:ClearAllPoints() self.point = nil end
function frameMeta:SetFrameStrata(value) self.strata = value end
function frameMeta:GetFrameStrata() return self.strata end
function frameMeta:SetAlpha(value) self.alpha = value end
function frameMeta:SetID(value) self.id = value end
function frameMeta:GetID() return self.id or 0 end
function frameMeta:SetText(value) self.text = value end
function frameMeta:GetText() return self.text end
function frameMeta:GetChildren() return unpack(self.children or {}) end
function frameMeta:GetNumChildren() return table.getn(self.children or {}) end
function frameMeta:GetName() return self.name end
-- Regions are the FontStrings and Textures a frame draws itself, returned as
-- varargs. The real client's GetNumRegions is recorded as always answering 0,
-- so the mock offers no count either -- nothing may come to depend on one.
function frameMeta:GetRegions() return unpack(self.regions or {}) end
function frameMeta:IsObjectType(name) return self.frameType == name end
function frameMeta:SetPoint(point, relative, relativePoint, x, y)
    self.point = { point, relative, relativePoint, x, y }
end
local textureMeta = {}
textureMeta.__index = textureMeta
function textureMeta:SetAllPoints(frame) self.allPoints = frame end
function textureMeta:SetPoint(point, relative, relativePoint, x, y)
    self.points = self.points or {}
    self.points[#self.points+1] = { point, relative, relativePoint, x, y }
    self.allPoints = relative
end
function textureMeta:SetWidth(value) self.width = value end
function textureMeta:SetHeight(value) self.height = value end
function textureMeta:GetDrawLayer() return self.layer end
function textureMeta:GetAlpha() return self.alpha or 1 end
function textureMeta:SetAlpha(value) self.alpha = value end
function textureMeta:IsShown() return true end
function textureMeta:IsVisible() return self.allPoints and self.allPoints:IsVisible() or false end
function textureMeta:GetTexture() return self.path end
function textureMeta:GetObjectType() return "Texture" end
function textureMeta:SetTexture(red, green, blue, alpha)
    if type(red) == 'string' then self.path = red else self.path = nil end
    self.color = { red, green, blue, alpha }
end
function textureMeta:SetVertexColor(red, green, blue, alpha)
    self.vertex = { red, green, blue, alpha }
end
-- Documented on this client as returning true. UQ_TEST_DESATURATE_OK models a
-- client that has the method but refuses the effect, which the pin layer has
-- to fall back from rather than trust.
UQ_TEST_DESATURATE_OK = true
function textureMeta:SetDesaturated(value)
    if not UQ_TEST_DESATURATE_OK then return false end
    self.desaturated = value and true or false
    return true
end
function frameMeta:CreateTexture(name, layer)
    local texture = setmetatable({ name = name, layer = layer }, textureMeta)
    self.texture = texture
    self.regions = self.regions or {}
    self.regions[#self.regions+1] = texture
    return texture
end
local fontStringMeta = {}
fontStringMeta.__index = fontStringMeta
function fontStringMeta:SetAllPoints(frame) self.allPoints = frame end
function fontStringMeta:SetJustifyH(value) self.justifyH = value end
function fontStringMeta:SetJustifyV(value) self.justifyV = value end
function fontStringMeta:SetTextColor(red, green, blue) self.color = { red, green, blue } end
function fontStringMeta:SetText(value) self.text = value end
function fontStringMeta:GetText() return self.text end
function fontStringMeta:SetFontObject(value) self.fontObject = value end
function fontStringMeta:SetPoint(point, relative, relativePoint, x, y)
    self.point = { point, relative, relativePoint, x, y }
end
function fontStringMeta:Show() self.shown = true end
function fontStringMeta:Hide() self.shown = false end
function fontStringMeta:IsShown() return self.shown ~= false end
function fontStringMeta:GetWidth() return self.width or 120 end
function fontStringMeta:GetHeight() return self.height or 12 end
function fontStringMeta:GetObjectType() return "FontString" end
function frameMeta:CreateFontString(name, layer, inherits)
    local label = setmetatable({ name = name, layer = layer, inherits = inherits }, fontStringMeta)
    self.fontString = label
    self.regions = self.regions or {}
    self.regions[#self.regions+1] = label
    return label
end
function frameMeta:RegisterEvent(event)
    if UQ_TEST_KNOWN_EVENTS[event] then
        self.events[event] = true
        return
    end
    error("Unknown event: " .. tostring(event))
end
function frameMeta:UnregisterEvent(event) self.events[event] = nil end

UQ_TEST_KNOWN_EVENTS = {
    PLAYER_ENTERING_WORLD = true,
    VARIABLES_LOADED = true,
    BAG_UPDATE = true,
    PLAYER_LEVEL_UP = true,
    -- Deliberately absent: every QUEST_* name, mirroring a client where no
    -- quest event is verified to exist.
}

function CreateFrame(kind, name, parent)
    local frame = setmetatable({ frameType = kind, name = name, parent = parent,
                                 scripts = {}, events = {}, shown = true,
                                 children = {}, regions = {} }, frameMeta)
    -- Only a real status bar answers GetValue, so the inventory's "bars=" count
    -- means something. Handing it to every frame would make it meaningless.
    if kind == "StatusBar" then
        frame.GetValue = function(self) return self.value or 0 end
        frame.SetValue = function(self, value) self.value = value end
    end
    frames[#frames+1] = frame
    if name then env[name] = frame end
    if parent and parent.children then
        parent.children[#parent.children+1] = frame
    end
    return frame
end

-- The 3D viewport. Mocked as a real frame with no parent because the game UI
-- is not its ancestor: hiding UIParent must not affect anything hanging off it.
WorldFrame = CreateFrame("Frame", "WorldFrame")
UIParent = CreateFrame("Frame", "UIParent")
WorldMapFrame = CreateFrame("Frame", "WorldMapFrame", UIParent)
WorldMapButton = CreateFrame("Button", "WorldMapButton", WorldMapFrame)
WorldMapButton:SetWidth(1000)
WorldMapButton:SetHeight(700)

-- The minimap, at the geometry measured on this client (140x140, frame level
-- 2). Map/MinimapPins.lua reads width and zoom every tick and picks its
-- yards-per-pixel scale from the zoom step, so both have to be real here --
-- a mock without GetZoom would silently exercise only the fallback path.
Minimap = CreateFrame("Frame", "Minimap", UIParent)
Minimap:SetWidth(140)
Minimap:SetHeight(140)
Minimap:SetFrameLevel(2)
UQ_TEST_MINIMAP_ZOOM = 0
function Minimap.GetZoom() return UQ_TEST_MINIMAP_ZOOM end
function Minimap.GetZoomLevels() return 6 end
-- Real GameTooltip renders its first line into this region. pfQuest reads it
-- back via getglobal("GameTooltipTextLeft1"):GetText() and EntityTooltip does
-- the same, so the mock needs a real global with a GetText method, not just a
-- plain field on the tooltip mock.
GameTooltipTextLeft1 = { text = nil, GetText = function(self) return self.text end }

local function BuildTooltipMock()
    return {
        CreateTexture = function(self, name, layer)
            local texture = setmetatable({ name = name, layer = layer }, textureMeta)
            self.textures = self.textures or {}
            self.textures[#self.textures + 1] = texture
            return texture
        end,
        SetBackdrop = function(self, backdrop) self.backdrop = backdrop end,
        SetBackdropColor = function(self, r, g, b, a) self.bgColor = { r, g, b, a } end,
        SetBackdropBorderColor = function(self, r, g, b, a) self.edgeColor = { r, g, b, a } end,
        SetOwner = function(self, owner, anchor) self.owner = owner; self.anchor = anchor end,
        SetText = function(self, value)
            self.text = value
            -- Real GameTooltip populates the region GameTooltipTextLeft1 with
            -- its first line; EntityTooltip reads that back (pfQuest's own
            -- technique) instead of UnitName("mouseover").
            if self == GameTooltip then GameTooltipTextLeft1.text = value end
        end,
        SetUnit = function(self, unit)
            local name = UnitName(unit)
            if not name then return false end
            self.text = name
            self.lines = {}
            self.doubles = {}
            self.setUnitCalls = (self.setUnitCalls or 0) + 1
            if self == GameTooltip then GameTooltipTextLeft1.text = name end
            return true
        end,
        AddLine = function(self, value)
            self.lines = self.lines or {}
            self.lines[#self.lines + 1] = value
        end,
        AddDoubleLine = function(self, left, right)
            self.doubles = self.doubles or {}
            self.doubles[#self.doubles + 1] = { left, right }
        end,
        NumLines = function(self)
            return (self.text and 1 or 0) + table.getn(self.lines or {})
        end,
        ClearLines = function(self)
            self.text = nil
            self.lines = {}
            self.doubles = {}
            if self == GameTooltip then GameTooltipTextLeft1.text = nil end
        end,
        IsOwned = function(self, frame) return self.owner == frame end,
        IsShown = function(self) return self.shown and true or false end,
        showCalls = 0,
        -- Mirrors real Frame OnShow semantics: it fires for a child frame
        -- (like the accelerator hook in Client.HookGameTooltipShow) only on
        -- the hidden->shown transition, not on every redundant Show() call.
        Show = function(self)
            self.showCalls = self.showCalls + 1
            local wasShown = self.shown
            self.shown = true
            if not wasShown then
                for _, frame in ipairs(frames) do
                    if frame.parent == self and frame.scripts.OnShow then
                        frame.scripts.OnShow()
                    end
                end
            end
        end,
        Hide = function(self) self.shown = false end,
    }
end

GameTooltip = BuildTooltipMock()
-- The fullscreen map owns a separate tooltip frame; the pin layer must prefer
-- it over GameTooltip, matching how the installed pfQuest source selects one.
WorldMapTooltip = BuildTooltipMock()

-- Bags --------------------------------------------------------------------
-- Vanilla-shaped container API. UQ_TEST_BAGS[bag] is a slot->itemId array;
-- a bag absent from the table is a bag slot the player has not filled, which
-- GetContainerNumSlots reports as 0 rather than nil.
UQ_TEST_BAGS = { [0] = {} }
UQ_TEST_BAG_API = true

function GetContainerNumSlots(bag)
    if not UQ_TEST_BAG_API then return 0 end
    local contents = UQ_TEST_BAGS[bag]
    if not contents then return 0 end
    return contents.slots or 16
end

function GetContainerItemLink(bag, slot)
    if not UQ_TEST_BAG_API then return nil end
    local contents = UQ_TEST_BAGS[bag]
    if not contents then return nil end
    local itemId = contents[slot]
    if not itemId then return nil end
    return "|cffffffff|Hitem:" .. itemId .. ":0:0:0|h[Test Item]|h|r"
end

-- Shift-click simulation for the map-pin "mark quest as done" gesture.
UQ_TEST_SHIFT_DOWN = false
function IsShiftKeyDown() return UQ_TEST_SHIFT_DOWN end
UQ_TEST_CTRL_DOWN = false
function IsControlKeyDown() return UQ_TEST_CTRL_DOWN end
UQ_TEST_ALT_DOWN = false
function IsAltKeyDown() return UQ_TEST_ALT_DOWN end

-- Screen ---------------------------------------------------------------------
-- The waypoint converts a bearing offset into a screen offset, so the mock
-- needs a real screen. 1600x900 keeps the half-width a round 800.
function GetScreenWidth() return 1600 end
function GetScreenHeight() return 900 end

-- Legacy CVars, with the two documented quirks the addon has to cope with:
-- GetCVar returns a STRING and answers "0" for a name it does not know, and
-- SetCVar silently ignores an unknown name. UQ_TEST_CVAR_KNOWN is the set of
-- names this mock client actually registers; UnitNameNPC is in it by default,
-- and the NPC-name tests take it out to model a client that is not.
UQ_TEST_CVARS = { rotateMinimap = "0", UnitNameNPC = "0" }
UQ_TEST_CVAR_KNOWN = { rotateMinimap = true, UnitNameNPC = true }
UQ_TEST_CVAR_WRITES = 0

function GetCVar(name)
    local value = UQ_TEST_CVARS[name]
    if value == nil then return "0" end
    return value
end

function SetCVar(name, value)
    UQ_TEST_CVAR_WRITES = UQ_TEST_CVAR_WRITES + 1
    if not UQ_TEST_CVAR_KNOWN[name] then return end
    if value == true then value = 1 elseif value == false then value = 0 end
    if type(value) ~= "number" then value = tonumber(value) or 0 end
    if value == 1 then
        UQ_TEST_CVARS[name] = "1"
    elseif value == 0 then
        UQ_TEST_CVARS[name] = "0"
    else
        UQ_TEST_CVARS[name] = string.format("%.3f", value)
    end
end

-- Deliberately absent, mirroring a client where the compatibility database has
-- no record of them: GetPlayerFacing, and every camera getter. UQ_TEST_FACING
-- is switched on by the facing tests to model a client that does have one, so
-- both branches of HUD/PlayerHeading.lua are exercised.
UQ_TEST_FACING = nil
function UQ_TEST_ENABLE_CLIENT_FACING(value)
    UQ_TEST_FACING = value
    if value == nil then
        env.GetPlayerFacing = nil
    else
        env.GetPlayerFacing = function() return UQ_TEST_FACING end
    end
    -- ClientAPI caches resolved symbols by name, so a symbol appearing or
    -- disappearing mid-session has to be forgotten explicitly. Nothing in the
    -- addon does this; it is a test affordance.
    UnrealQuest.Client.ForgetSymbol("GetPlayerFacing")
end

-- Clock --------------------------------------------------------------------
UQ_TEST_CLOCK = 1000.0
function GetTime() return UQ_TEST_CLOCK end

-- Quest log ----------------------------------------------------------------
-- The client's own objective format strings. Its API reference documents
-- GetQuestLogLeaderBoard as formatting objective text with exactly these, and
-- Tooltip/EntityTooltip.lua reads them back to split a line into a name and its
-- counters, the way pfQuest does. UQ_TEST_NO_QUEST_FORMATS below models a
-- client that does not define them.
QUEST_MONSTERS_KILLED = "%s slain: %d/%d"
QUEST_OBJECTS_FOUND = "%s: %d/%d"
QUEST_ITEMS_NEEDED = "%s: %d/%d"

-- Row shape: { title, level, tag, isHeader, isCollapsed, isComplete, objectives }
UQ_TEST_LOG = {
    { "Elwynn Forest", 0, nil, 1, nil, nil },
    { "Kobold Camp Cleanup", 6, nil, nil, nil, nil,
      { { "Kobold Vermin slain: 4/10", "monster", nil } } },
    { "Sharptalon's Claw", 30, nil, nil, nil, 1,
      { { "Sharptalon's Claw: 1/1", "item", 1 } } },
}
UQ_TEST_SELECTION = 0
UQ_TEST_WATCHES = {}
UQ_TEST_WATCH_REFRESHES = 0

function GetNumQuestLogEntries() return table.getn(UQ_TEST_LOG) end

function GetQuestLogTitle(index)
    local row = UQ_TEST_LOG[index]
    if not row then return nil, 0, nil, nil, nil, nil end
    return row[1], row[2], row[3], row[4], row[5], row[6]
end

function GetNumQuestLeaderBoards(index)
    local row = UQ_TEST_LOG[index or UQ_TEST_SELECTION]
    if not row or not row[7] then return 0 end
    return table.getn(row[7])
end

function GetQuestLogLeaderBoard(objectiveIndex, questIndex)
    local row = UQ_TEST_LOG[questIndex or UQ_TEST_SELECTION]
    if not row or not row[7] then return nil end
    local objective = row[7][objectiveIndex]
    if not objective then return nil end
    return objective[1], objective[2], objective[3]
end

function GetQuestLogSelection() return UQ_TEST_SELECTION end
function SelectQuestLogEntry(index) UQ_TEST_SELECTION = index or 0 end

function IsQuestWatched(index) return UQ_TEST_WATCHES[index] and true or false end
function AddQuestWatch(index) UQ_TEST_WATCHES[index] = true end
function RemoveQuestWatch(index) UQ_TEST_WATCHES[index] = nil end
function GetNumQuestWatches()
    local n = 0
    for _ in pairs(UQ_TEST_WATCHES) do n = n + 1 end
    return n
end
function QuestWatch_Update() UQ_TEST_WATCH_REFRESHES = UQ_TEST_WATCH_REFRESHES + 1 end

-- Player / map -------------------------------------------------------------
function UnitLevel(unit) return UQ_TEST_LEVEL end
UQ_TEST_MOUSEOVER_NAME = nil
UQ_TEST_TARGET_NAME = nil
UQ_TEST_PLAYER_UNITS = {}
function UnitName(unit)
    if unit == "mouseover" then return UQ_TEST_MOUSEOVER_NAME end
    if unit == "target" then return UQ_TEST_TARGET_NAME end
    return "Tester"
end
function UnitExists(unit) return UnitName(unit) ~= nil end
function UnitIsPlayer(unit) return UQ_TEST_PLAYER_UNITS[unit] and true or false end

-- Raid target marks. Modelled the way the client's own reference describes
-- them: SetRaidTarget "sends index - 1 to the server", so the mark is NOT
-- readable straight back. UQ_TEST_MARK_LATENCY is how many SetRaidTarget or
-- GetRaidTargetIndex calls pass before a write becomes visible, and
-- UQ_TEST_MARK_ACCEPT models a server that refuses the write outright -- which
-- is exactly what a solo player may hit, since on Vanilla a mark needs party
-- leader or assist.
UQ_TEST_MARKS = {}
UQ_TEST_MARK_PENDING = nil
UQ_TEST_MARK_LATENCY = 1
UQ_TEST_MARK_ACCEPT = true
UQ_TEST_MARK_WRITES = 0

function SetRaidTarget(unit, index)
    UQ_TEST_MARK_WRITES = UQ_TEST_MARK_WRITES + 1
    if not UQ_TEST_MARK_ACCEPT then return end
    if not UnitExists(unit) then return end
    UQ_TEST_MARK_PENDING = { unit = UnitName(unit), index = index,
                             ticks = UQ_TEST_MARK_LATENCY }
end

function GetRaidTargetIndex(unit)
    local pending = UQ_TEST_MARK_PENDING
    if pending then
        if pending.ticks > 0 then
            pending.ticks = pending.ticks - 1
        else
            if pending.index == 0 then
                UQ_TEST_MARKS[pending.unit] = nil
            else
                UQ_TEST_MARKS[pending.unit] = pending.index
            end
            UQ_TEST_MARK_PENDING = nil
        end
    end
    local name = UnitName(unit)
    if not name then return nil end
    return UQ_TEST_MARKS[name]
end

UQ_TEST_PARTY_SIZE = 0
function GetNumPartyMembers() return UQ_TEST_PARTY_SIZE end
function GetNumRaidMembers() return 0 end
-- Measured on this client: both return a third numeric id. Race 1 = Human,
-- class 8 = Mage, giving bitmask bits 2^(id-1) of 1 and 128.
UQ_TEST_LEVEL = 12
UQ_TEST_RACE = { "Human", "Human", 1 }
UQ_TEST_CLASS = { "Mage", "MAGE", 8 }
function UnitRace(unit) return UQ_TEST_RACE[1], UQ_TEST_RACE[2], UQ_TEST_RACE[3] end
function UnitClass(unit) return UQ_TEST_CLASS[1], UQ_TEST_CLASS[2], UQ_TEST_CLASS[3] end
function UnitFactionGroup(unit) return "Alliance" end
function GetQuestGreenRange() return 5 end

-- Held in variables rather than swapped as functions: ClientAPI caches every
-- resolved global, so reassigning GetMapInfo mid-run would never be seen.
UQ_TEST_MAP_FILE = "ElwynnForest"
UQ_TEST_ZONE_NAME = "Elwynn Forest"
UQ_TEST_SUBZONE_NAME = "Goldshire"
function GetMapInfo() return UQ_TEST_MAP_FILE, 1, 1 end
function GetCurrentMapContinent() return 2 end
function GetCurrentMapZone() return 8 end
UQ_TEST_PLAYER_POSITION = { 0.42, 0.65 }

-- Measured on this client by probe 1.37.0: GetPlayerMapPosition is quantized
-- to exactly one yard. Modelled here because it is the whole reason the
-- heading estimator needs a multi-yard baseline -- a mock with infinite
-- precision would let a broken estimator pass.
UQ_TEST_QUANTIZE_YARDS = false
UQ_TEST_ZONE_YARDS = { 3470.84, 2314.62 }

local function QuantizeUV(value, yards)
    if not UQ_TEST_QUANTIZE_YARDS then return value end
    return math.floor(value * yards + 0.5) / yards
end

function GetPlayerMapPosition(unit)
    return QuantizeUV(UQ_TEST_PLAYER_POSITION[1], UQ_TEST_ZONE_YARDS[1]),
           QuantizeUV(UQ_TEST_PLAYER_POSITION[2], UQ_TEST_ZONE_YARDS[2])
end

-- Documented in the client's `Azeroth` category and measured returning a real
-- boolean that tracked standing versus running.
UQ_TEST_MOVING = false
function IsPlayerMoving() return UQ_TEST_MOVING end
function GetZoneText() return UQ_TEST_ZONE_NAME end
function GetSubZoneText() return UQ_TEST_SUBZONE_NAME end

-- Event dispatch helper ----------------------------------------------------
-- The native surfaces the click layer attaches to.
--
-- Quest log rows are real Buttons with a working OnClick, because that is what
-- the chaining has to preserve: UQ_TEST_LOG_SELECTION records that the native
-- handler still ran. The HUD tracker is FontStrings, because that is why it
-- needs an overlay instead.
QuestWatchFrame = CreateFrame("Frame", "QuestWatchFrame", UIParent)
UQ_TEST_LOG_SELECTION = nil

for i = 1, 6 do
    local row = CreateFrame("Button", "QuestLogTitle" .. i, UIParent)
    row:SetScript("OnClick", function()
        UQ_TEST_LOG_SELECTION = row:GetID()
    end)
end

UQ_TEST_WATCH_LINES = {}
for i = 1, 8 do
    local line = QuestWatchFrame:CreateFontString("QuestWatchLine" .. i, "ARTWORK")
    line:Hide()
    env["QuestWatchLine" .. i] = line
    UQ_TEST_WATCH_LINES[i] = line
end

-- Repopulates both native surfaces from UQ_TEST_LOG, the way the client's own
-- QuestLog_Update and QuestWatch_Update would.
function UQ_TEST_REFRESH_NATIVE_QUEST_UI()
    local row = 0
    for index = 1, table.getn(UQ_TEST_LOG) do
        local entry = UQ_TEST_LOG[index]
        row = row + 1
        local button = env["QuestLogTitle" .. row]
        if button then
            button:SetID(index)
            if entry[4] then
                button:SetText(entry[1])
            else
                button:SetText("  [" .. tostring(entry[2]) .. "] " .. entry[1])
            end
        end
    end

    local line = 0
    for index = 1, table.getn(UQ_TEST_LOG) do
        local entry = UQ_TEST_LOG[index]
        if not entry[4] and UQ_TEST_WATCHES[index] then
            line = line + 1
            local title = UQ_TEST_WATCH_LINES[line]
            if title then
                title:SetText(entry[1])
                title:Show()
            end
            for _, objective in ipairs(entry[7] or {}) do
                line = line + 1
                local text = UQ_TEST_WATCH_LINES[line]
                if text then
                    text:SetText(objective[1])
                    text:Show()
                end
            end
        end
    end
    for spare = line + 1, table.getn(UQ_TEST_WATCH_LINES) do
        UQ_TEST_WATCH_LINES[spare]:SetText("")
        UQ_TEST_WATCH_LINES[spare]:Hide()
    end
end

function UQ_TEST_FIRE(eventName, a1)
    env.event = eventName
    env.arg1 = a1
    for _, frame in ipairs(frames) do
        if frame.events[eventName] and frame.scripts.OnEvent then
            frame.scripts.OnEvent()
        end
    end
    env.event = nil
    env.arg1 = nil
end

function UQ_TEST_TICK(seconds, steps)
    steps = steps or 1
    for _ = 1, steps do
        UQ_TEST_CLOCK = UQ_TEST_CLOCK + seconds
        for _, frame in ipairs(frames) do
            if frame.scripts.OnUpdate then frame.scripts.OnUpdate() end
        end
    end
end
"""

rt.execute(PRELUDE)


def run_file(path, label=None):
    with open(path, encoding="utf-8") as handle:
        source = handle.read()
    chunk = rt.eval("function(s, n) return assert(load(s, n)) end")(source, label or path)
    chunk()


def toc_files(toc_path):
    base = os.path.dirname(toc_path)
    out = []
    # utf-8-sig, not utf-8: a .toc saved with a UTF-8 BOM (common, and what
    # several Windows editors write by default) otherwise leaves ﻿ glued
    # to the front of the first line, so the "## Interface:" header stops
    # looking like a comment and is read as a source file name.
    with open(toc_path, encoding="utf-8-sig") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            out.append(os.path.join(base, line.replace("\\", os.sep)))
    return out


failures = []


def check(label, condition, detail=""):
    if condition:
        print(f"  PASS  {label}")
    else:
        failures.append(label)
        print(f"  FAIL  {label}  {detail}")


print("loading UnrealQuest (bundled world data included)")
for path in toc_files(os.path.join(ADDONS, "unrealQuest", "UnrealQuest.toc")):
    run_file(path)

check("world data populated", rt.eval("UnrealQuestData ~= nil and UnrealQuestData.quests ~= nil"))

check("namespace created", rt.eval("UnrealQuest ~= nil and UnrealQuest.version == '0.0.1'"))
check("slash command registered", rt.eval("SlashCmdList.UNREALQUEST == nil"),
      "should still be nil before init")

print("bootstrapping")
rt.execute("UQ_TEST_FIRE('VARIABLES_LOADED')")
check("init ran on VARIABLES_LOADED", rt.eval("SlashCmdList.UNREALQUEST ~= nil"))
check("saved variables created", rt.eval("UnrealQuestDB ~= nil and UnrealQuestDB.schema == 1"))

rt.execute("UQ_TEST_FIRE('PLAYER_ENTERING_WORLD')")
check("modules enabled", rt.eval("UnrealQuest:GetModule('QuestState').enabled == true"))

print("driving the driver")
rt.execute("UQ_TEST_TICK(0.5, 60)")

check("database indexed", rt.eval("UnrealQuest:GetModule('Database'):IsIndexReady()"))
print("     indexed titles:", rt.eval("UnrealQuest:GetModule('Database').indexedCount"))

check("quest log modelled", rt.eval("UnrealQuest:GetModule('QuestState'):GetQuestCount() == 2"),
      str(rt.eval("UnrealQuest:GetModule('QuestState'):GetQuestCount()")))
check("snapshot complete", rt.eval("UnrealQuest:GetModule('QuestState'):IsComplete()"))

check("objectives read", rt.eval("""(function()
    local q = UnrealQuest:GetModule('QuestState'):GetQuestByTitle('Kobold Camp Cleanup')
    return q ~= nil and q.objectiveCount == 1 and q.objectives[1].have == 4 and q.objectives[1].need == 10
end)()"""))

print("entity tooltip")
rt.execute("""
    local state = UnrealQuest:GetModule('QuestState')
    table.insert(UQ_TEST_LOG, { "Night Web's Hollow", 4, nil, nil, nil, nil,
      { { "Young Night Web Spider slain: 0/10", "monster", nil },
        { "Night Web Spider slain: 0/8", "monster", nil } } })
    state:Scan()
    UQ_TEST_MOUSEOVER_NAME = 'Young Night Web Spider'
    -- The native client already owns and shows the tooltip before the addon's
    -- poll ever runs; this mirrors that by showing it with only the client's
    -- own SetUnit content, not anything the addon adds itself.
    GameTooltip:SetUnit('mouseover')
    GameTooltip:Show()
""")
check("the client's objective format strings are resolved into patterns", rt.eval("""(function()
    local status = UnrealQuest:GetModule('EntityTooltip'):GetStatus()
    return status.patternsResolved == status.patternsExpected and status.patternsResolved > 0
end)()"""))
check("the quest line appears synchronously on Show(), with no poll tick needed", rt.eval("""(function()
    for _, line in ipairs(GameTooltip.lines or {}) do
        if line == '|cffaaaaaa- |rYoung Night Web Spider: 0/10' then return true end
    end
    return false
end)()"""), "GameTooltip:Show() should have triggered the OnShow hook -> Refresh() synchronously")
rt.execute("""
    UQ_TEST_TICK(0.5, 1)
""")
check("hovering a quest creature appends its live objective progress", rt.eval("""(function()
    local seenQuest, seenObjective = false, false
    for _, line in ipairs(GameTooltip.lines or {}) do
        if line == "Night Web's Hollow" then seenQuest = true end
        if line == '|cffaaaaaa- |rYoung Night Web Spider: 0/10' then seenObjective = true end
    end
    return seenQuest and seenObjective
end)()"""))
check("only the hovered creature's own objective is shown, not its name-prefix sibling",
    rt.eval("GameTooltip:NumLines() == 3"),
    "'Night Web Spider slain: 0/8' must not match a hover on 'Young Night Web Spider'")
check("entity tooltip diagnostics record refreshCount and the read tooltip text", rt.eval("""(function()
    local status = UnrealQuest:GetModule('EntityTooltip'):GetStatus()
    return status.refreshCount >= 1 and status.labelReads >= 1
       and status.lastSeenLabel == 'Young Night Web Spider'
end)()"""))
check("the kill objective matched from the log line alone, not from world data", rt.eval("""(function()
    local status = UnrealQuest:GetModule('EntityTooltip'):GetStatus()
    return status.matches >= 1 and status.directMatches >= 1 and status.appendFailures == 0
end)()"""))
check("the native tooltip is re-shown after AddLine, not just appended to", rt.eval(
    "GameTooltip.showCalls >= 1"))
check("nothing the addon does calls GameTooltip:SetUnit itself", rt.eval(
    "(GameTooltip.setUnitCalls or 0) == 1"),
    "only the test's own simulated native SetUnit call above should count")

rt.execute("""
    UQ_TEST_TICK(0.5, 1)
""")
check("an unchanged hover does not duplicate lines", rt.eval(
    "GameTooltip:NumLines() == 3"))

rt.execute("""
    -- Quest progress advances while the player keeps hovering the same
    -- creature. AddLine cannot overwrite an already-drawn line, and SetUnit
    -- is deliberately never called by the addon (see ClientAPI.lua), so this
    -- is a known, accepted limitation: the line shown is a snapshot from the
    -- first hover, not a live counter, until the player re-hovers. What must
    -- still hold is that this never duplicates lines or errors.
    local row = UQ_TEST_LOG[table.getn(UQ_TEST_LOG)]
    row[7][1][1] = "Young Night Web Spider slain: 1/10"
    -- Scan() only reads objectives for a newly-added quest; an existing
    -- quest's progress is refreshed by RefreshObjectiveSlice on its own
    -- cadence, so that is what has to run for the change to be observed.
    UnrealQuest:GetModule('QuestState'):RefreshObjectiveSlice()
    UQ_TEST_TICK(0.5, 1)
""")
check("a quest progressing while still hovering does not duplicate or error", rt.eval(
    "GameTooltip:NumLines() == 3"))

rt.execute("""
    -- Simulate the mouse moving straight to a different quest creature: the
    -- native client hides the old tooltip and shows a fresh one via its own
    -- SetUnit + Show before the addon's poll job would naturally run again.
    -- Client.HookGameTooltipShow should wake the job so this is caught well
    -- inside one tenth of a second, not by chance on the next 0.1s tick.
    GameTooltip:Hide()
    GameTooltip:ClearLines()
    local tooltip = UnrealQuest:GetModule('EntityTooltip')
    tooltip.lastUnitKey = nil
    tooltip.lastTooltipLines = nil
    UQ_TEST_MOUSEOVER_NAME = 'Night Web Spider'
    GameTooltip:SetUnit('mouseover')
    GameTooltip:Show()
    UQ_TEST_TICK(0.01, 1)
""")
check("GameTooltip:Show() wakes the poll instead of waiting out the full interval", rt.eval("""(function()
    for _, line in ipairs(GameTooltip.lines or {}) do
        if line == '|cffaaaaaa- |rNight Web Spider: 0/8' then return true end
    end
    return false
end)()"""))
# The other direction of the prefix trap, and the one the world-data path can
# re-open: "Night Web's Hollow" lists BOTH spiders as objective sources, so a
# substring test against its objective lines would show the young spider's
# objective while hovering the adult one.
check("hovering the shorter-named creature does not pull in its prefixed sibling",
    rt.eval("""(function()
    for _, line in ipairs(GameTooltip.lines or {}) do
        if line == '|cffaaaaaa- |rYoung Night Web Spider: 1/10' then return false end
    end
    return GameTooltip:NumLines() == 3
end)()"""))

# A kill objective must not need the bundled world data at all. This quest
# title is not in the database, so it never resolves to a quest ID and has no
# objective-source record -- exactly the case the previous index-based
# implementation could not serve, and the case a server-renamed quest lands in.
rt.execute("""
    GameTooltip:Hide()
    GameTooltip:ClearLines()
    table.insert(UQ_TEST_LOG, { "Emberveil Vermin Contract", 5, nil, nil, nil, nil,
      { { "Ravenous Emberveil Rat slain: 2/6", "monster", nil } } })
    UnrealQuest:GetModule('QuestState'):Scan()
    UQ_TEST_MOUSEOVER_NAME = 'Ravenous Emberveil Rat'
    GameTooltip:SetUnit('mouseover')
    GameTooltip:Show()
""")
check("a quest with no database match still shows its kill objective", rt.eval("""(function()
    local quest = UnrealQuest:GetModule('QuestState'):GetQuestByTitle('Emberveil Vermin Contract')
    if not quest or quest.questId ~= nil then return false end
    local seenQuest, seenObjective = false, false
    for _, line in ipairs(GameTooltip.lines or {}) do
        if line == 'Emberveil Vermin Contract' then seenQuest = true end
        if line == '|cffaaaaaa- |rRavenous Emberveil Rat: 2/6' then seenObjective = true end
    end
    return seenQuest and seenObjective
end)()"""), "the kill path must not depend on a resolved quest ID")

# An item objective names the item, not the creature that drops it, so this one
# genuinely does need the world data: Gold Dust (item 773) drops from the
# Fargodeep kobolds, and quest 47 "Gold Dust Exchange" lists it under obj.I.
rt.execute("""
    GameTooltip:Hide()
    GameTooltip:ClearLines()
    table.remove(UQ_TEST_LOG, table.getn(UQ_TEST_LOG))
    table.insert(UQ_TEST_LOG, { "Gold Dust Exchange", 7, nil, nil, nil, nil,
      { { "Gold Dust: 5/10", "item", nil } } })
    UnrealQuest:GetModule('QuestState'):Scan()
    UQ_TEST_MOUSEOVER_NAME = 'Kobold Tunneler'
    GameTooltip:SetUnit('mouseover')
    GameTooltip:Show()
""")
check("an item objective matches the creatures the world data says drop it", rt.eval("""(function()
    local seenQuest, seenObjective = false, false
    for _, line in ipairs(GameTooltip.lines or {}) do
        if line == 'Gold Dust Exchange' then seenQuest = true end
        if line == '|cffaaaaaa- |rGold Dust: 5/10' then seenObjective = true end
    end
    return seenQuest and seenObjective
end)()"""), "Gold Dust drops from Kobold Tunneler in the bundled data")
check("the item objective is counted as a world-data match, not a log-line one", rt.eval("""(function()
    local status = UnrealQuest:GetModule('EntityTooltip'):GetStatus()
    return status.databaseMatches >= 1
end)()"""))

rt.execute("""
    GameTooltip:Hide()
    GameTooltip:ClearLines()
    UQ_TEST_MOUSEOVER_NAME = 'Stormwind Guard'
    GameTooltip:SetUnit('mouseover')
    GameTooltip:Show()
    UQ_TEST_TICK(0.5, 3)
""")
check("a creature no quest wants gets nothing appended", rt.eval(
    "GameTooltip:NumLines() == 1"),
    "only the client's own first line should be there")

rt.execute("""
    UQ_TEST_MOUSEOVER_NAME = nil
    GameTooltip:Hide()
    GameTooltip:ClearLines()
    table.remove(UQ_TEST_LOG, table.getn(UQ_TEST_LOG))
    table.remove(UQ_TEST_LOG, table.getn(UQ_TEST_LOG))
    UnrealQuest:GetModule('QuestState'):Scan()
    UQ_TEST_TICK(0.5, 1)
""")


print("WorldFrame inventory")

# /uq worldscan is the answer to a question, not a feature: which WorldFrame
# child is a nameplate. It observes and must change nothing -- a classifier
# already got this wrong once and acted on it (docs/CLIENT-COMPATIBILITY.md
# item 12), so the addon is not allowed to have an opinion here yet.
rt.execute("""
    UQ_TEST_SCAN_TARGET = CreateFrame("Frame", "UQTestWorldChild", WorldFrame)
    local label = UQ_TEST_SCAN_TARGET:CreateFontString(nil, "ARTWORK")
    label:SetText("Kobold Vermin")
    local art = UQ_TEST_SCAN_TARGET:CreateTexture(nil, "BACKGROUND")
    art:SetTexture("Interface\\\\Tooltips\\\\Nameplate-Border")
    local bar = CreateFrame("StatusBar", nil, UQ_TEST_SCAN_TARGET)
    bar:SetValue(50)
    UQ_TEST_SCAN_OK = UnrealQuest:GetModule('WorldFrameScan'):Scan()
""")

check("every WorldFrame child is inventoried", rt.eval("""(function()
    local scan = UnrealQuest:GetModule('WorldFrameScan')
    return UQ_TEST_SCAN_OK == true and scan.childCount == table.getn(scan.lines)
        and scan.childCount > 0
end)()"""))

check("a child's fontstrings, textures and value-bearing children are all reported",
      rt.eval("""(function()
    local scan = UnrealQuest:GetModule('WorldFrameScan')
    local index
    for index = 1, table.getn(scan.lines) do
        local line = scan.lines[index]
        if string.find(line, 'UQTestWorldChild', 1, true) then
            return string.find(line, 'fs=1', 1, true) ~= nil
                and string.find(line, 'tex=1', 1, true) ~= nil
                and string.find(line, 'bars=1', 1, true) ~= nil
                and string.find(line, 'Kobold Vermin', 1, true) ~= nil
        end
    end
    return false
end)()"""))

check("texture paths are stored without a backslash", rt.eval("""(function()
    local scan = UnrealQuest:GetModule('WorldFrameScan')
    local index
    for index = 1, table.getn(scan.lines) do
        local line = scan.lines[index]
        if string.find(line, 'UQTestWorldChild', 1, true) then
            return string.find(line, 'Interface/Tooltips/Nameplate', 1, true) ~= nil
                and string.find(line, '\\\\', 1, true) == nil
        end
    end
    return false
end)()"""), "the saved-variables writer mangles a stored backslash")

check("the inventory survives the reload that flushes it", rt.eval("""(function()
    local saved = UnrealQuestDB.worldFrameScan
    return saved ~= nil and saved.children ~= nil and saved[1] ~= nil
end)()"""))

check("/uq worldscan <n> reports one child's regions and children in full",
      rt.eval("""(function()
    local scan = UnrealQuest:GetModule('WorldFrameScan')
    local worldFrame = UnrealQuest.Client.GetWorldFrame()
    local children = UnrealQuest.Client.GetChildList(worldFrame)
    local target
    local index
    for index = 1, table.getn(children) do
        if children[index] == UQ_TEST_SCAN_TARGET then target = index end
    end
    local detail = scan:Detail(target)
    if not detail then return false end
    local sawFont, sawChild = false, false
    for index = 1, table.getn(detail) do
        if string.find(detail[index], "region 1 FontString", 1, true) then sawFont = true end
        if string.find(detail[index], "child 1 StatusBar", 1, true) then sawChild = true end
    end
    return sawFont and sawChild
end)()"""))

check("scanning writes nothing to any WorldFrame child", rt.eval("""(function()
    return UQ_TEST_SCAN_TARGET:GetAlpha() == 1 and UQ_TEST_SCAN_TARGET:IsShown() == true
end)()"""), "this layer observes; nothing in the addon acts on a WorldFrame child")


print("quest marks over creatures")

# The only per-creature marker this client offers. Every anchor an addon would
# draw its own icon on was measured absent -- no unit position, no player
# facing, no nameplate widget. The realm also ignores SetRaidTarget while solo,
# so only the explicit group-leader/assistant route remains open. See
# docs/CLIENT-COMPATIBILITY.md item 12.
rt.execute("""
    -- The module has been polling since enable, through every mouseover the
    -- tooltip tests drove, so the counters start from a clean slate here.
    local marks = UnrealQuest:GetModule('QuestMarks')
    marks.written = {}
    marks.stats.writes = 0
    marks.stats.confirmed = 0
    marks.stats.cleared = 0
    marks.stats.unconfirmed = 0
    marks.pendingUnit = nil
    UQ_TEST_MARKS = {}
    UQ_TEST_MARK_PENDING = nil
    UQ_TEST_MOUSEOVER_NAME = nil
    UQ_TEST_TARGET_NAME = "Kobold Vermin"
    UnrealQuest:GetModule('QuestState'):Scan()
    UQ_TEST_TICK(0.25, 3)
""")
check("the runtime-confirmed broken solo route sends no writes", rt.eval("""(function()
    local status = UnrealQuest:GetModule('QuestMarks'):GetStatus()
    return UQ_TEST_MARKS['Kobold Vermin'] == nil
        and status.allowedHere == false and status.writes == 0
end)()"""), "this realm ignored nine correctly matched solo writes in game")

rt.execute("""
    UQ_TEST_PARTY_SIZE = 3
    SlashCmdList.UNREALQUEST('marks group on')
    UQ_TEST_TICK(0.25, 3)
""")
check("a creature an objective names is marked", rt.eval(
    "UQ_TEST_MARKS['Kobold Vermin'] == 1"), "1 is the star")

check("and the write is confirmed by reading it back on a later pass, not immediately",
      rt.eval("""(function()
    local status = UnrealQuest:GetModule('QuestMarks'):GetStatus()
    return status.writes == 1 and status.confirmed == 1
end)()"""), "SetRaidTarget sends the value to the server; an instant read reports nil")

rt.execute("UQ_TEST_TICK(0.25, 8)")
check("an already-correct mark is not written again every poll", rt.eval("""(function()
    local status = UnrealQuest:GetModule('QuestMarks'):GetStatus()
    return status.writes == 1
end)()"""))

# A creature nothing wants must be left completely alone -- including a mark
# somebody else put on it.
rt.execute("""
    UQ_TEST_TARGET_NAME = "Stonetusk Boar"
    UQ_TEST_MARKS["Stonetusk Boar"] = 8
    UQ_TEST_TICK(0.25, 6)
""")
check("a creature no quest wants keeps the mark someone else set", rt.eval(
    "UQ_TEST_MARKS['Stonetusk Boar'] == 8"),
    "clearing a mark the addon did not set would fight the player's group")

# ... but a mark the addon did set is taken back when the quest stops wanting
# the creature.
rt.execute("""
    UQ_TEST_MARKS["Stonetusk Boar"] = nil
    UQ_TEST_TARGET_NAME = "Kobold Vermin"
    UQ_TEST_TICK(0.25, 4)
    UQ_TEST_RESTORE_LOG = UQ_TEST_LOG
    UQ_TEST_LOG = { { "Elwynn Forest", 0, nil, 1, nil, nil, {} } }
    UnrealQuest:GetModule('QuestState'):Scan()
    UQ_TEST_TICK(0.25, 6)
""")
check("a mark the addon set is cleared once no quest wants the creature", rt.eval(
    "UQ_TEST_MARKS['Kobold Vermin'] == nil"))
rt.execute("""
    UQ_TEST_LOG = UQ_TEST_RESTORE_LOG
    UnrealQuest:GetModule('QuestState'):Scan()
    UQ_TEST_TICK(0.25, 4)
""")

# Players are never marked, whatever they are called.
rt.execute("""
    UQ_TEST_MARKS = {}
    UQ_TEST_TARGET_NAME = "Kobold Vermin"
    UQ_TEST_PLAYER_UNITS.target = true
    UQ_TEST_TICK(0.25, 6)
""")
check("a player is never marked, even with a creature's name", rt.eval(
    "UQ_TEST_MARKS['Kobold Vermin'] == nil"))
rt.execute("UQ_TEST_PLAYER_UNITS.target = nil")

# A raid mark is shared state: everyone in the group sees it and it overwrites
# what they had set. Even in the only potentially supported context, group
# writes remain disabled unless the player says otherwise.
rt.execute("""
    SlashCmdList.UNREALQUEST('marks group off')
    UQ_TEST_MARKS = {}
    UQ_TEST_TICK(0.25, 6)
""")
check("nothing is marked automatically while in a group", rt.eval(
    "UQ_TEST_MARKS['Kobold Vermin'] == nil"))
rt.execute("SlashCmdList.UNREALQUEST('marks group on'); UQ_TEST_TICK(0.25, 6)")
check("/uq marks group on opts into it", rt.eval(
    "UQ_TEST_MARKS['Kobold Vermin'] == 1"))
rt.execute("""
    UQ_TEST_MARKS = {}
    UQ_TEST_TICK(0.25, 6)
""")

rt.execute("SlashCmdList.UNREALQUEST('marks icon 8'); UQ_TEST_MARKS = {}; UQ_TEST_TICK(0.25, 6)")
check("/uq marks icon picks which of the eight marks is used", rt.eval(
    "UQ_TEST_MARKS['Kobold Vermin'] == 8"), "8 is the skull")
rt.execute("SlashCmdList.UNREALQUEST('marks icon 1')")

# The case that decides whether this feature exists at all on this realm: a
# server that refuses the write. It must be detected and given up on, not
# retried four times a second forever.
rt.execute("""
    SlashCmdList.UNREALQUEST('marks off')
    UQ_TEST_MARKS = {}
    local marks = UnrealQuest:GetModule('QuestMarks')
    marks.written = {}
    marks.stats.writes = 0
    marks.stats.confirmed = 0
    marks.stats.unconfirmed = 0
    marks.refused = false
    UQ_TEST_MARK_ACCEPT = false
    UQ_TEST_PARTY_SIZE = 3
    SlashCmdList.UNREALQUEST('marks group on')
    SlashCmdList.UNREALQUEST('marks on')
    UQ_TEST_TICK(1.0, 40)
""")
check("a server that refuses the marks is detected and given up on", rt.eval("""(function()
    local status = UnrealQuest:GetModule('QuestMarks'):GetStatus()
    return status.refused == true and status.writes <= 8
end)()"""), "a group role without mark permission must not retry forever")

check("and that verdict is persisted for a post-mortem", rt.eval("""(function()
    local diagnostics = UnrealQuestDB.questMarkDiagnostics
    return diagnostics ~= nil and diagnostics.refused == true
end)()"""))

rt.execute("""
    UQ_TEST_MARK_ACCEPT = true
    SlashCmdList.UNREALQUEST('marks on')
    SlashCmdList.UNREALQUEST('marks group off')
    UQ_TEST_PARTY_SIZE = 0
    UQ_TEST_TARGET_NAME = nil
    UQ_TEST_MARKS = {}
    UnrealQuest:GetModule('QuestMarks').written = {}
""")


print("minimap pins")
# The scene is already built by the world-map block below only after it runs,
# so this block drives its own refresh from the same quest log state.
rt.execute("""
    UnrealQuest:GetModule('MinimapPins').dirty = true
    UnrealQuest:GetModule('MinimapPins'):Refresh()
""")
check("minimap draws a dot for every quest-creature spawn", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('MinimapPins')
    pins.targets = { { kind = 'objective', x = 42, y = 65, complete = false } }
    pins:Project(0.42, 0.65, 3470, 2314, 466.6, 140, 140)
    local dot = pins.objectivePool[1]
    local valid = pins.objectiveVisible == 1 and dot ~= nil
        and dot.shown == true and dot.frameType == 'Frame'
        and dot.frameLevel >= 120 and dot.width == 6
        and dot.parent == Minimap
        and dot.unrealQuestTexture ~= nil
        and string.find(dot.unrealQuestTexture.path, 'QuestDot') ~= nil
        and dot.mouseEnabled == false
    pins.dirty = true
    pins:Refresh()
    return valid
end)()"""))
check("minimap objective dots use raw quest-creature positions", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('MinimapPins')
    local state = UnrealQuest:GetModule('QuestState')
    local target = UnrealQuest:GetModule('QuestTarget')
    local map = UnrealQuest:GetModule('WorldMapPins')
    local config = UnrealQuest:GetModule('Config')
    if not pins or not state or not target or not map then return false end
    local expected = 0
    local seen = {}
    local quests = state:GetOrderedQuests()
    local index = 1
    while index <= table.getn(quests) do
        local quest = quests[index]
        if quest.isComplete ~= 1 and map:IsResolvedQuest(quest)
            and not map:IsQuestHidden(quest.questId, config) then
            local locations = target:CollectLocations(quest, 12, false)
            local locationIndex = 1
            while locationIndex <= table.getn(locations) do
                local location = locations[locationIndex]
                if location.sourceType == 'unit' then
                    local key = tostring(location.x) .. ':' .. tostring(location.y)
                    if not seen[key] then
                        seen[key] = true
                        expected = expected + 1
                    end
                end
                locationIndex = locationIndex + 1
            end
        end
        index = index + 1
    end
    local actual = 0
    index = 1
    while index <= table.getn(pins.targets) do
        if pins.targets[index].kind == 'objective' then actual = actual + 1 end
        index = index + 1
    end
    return expected > 0 and actual == expected
end)()"""))
check("minimap objective positions are not truncated at 24", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('MinimapPins')
    pins.targets = {}
    local index = 1
    while index <= 40 do
        table.insert(pins.targets, {
            kind = 'objective', x = 42 + index * 0.01, y = 65, complete = false,
        })
        index = index + 1
    end
    pins:Project(0.42, 0.65, 3470, 2314, 466.6, 140, 140)
    local allVisible = pins.objectiveVisible == 40
    pins.dirty = true
    pins:Refresh()
    return allVisible
end)()"""))
check("every minimap pin is inside the minimap", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('MinimapPins')
    pins.targets = {
        { kind = 'objective', x = 42.1, y = 65, complete = false },
        { kind = 'objective', x = 42.2, y = 65.1, complete = false },
    }
    pins:Project(0.42, 0.65, 3470, 2314, 466.6, 140, 140)
    local limit = 70
    local index = 1
    local checked = 0
    local valid = true
    while index <= table.getn(pins.objectivePool) do
        local pin = pins.objectivePool[index]
        if pin and pin.shown and pin.point then
            local x, y = pin.point[4], pin.point[5]
            if math.sqrt(x * x + y * y) > limit then valid = false end
            checked = checked + 1
        end
        index = index + 1
    end
    pins.dirty = true
    pins:Refresh()
    return valid and checked == 2
end)()"""))
# A creature position is exact. A far spawn is absent instead of being folded
# onto the edge with every other distant spawn.
check("an off-view creature position is hidden instead of clamped", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('MinimapPins')
    pins.targets = { { kind = 'objective', x = 99, y = 99, complete = false } }
    pins.dirty = false
    pins:Refresh()
    return pins.objectiveVisible == 0 and pins.clampedCount == 0
end)()"""))
# Quest POIs keep the established "that way, further than this" contract.
check("a far giver remains clamped to the minimap edge and faded", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('MinimapPins')
    pins.targets = { { kind = 'giver', x = 99, y = 99 } }
    pins.dirty = false
    pins:Refresh()
    local pin = pins.giverPool[1]
    if not pin or not pin.point then return false end
    local x, y = pin.point[4], pin.point[5]
    local distance = math.sqrt(x * x + y * y)
    return pins.giverVisible == 1 and pins.clampedCount == 1
        and distance <= 70 and distance > 55
        and pin.alpha ~= nil and pin.alpha < 1
end)()"""))
# No player facing exists on this client, so a rotated minimap cannot be
# drawn on at all. Refusing is the contract; approximating would be a bug.
check("a rotating minimap hides every pin", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('MinimapPins')
    pins.targets = { { kind = 'objective', x = 42, y = 65, complete = false } }
    pins.dirty = false
    UQ_TEST_CVARS.rotateMinimap = "1"
    pins:Refresh()
    local hidden = pins.objectiveVisible == 0 and pins.giverVisible == 0
        and pins.turnInVisible == 0 and pins.lastState == 'rotatingMinimap'
    UQ_TEST_CVARS.rotateMinimap = "0"
    pins:Refresh()
    local restored = pins.objectiveVisible == 1
    pins.dirty = true
    pins:Refresh()
    return hidden and restored
end)()"""))
check("the minimap layer reports which zoom steps are measured", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('MinimapPins')
    local measured = pins:GetStatus()
    UQ_TEST_MINIMAP_ZOOM = 3
    pins:Refresh()
    local assumed = pins:GetStatus()
    UQ_TEST_MINIMAP_ZOOM = 0
    pins:Refresh()
    return measured.spanEvidence == 'measured' and measured.span == 466.6
        and assumed.spanEvidence == 'vanillaConstant' and assumed.span == 266.6
end)()"""))
check("/uq minimap toggles the layer off and on", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('MinimapPins')
    local config = UnrealQuest:GetModule('Config')
    config:Set('minimapPins', false)
    pins:Refresh()
    local off = pins.objectiveVisible == 0 and pins.lastState == 'disabled'
    config:Set('minimapPins', true)
    pins.targets = { { kind = 'objective', x = 42, y = 65, complete = false } }
    pins.dirty = false
    pins:Refresh()
    local restored = pins.objectiveVisible == 1
    pins.dirty = true
    pins:Refresh()
    return off and restored
end)()"""))

print("world map pins")
check("world-map area rendering enabled after runtime confirmation", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('WorldMapPins')
    return pins ~= nil and pins.renderEnabled == true
end)()"""))
rt.execute("""
    UnrealQuest:GetModule('WorldMapPins').dirty = true
    table.insert(UQ_TEST_LOG, { "Gold Dust Exchange", 7, nil, nil, nil, nil,
      { { "Gold Dust: 5/10", "item", nil } } })
    UnrealQuest:GetModule('QuestState'):Scan()
    UQ_TEST_TICK(0.5, 2)
""")
check("quest areas use the confirmed construction", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('WorldMapPins')
    local area = pins and pins.areaPool[1]
    local diagnostics = UnrealQuestDB.mapDiagnostics
    return pins ~= nil and area ~= nil and pins.areaVisibleCount > 0
        and area.shown == true and area.point ~= nil
        and area.frameType == 'Button' and area.frameLevel >= 120
        and area.width == 25 and area.height == 17.5
        and area.unrealQuestTexture ~= nil and area.unrealQuestTexture.alpha == 0.5
        and area.unrealQuestLabel == nil
        and diagnostics ~= nil and pins.areaVisibleCount <= diagnostics.pooledAreas
end)()"""))
# The yellow numbered square is retired: the areas are the whole quest layer,
# and hovering one names the quest. No marker may be created or drawn at all.
check("no numbered marker is drawn above a quest area", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('WorldMapPins')
    return pins.visibleCount == 0 and pins.pool[1] == nil
        and pins.areaPool[1].unrealQuestMarkerPin == nil
end)()"""))
check("stable map refresh reapplies cached area positions", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('WorldMapPins')
    local area = pins and pins.areaPool[1]
    return area ~= nil
        and type(area.unrealQuestMapX) == 'number' and type(area.unrealQuestMapY) == 'number'
        and type(area.unrealQuestAreaWidthPercent) == 'number'
        and type(area.unrealQuestAreaHeightPercent) == 'number'
end)()"""))
check("map diagnostics record rendered state", rt.eval("""(function()
    local diagnostics = UnrealQuestDB.mapDiagnostics
    return diagnostics ~= nil and diagnostics.state == 'rendered'
        and diagnostics.visiblePins == 0 and diagnostics.visibleAreas > 0
        and diagnostics.candidateLocations > diagnostics.visibleAreas
        and diagnostics.renderMode == 'fileBackedAreasHoverTooltipV1'
        -- The snapshot now samples the area tile, the only quest child left on
        -- the canvas, and it must still satisfy the confirmed contract.
        and diagnostics.pinType == 'Button' and diagnostics.pinLevel >= 120
        and diagnostics.pinWidth == 25 and diagnostics.pinHeight == 17.5
        and diagnostics.parentMatches == true and diagnostics.textureLayer == 'BACKGROUND'
        and diagnostics.textureHasPath == true
end)()"""))
print("quest area hover")
# Driven through the frame's own OnEnter/OnLeave scripts rather than by calling
# the module methods, so the wiring from SetWorldMapPinHandlers is exercised too.
rt.execute("""
    local pins = UnrealQuest:GetModule('WorldMapPins')
    UQ_TEST_AREA = pins.areaPool[1]
    UQ_TEST_AREA.scripts.OnEnter()
""")
check("an area tile is mouse-aware and knows its quest", rt.eval("""(function()
    return UQ_TEST_AREA.mouseEnabled == true and UQ_TEST_AREA.unrealQuestQuest ~= nil
end)()"""))
check("hovering an area shows that quest's title and live objective progress", rt.eval("""(function()
    local quest = UQ_TEST_AREA.unrealQuestQuest
    if WorldMapTooltip.text ~= quest.title then return false end
    local objective = quest.objectives[1].text
    for _, line in ipairs(WorldMapTooltip.lines or {}) do
        if line == '- ' .. objective then return true end
    end
    return false
end)()"""))
check("the area tooltip carries the quest level and its status", rt.eval("""(function()
    local seenLevel, seenStatus = false, false
    for _, pair in ipairs(WorldMapTooltip.doubles or {}) do
        if pair[1] == 'Level:' then seenLevel = true end
        if pair[1] == 'Status:' and (pair[2] == 'In progress' or pair[2] == 'Ready to turn in') then
            seenStatus = true
        end
    end
    return seenLevel and seenStatus
end)()"""))
rt.execute("UQ_TEST_TICK(0.5, 2)")
check("a stable map refresh leaves the tooltip up", rt.eval("WorldMapTooltip.shown == true"))
rt.execute("""
    local pins = UnrealQuest:GetModule('WorldMapPins')
    pins.dirty = true
    pins:Refresh()
""")
check("a hover held across a full rebuild keeps the tooltip", rt.eval("""(function()
    return WorldMapTooltip.shown == true
        and WorldMapTooltip.text == UQ_TEST_AREA.unrealQuestQuest.title
end)()"""))
rt.execute("UQ_TEST_AREA.scripts.OnLeave()")
check("leaving the area hides the tooltip", rt.eval("WorldMapTooltip.shown == false"))
check("area hovers are counted for the SavedVariables record", rt.eval(
    "UnrealQuestDB.mapDiagnostics.areaHovers > 0"))
# Marker suppression still ships behind MARKER_RENDER_ENABLED, so its one
# load-bearing property is tested directly on the layer: the pools re-apply
# every visible pin's point on stable ticks and re-applying a point calls Show,
# which is exactly what a plain Hide would lose.
rt.execute("""
    local Client = UnrealQuest.Client
    UQ_TEST_SUPPRESSED = Client.CreateWorldMapPin(9001, 1, 0.75, 0.1)
    Client.PositionWorldMapPin(UQ_TEST_SUPPRESSED, 0.5, 0.5)
    Client.SetWorldMapPinSuppressed(UQ_TEST_SUPPRESSED, true)
    Client.ReapplyWorldMapPin(UQ_TEST_SUPPRESSED)
""")
check("a suppressed marker stays hidden when its point is re-applied", rt.eval(
    "UQ_TEST_SUPPRESSED.shown == false and UQ_TEST_SUPPRESSED.point ~= nil"))
rt.execute("""
    local Client = UnrealQuest.Client
    Client.SetWorldMapPinSuppressed(UQ_TEST_SUPPRESSED, false)
    Client.ReapplyWorldMapPin(UQ_TEST_SUPPRESSED)
""")
check("clearing suppression restores the marker on the next re-apply", rt.eval(
    "UQ_TEST_SUPPRESSED.shown == true"))

print("quest-giver \"still to take\" markers")
rt.execute("UQ_TEST_TICK(0.5, 30)")
check("giver index builds from bundled world data", rt.eval(
    "UnrealQuest:GetModule('Database'):IsGiverIndexReady()"))
# Quest 6 ("Bounty on Garrick Padfoot") starts from unit 823 ("Deputy Willem")
# with a real bundled coordinate in Elwynn Forest (area 12) and is not in the
# test quest log, so it must surface as a "still to take" giver marker.
rt.execute("""
    UnrealQuest:GetModule('WorldMapPins').dirty = true
    UnrealQuest:GetModule('WorldMapPins'):Refresh()
""")
check("quest giver marker uses the client's native available-quest icon", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('WorldMapPins')
    local pin = pins.giverPool[1]
    if pins.giverVisibleCount == 0 or pin == nil then return false end
    -- Native icon, untinted, and no "!" FontString of our own.
    return pin.unrealQuestTexture.path == 'Interface\\\\GossipFrame\\\\AvailableQuestIcon'
        and pin.unrealQuestTexture.vertex[1] == 1
        and pin.unrealQuestTexture.vertex[2] == 1
        and pin.unrealQuestTexture.vertex[3] == 1
        and pin.unrealQuestLabel == nil
        and pin.frameType == 'Button' and pin.width == 14 and pin.height == 14
        and pin.unrealQuestTexture.layer == 'BACKGROUND'
end)()"""))
# The reported "shift-click does nothing" bug. Every pool runs the same level
# formula, so the giver pin and the area tile it sits on both landed on 120 and
# the tile -- mouse-aware for its tooltip, but deliberately without an OnClick
# -- could win the click and drop it. The pin must now outrank the tiles.
check("giver pin outranks the area tiles it can overlap", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('WorldMapPins')
    local pin, area = pins.giverPool[1], pins.areaPool[1]
    if pin == nil or area == nil then return false end
    return pin.frameLevel > area.frameLevel and pin.frameLevel >= 120
end)()"""))
check("giver pin registers the click token it depends on", rt.eval("""(function()
    local pin = UnrealQuest:GetModule('WorldMapPins').giverPool[1]
    for _, token in ipairs(pin and pin.clickTokens or {}) do
        if token == 'LeftButtonUp' then return true end
    end
    return false
end)()"""))
# Area tiles have no OnClick, so they must not claim click tokens either.
check("area tiles claim no click tokens", rt.eval("""(function()
    local area = UnrealQuest:GetModule('WorldMapPins').areaPool[1]
    return area ~= nil and area.clickTokens == nil
end)()"""))
check("giver pin carries the quest it offers", rt.eval("""(function()
    local pin = UnrealQuest:GetModule('WorldMapPins').giverPool[1]
    local ids = pin and pin.unrealQuestAvailableQuestIds
    if not ids then return false end
    for _, id in ipairs(ids) do
        if id == 6 then return true end
    end
    return false
end)()"""))
rt.execute("""
    local pins = UnrealQuest:GetModule('WorldMapPins')
    pins:OnGiverEnter(pins.giverPool[1])
""")
check("the fullscreen map's own tooltip frame is preferred over GameTooltip", rt.eval(
    "UnrealQuest.Client.GetMapTooltipName() == 'WorldMapTooltip' and GameTooltip.text == nil"))
# Separates "the mouse never reaches a 14x14 pin" from "only the click is lost"
# without a screenshot; see the open worldMapPinInteraction question.
check("giver hovers are counted for the SavedVariables record", rt.eval(
    "UnrealQuest:GetModule('WorldMapPins'):GetStatus().giverHovers > 0"))
check("hovering the marker shows the giver name and quest title in the tooltip", rt.eval("""(function()
    if WorldMapTooltip.text ~= 'Deputy Willem' or WorldMapTooltip.lines == nil then
        return false
    end
    for _, line in ipairs(WorldMapTooltip.lines) do
        if line == '[!] Bounty on Garrick Padfoot' then
            return true
        end
    end
    return false
end)()"""))
check("the tooltip carries the giver's level as a label/value pair", rt.eval("""(function()
    if WorldMapTooltip.doubles == nil then return false end
    for _, pair in ipairs(WorldMapTooltip.doubles) do
        if pair[1] == 'Level:' and pair[2] == '18' then return true end
    end
    return false
end)()"""))
# Deputy Willem offers five quests, so the hint must promise the picker rather
# than a straight mark-done. Advertising the wrong one is how the gesture came
# to read as broken: the click appeared to delete a quest without asking which.
check("a multi-quest giver's tooltip advertises the picker, not a blind mark-done", rt.eval("""(function()
    local found = false
    for _, line in ipairs(WorldMapTooltip.lines or {}) do
        if string.find(line, 'Shift-click to choose which quest is already done', 1, true) then
            found = true
        end
        if string.find(line, 'Shift-click to mark as already done', 1, true) then
            return false
        end
    end
    return found
end)()"""))
# Same flat panel look unrealUI applies to GameTooltip: near-black fill, the
# stock bevel driven to zero alpha, and a 1-unit outline drawn from plain
# textures rather than requested through the backdrop's edgeFile. Separator
# textures share the frame, so inspect the border's own pool rather than every
# texture attached to the tooltip.
check("the tooltip wears unrealUI's flat panel styling", rt.eval("""(function()
    local t = WorldMapTooltip
    if t.backdrop == nil or t.backdrop.edgeFile ~= nil then return false end
    if t.bgColor == nil or t.bgColor[1] ~= 0.06 or t.bgColor[4] ~= 0.85 then return false end
    if t.edgeColor == nil or t.edgeColor[4] ~= 0 then return false end
    if t.unrealQuestEdges == nil or table.getn(t.unrealQuestEdges) ~= 4 then return false end
    for _, edge in ipairs(t.unrealQuestEdges) do
        if edge.layer ~= 'OVERLAY' then return false end
        if edge.vertex[1] ~= 0.16 then return false end
        if (edge.width or edge.height) ~= 1 then return false end
    end
    return true
end)()"""))
check("tooltip border textures are built once, not per hover", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('WorldMapPins')
    local edges = WorldMapTooltip.unrealQuestEdges
    local firstEdge = edges and edges[1]
    local textureCount = table.getn(WorldMapTooltip.textures or {})
    pins:OnGiverEnter(pins.giverPool[1])
    pins:OnGiverEnter(pins.giverPool[1])
    return WorldMapTooltip.unrealQuestEdges == edges
        and WorldMapTooltip.unrealQuestEdges[1] == firstEdge
        and table.getn(WorldMapTooltip.unrealQuestEdges) == 4
        and table.getn(WorldMapTooltip.textures or {}) == textureCount
end)()"""))
rt.execute("""
    local pins = UnrealQuest:GetModule('WorldMapPins')
    pins:OnGiverLeave(pins.giverPool[1])
""")
check("leaving the marker hides the tooltip", rt.eval("WorldMapTooltip.shown == false"))

check("plain click does not mark the quest done", rt.eval("""(function()
    UQ_TEST_SHIFT_DOWN = false
    local pins = UnrealQuest:GetModule('WorldMapPins')
    pins:OnGiverClick(pins.giverPool[1])
    return UnrealQuest:GetModule('QuestHistory'):IsDone(6) == false
end)()"""))
# A "!" is per-GIVER, and Deputy Willem is still offering five quests. One
# click therefore cannot mean "all five" without silently discarding four the
# player never chose -- the reported bug. Shift-click must ask instead.
rt.execute("""
    UQ_TEST_SHIFT_DOWN = true
    local pins = UnrealQuest:GetModule('WorldMapPins')
    pins:OnGiverClick(pins.giverPool[1])
    UQ_TEST_SHIFT_DOWN = false
""")
check("shift-clicking a multi-quest giver opens the picker instead of marking anything",
    rt.eval("""(function()
    if UnrealQuest.Client.IsGiverQuestMenuOpenFor(
        UnrealQuest:GetModule('WorldMapPins').giverPool[1]) ~= true then
        return false
    end
    local history = UnrealQuest:GetModule('QuestHistory')
    for _, id in ipairs({6, 18, 783, 3903, 5261}) do
        if history:IsDone(id) then return false end
    end
    return true
end)()"""))
# The menu must clear the pins it was summoned from. Every pooled map child
# sits at max(canvasLevel + 20, 120); a menu built off the raw canvas level
# opened underneath them, which is what made it flash and vanish.
check("the picker is drawn above the map pins, not beneath them", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('WorldMapPins')
    return UnrealQuestGiverMenu:GetFrameLevel() > pins.giverPool[1]:GetFrameLevel()
end)()"""))
check("the picker names every quest the giver still offers", rt.eval("""(function()
    local wanted = {
        ['Bounty on Garrick Padfoot'] = true, ['Brotherhood of Thieves'] = true,
        ['A Threat Within'] = true, ['Milly Osworth'] = true,
        ['Eagan Peltskinner'] = true,
    }
    for i = 1, 5 do
        local row = getglobal('UnrealQuestGiverMenuRow' .. i)
        if row == nil or row.fontString == nil then return false end
        wanted[row.fontString.text] = nil
    end
    for _ in pairs(wanted) do return false end
    return true
end)()"""))
# Picking one row marks that quest and only that quest.
rt.execute("""
    local row
    for i = 1, 5 do
        local candidate = getglobal('UnrealQuestGiverMenuRow' .. i)
        if candidate.fontString.text == 'Bounty on Garrick Padfoot' then row = candidate end
    end
    row:GetScript('OnClick')()
""")
check("picking a quest from the picker marks only that quest done", rt.eval("""(function()
    local history = UnrealQuest:GetModule('QuestHistory')
    if history:IsDone(6) ~= true then return false end
    for _, id in ipairs({18, 783, 3903, 5261}) do
        if history:IsDone(id) then return false end
    end
    return true
end)()"""))
check("picking a quest closes the picker", rt.eval(
    "UnrealQuestGiverMenu:IsShown() == false"))
check("closing the picker also hides its outside-click catcher", rt.eval(
    "UnrealQuestGiverMenuCatcher == nil or UnrealQuestGiverMenuCatcher:IsShown() == false"))

# Reopen the picker (four quests remain) and confirm a click elsewhere on the
# map -- caught by the invisible full-canvas Button beneath the menu and above
# every pin -- dismisses it without marking anything, the same "click outside
# closes it" behaviour a native dropdown has.
rt.execute("""
    UQ_TEST_SHIFT_DOWN = true
    local pins = UnrealQuest:GetModule('WorldMapPins')
    pins:OnGiverClick(pins.giverPool[1])
    UQ_TEST_SHIFT_DOWN = false
""")
check("the picker reopens for the quests still on offer", rt.eval(
    "UnrealQuestGiverMenu:IsShown() == true"))
check("the outside-click catcher is shown while the picker is open", rt.eval(
    "UnrealQuestGiverMenuCatcher ~= nil and UnrealQuestGiverMenuCatcher:IsShown() == true"))
check("the catcher sits above the pins and below the menu itself", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('WorldMapPins')
    local pinLevel = pins.giverPool[1]:GetFrameLevel()
    local catcherLevel = UnrealQuestGiverMenuCatcher:GetFrameLevel()
    local menuLevel = UnrealQuestGiverMenu:GetFrameLevel()
    return catcherLevel > pinLevel and catcherLevel < menuLevel
end)()"""))
rt.execute("UnrealQuestGiverMenuCatcher:GetScript('OnClick')()")
check("clicking outside the picker closes it without marking any quest", rt.eval("""(function()
    if UnrealQuestGiverMenu:IsShown() ~= false then return false end
    local history = UnrealQuest:GetModule('QuestHistory')
    for _, id in ipairs({18, 783, 3903, 5261}) do
        if history:IsDone(id) then return false end
    end
    return true
end)()"""))
check("the catcher hides again once the picker it guards is closed", rt.eval(
    "UnrealQuestGiverMenuCatcher:IsShown() == false"))

rt.execute("""
    UnrealQuest:GetModule('WorldMapPins').dirty = true
    UnrealQuest:GetModule('WorldMapPins'):Refresh()
""")
# The "!" itself stays -- four quests are still on offer -- but must stop
# listing the one just marked.
check("a quest marked done is dropped from its giver marker", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('WorldMapPins')
    for i = 1, pins.giverVisibleCount do
        local ids = pins.giverPool[i].unrealQuestAvailableQuestIds
        for _, id in ipairs(ids) do
            if id == 6 then return false end
        end
    end
    return true
end)()"""))
# The reported "have to close and reopen the map" bug: the whole driver stops
# ticking while the fullscreen map hides UIParent, so nothing rebuilt until the
# map was closed. The driver must hang off WorldFrame, which the UI never hides
# -- the same parent the installed pfQuest uses for its own live map layer.
check("the shared driver survives the game UI being hidden", rt.eval("""(function()
    local frame = UnrealQuest:GetModule('Driver').frame
    if frame == nil then return false end
    if frame:GetParent() ~= WorldFrame then return false end
    UIParent.shown = false            -- fullscreen map hides the game UI
    local ticks = frame:IsVisible()
    UIParent.shown = true
    return ticks == true
end)()"""))
check("marking a giver done wakes the map job instead of waiting out its interval",
    rt.eval("""(function()
    local driver = UnrealQuest:GetModule('Driver')
    local job = driver.jobsByName['map.worldpins']
    if job == nil then return false end
    job.accumulated = 0
    local pins = UnrealQuest:GetModule('WorldMapPins')
    -- Through the picker, since this giver offers several quests: shift-click
    -- to open it, then take the first row.
    UQ_TEST_SHIFT_DOWN = true
    pins:OnGiverClick(pins.giverPool[1])
    UQ_TEST_SHIFT_DOWN = false
    local row = getglobal('UnrealQuestGiverMenuRow1')
    if row == nil or row:IsShown() ~= true then return false end
    row:GetScript('OnClick')()
    return job.accumulated >= job.interval
end)()"""))
check("the rebuild counter separates a stale paint from a stale layer", rt.eval(
    "UnrealQuest:GetModule('WorldMapPins'):GetStatus().rebuilds > 0"))

print("quest turn-in \"?\" markers")
# Marshal McBride (unit 197) has exactly one spawn in Elwynn Forest (48.9/41.6,
# area 12) and is the ender of both "Kobold Camp Cleanup" (7) and "Investigate
# Echo Ridge" (15) -- so he is the shared-marker case. Remy "Two Times" (241,
# 42.1/67.3) ends "Gold Dust Exchange" (47), already in the test log and still
# in progress. Sharptalon's Claw (2) ends at Senani Thunderheart in Ashenvale
# and must therefore draw nothing on an Elwynn map.
rt.execute("""
    UQ_TEST_LOG[2][6] = 1   -- Kobold Camp Cleanup is now ready to turn in
    table.insert(UQ_TEST_LOG, { "Investigate Echo Ridge", 3, nil, nil, nil, nil, {} })
    UnrealQuest:GetModule('QuestState'):Scan()
    UnrealQuest:GetModule('WorldMapPins').dirty = true
    UnrealQuest:GetModule('WorldMapPins'):Refresh()
""")
rt.execute("""
    UQ_TEST_TURNIN = nil
    UQ_TEST_TURNIN_DIM = nil
    UQ_TEST_TURNIN_MCBRIDE = 0
    local pins = UnrealQuest:GetModule('WorldMapPins')
    for i = 1, pins.turnInVisibleCount do
        local pin = pins.turnInPool[i]
        local point = pin.unrealQuestTurnIn
        if point.sourceId == 197 then
            UQ_TEST_TURNIN = pin
            UQ_TEST_TURNIN_MCBRIDE = UQ_TEST_TURNIN_MCBRIDE + 1
        elseif point.sourceId == 241 then
            UQ_TEST_TURNIN_DIM = pin
        end
    end
""")
check("turn-in marker uses the bundled active-quest icon", rt.eval("""(function()
    local pin = UQ_TEST_TURNIN
    if pin == nil then return false end
    -- Bundled icon, no "?" FontString of our own, and every other property of
    -- the confirmed pin contract unchanged except size: the icon is a 19x32
    -- portrait image (media/ActiveQuestIcon.tga), so the frame is resized to
    -- that aspect ratio at the confirmed height of 14 instead of staying a
    -- 14x14 square, which would stretch/squash the glyph.
    return pin.unrealQuestTexture.path == 'Interface\\\\AddOns\\\\unrealQuest\\\\media\\\\ActiveQuestIcon'
        and pin.unrealQuestLabel == nil
        and pin.frameType == 'Button' and pin.width == 14 * 19 / 32 and pin.height == 14
        and pin.unrealQuestTexture.layer == 'BACKGROUND'
        and pin.shown == true and pin.point ~= nil
end)()"""))
check("two quests ending at one NPC share a single marker", rt.eval("""(function()
    local pin = UQ_TEST_TURNIN
    if pin == nil or UQ_TEST_TURNIN_MCBRIDE ~= 1 then return false end
    local ids = {}
    for _, quest in ipairs(pin.unrealQuestTurnIn.quests) do ids[quest.questId] = true end
    return table.getn(pin.unrealQuestTurnIn.quests) == 2 and ids[7] and ids[15]
end)()"""))
check("a point with something ready to hand in shows the icon untinted", rt.eval("""(function()
    local pin = UQ_TEST_TURNIN
    if pin == nil or pin.unrealQuestTurnIn.complete ~= true then return false end
    local v = pin.unrealQuestTexture.vertex
    return v[1] == 1 and v[2] == 1 and v[3] == 1
end)()"""))
# Greyscale, not "darker yellow": SetVertexColor only multiplies, so scaling
# the client's yellow "?" down leaves it yellow. The in-progress marker has to
# be desaturated for real -- and at full brightness, the same (1, 1, 1) the
# giver "!" is created with. A multiply on top of greyscale reads as a shadow
# on the map, not as "not ready yet".
check("a quest still in progress greys out its turn-in marker instead", rt.eval("""(function()
    local pin = UQ_TEST_TURNIN_DIM
    if pin == nil or pin.unrealQuestTurnIn.complete ~= false then return false end
    local texture = pin.unrealQuestTexture
    local v = texture.vertex
    return texture.desaturated == true and v[1] == 1 and v[2] == 1 and v[3] == 1
end)()"""))
check("the greyed \"?\" is as bright as the giver \"!\"", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('WorldMapPins')
    local giver = pins.giverPool[1]
    if giver == nil then return false end
    local g, q = giver.unrealQuestTexture.vertex, UQ_TEST_TURNIN_DIM.unrealQuestTexture.vertex
    return g[1] == q[1] and g[2] == q[2] and g[3] == q[3]
end)()"""))
check("a marker ready to hand in is not desaturated", rt.eval(
    "UQ_TEST_TURNIN.unrealQuestTexture.desaturated == false"))
check("greyscale is reported as a capability", rt.eval(
    "UnrealQuest.capabilities.worldMapPinDesaturation.state == 'detected'"))
# 174 bundled quests have no `end` relation, 53 of them while still carrying
# `obj`. Asked for a turn-in location, those must come back empty rather than
# falling through to the creatures their objectives are killed on -- which is
# what the `isComplete and finishers or objectives` idiom used to do.
check("a quest with no recorded turn-in yields no location, not its objectives",
    rt.eval("""(function()
    local db = UnrealQuest:GetModule('Database')
    local target
    for id = 1, 9000 do
        local r = db:GetQuest(id)
        if r and r['end'] == nil and r.obj ~= nil then target = id break end
    end
    if not target then return false end
    for areaId = 1, 2000 do
        if table.getn(db:GetQuestLocations(target, true, areaId, 8)) > 0 then return false end
    end
    return true
end)()"""))
check("a quest that ends in another zone draws no marker here", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('WorldMapPins')
    for i = 1, pins.turnInVisibleCount do
        -- Senani Thunderheart, Ashenvale: Sharptalon's Claw is complete, so
        -- this only stays off the map if the area filter holds.
        if pins.turnInPool[i].unrealQuestTurnIn.sourceId == 12696 then return false end
    end
    return pins.turnInVisibleCount == 2
end)()"""))
# Same frame-level collision that made the "!" shift-click do nothing: a pin at
# the tiles' own level leaves the hit test to draw order. The "?" must outrank
# the tiles it sits on -- a complete quest's green tiles are drawn from the very
# same ender coordinate -- while still yielding to the "!", which owns a click.
check("turn-in pin outranks the area tiles but yields to the giver \"!\"", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('WorldMapPins')
    local pin, area, giver = UQ_TEST_TURNIN, pins.areaPool[1], pins.giverPool[1]
    if pin == nil or area == nil or giver == nil then return false end
    return pin.frameLevel > area.frameLevel and pin.frameLevel >= 120
        and giver.frameLevel > pin.frameLevel
end)()"""))
# These pins have no OnClick, so like the area tiles they must not claim click
# tokens -- a mouse-aware frame that registers clicks and ignores them is what
# silently swallowed the giver gesture.
check("turn-in pins claim no click tokens", rt.eval(
    "UQ_TEST_TURNIN.clickTokens == nil"))
rt.execute("""
    local pins = UnrealQuest:GetModule('WorldMapPins')
    pins:OnTurnInEnter(UQ_TEST_TURNIN)
""")
check("turn-in hovers are counted for the SavedVariables record", rt.eval(
    "UnrealQuest:GetModule('WorldMapPins'):GetStatus().turnInHovers > 0"
    " and UnrealQuestDB.mapDiagnostics.turnInHovers > 0"))
check("hovering names the NPC and both quests handed in there", rt.eval("""(function()
    if WorldMapTooltip.text ~= 'Marshal McBride' or WorldMapTooltip.lines == nil then
        return false
    end
    local cleanup, ridge = false, false
    for _, line in ipairs(WorldMapTooltip.lines) do
        if line == '[?] Kobold Camp Cleanup' then cleanup = true end
        if line == '[?] Investigate Echo Ridge' then ridge = true end
    end
    return cleanup and ridge
end)()"""))
check("the tooltip separates what is ready from what is not", rt.eval("""(function()
    if WorldMapTooltip.doubles == nil then return false end
    local ready, progress, count = false, false, false
    for _, pair in ipairs(WorldMapTooltip.doubles) do
        if pair[1] == '- Status:' and pair[2] == 'Ready to turn in' then ready = true end
        if pair[1] == '- Status:' and pair[2] == 'In progress' then progress = true end
        if pair[1] == 'Turns in:' and pair[2] == '2' then count = true end
    end
    return ready and progress and count
end)()"""))
check("the tooltip carries the NPC's level as a label/value pair", rt.eval("""(function()
    for _, pair in ipairs(WorldMapTooltip.doubles or {}) do
        -- A string in the bundled data, never a number; passed through raw.
        if pair[1] == 'Level:' and pair[2] == '20' then return true end
    end
    return false
end)()"""), str(rt.eval("""(function()
    for _, pair in ipairs(WorldMapTooltip.doubles or {}) do
        if pair[1] == 'Level:' then return tostring(pair[2]) end
    end
    return 'no level pair'
end)()""")))
# No click gesture exists on these pins, so advertising one would be a lie.
check("the turn-in tooltip advertises no click gesture", rt.eval("""(function()
    for _, line in ipairs(WorldMapTooltip.lines or {}) do
        if string.find(line, 'lick', 1, true) then return false end
    end
    return true
end)()"""))
rt.execute("""
    local pins = UnrealQuest:GetModule('WorldMapPins')
    pins:OnTurnInLeave(UQ_TEST_TURNIN)
""")
check("leaving the turn-in marker hides the tooltip", rt.eval("WorldMapTooltip.shown == false"))
# A client that has SetDesaturated but refuses the effect must not be left with
# an in-progress "?" that looks identical to a ready one, so the multiply-only
# dim stays as the fallback.
rt.execute("""
    UQ_TEST_DESATURATE_OK = false
    local pins = UnrealQuest:GetModule('WorldMapPins')
    pins.dirty = true
    pins:Refresh()
""")
check("a client refusing greyscale falls back to a darker marker", rt.eval("""(function()
    local v = UQ_TEST_TURNIN_DIM.unrealQuestTexture.vertex
    return v[1] == 0.55 and v[1] == v[2] and v[2] == v[3]
end)()"""))
rt.execute("""
    UQ_TEST_DESATURATE_OK = true
    local pins = UnrealQuest:GetModule('WorldMapPins')
    pins.dirty = true
    pins:Refresh()
""")
rt.execute("""
    UnrealQuestDB.showInProgressTurnIns = false
    local pins = UnrealQuest:GetModule('WorldMapPins')
    pins.dirty = true
    pins:Refresh()
""")
check("opting out drops the in-progress markers and keeps the ready ones", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('WorldMapPins')
    if pins.turnInVisibleCount ~= 1 then return false end
    local point = pins.turnInPool[1].unrealQuestTurnIn
    -- Only McBride survives, and now for the one quest that is actually ready.
    return point.sourceId == 197 and point.complete == true
        and table.getn(point.quests) == 1 and point.quests[1].questId == 7
end)()"""))
check("the hidden markers are hidden, not merely dropped from the count", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('WorldMapPins')
    return pins.turnInPool[2] ~= nil and pins.turnInPool[2].shown == false
end)()"""))
# Restore the log and the setting for the checks that follow.
rt.execute("""
    UnrealQuestDB.showInProgressTurnIns = true
    UQ_TEST_LOG[2][6] = nil
    table.remove(UQ_TEST_LOG, table.getn(UQ_TEST_LOG))
    UnrealQuest:GetModule('QuestState'):Scan()
    local pins = UnrealQuest:GetModule('WorldMapPins')
    pins.dirty = true
    pins:Refresh()
""")

print("quest eligibility filtering")
# CLUCK! (3861) is started by the Chicken critter (unit 620, 108 spawn points
# across 9 zones) and carries race mask 77 = Human+Dwarf+NightElf+Gnome, i.e.
# Alliance only. It is the reason every chicken in the world became a marker.
check("CLUCK!'s Alliance race mask is offerable to a Human", rt.eval("""(function()
    local e = UnrealQuest:GetModule('QuestEligibility')
    e:RefreshPlayer()
    return e:IsOfferable(3861) == true
end)()"""))
check("the same quest is filtered out for an Undead character", rt.eval("""(function()
    UQ_TEST_RACE = { 'Undead', 'Scourge', 5 }
    local e = UnrealQuest:GetModule('QuestEligibility')
    e:RefreshPlayer()
    local ok, reason = e:IsOfferable(3861)
    UQ_TEST_RACE = { 'Human', 'Human', 1 }
    e:RefreshPlayer()
    return ok == false and reason == 'race'
end)()"""))
check("a quest above the character's level is filtered out", rt.eval("""(function()
    local db = UnrealQuest:GetModule('Database')
    local e = UnrealQuest:GetModule('QuestEligibility')
    -- Find any quest whose required level is above the test character's 12.
    local target
    for id = 1, 6000 do
        local r = db:GetQuest(id)
        if r and type(r.min) == 'number' and r.min > 40 then target = id break end
    end
    if not target then return false end
    e:RefreshPlayer()
    local ok, reason = e:IsOfferable(target)
    return ok == false and reason == 'level'
end)()"""))
check("seasonal event quests are hidden by default", rt.eval("""(function()
    local db = UnrealQuest:GetModule('Database')
    local e = UnrealQuest:GetModule('QuestEligibility')
    local target
    for id = 1, 9000 do
        local r = db:GetQuest(id)
        if r and r.event ~= nil and (r.min == nil or r.min <= 12)
            and (r.race == nil or r.race == 0 or math.floor(r.race / 1) - math.floor(r.race / 2) * 2 == 1) then
            target = id break
        end
    end
    if not target then return false end
    e:RefreshPlayer()
    local ok, reason = e:IsOfferable(target)
    if ok ~= false or reason ~= 'event' then return false end
    -- ...and shown when the player opts in.
    UnrealQuestDB.showEventQuests = true
    local shown = e:IsOfferable(target)
    UnrealQuestDB.showEventQuests = false
    return shown == true
end)()"""))
check("an unresolvable player attribute never blanks the map", rt.eval("""(function()
    local e = UnrealQuest:GetModule('QuestEligibility')
    UQ_TEST_RACE = { nil, nil, nil }
    e:RefreshPlayer()
    local ok = e:IsOfferable(3861)
    UQ_TEST_RACE = { 'Human', 'Human', 1 }
    e:RefreshPlayer()
    return ok == true
end)()"""))

rt.execute("WorldMapFrame:Hide(); UQ_TEST_TICK(0.5, 1)")
check("world-map children are effectively hidden with native map", rt.eval("""(function()
    local pins = UnrealQuest:GetModule('WorldMapPins')
    local area = pins.areaPool[1]
    -- Still shown from the addon's side: the refresh must never gate on the
    -- native map's visibility, which does not reflect this client's
    -- fullscreen presentation.
    return pins.areaVisibleCount > 0 and area ~= nil
        and area.shown == true and area:IsVisible() == false
end)()"""))
rt.execute("WorldMapFrame:Show(); UQ_TEST_TICK(0.5, 1)")
rt.execute("table.remove(UQ_TEST_LOG, table.getn(UQ_TEST_LOG)); UnrealQuest:GetModule('QuestState'):Scan()")

check("quest matched to database", rt.eval("""(function()
    local q = UnrealQuest:GetModule('QuestState'):GetQuestByTitle("Sharptalon's Claw")
    return q ~= nil and q.questId == 2 and q.matchConfidence == 'unique'
end)()"""), str(rt.eval("""(function()
    local q = UnrealQuest:GetModule('QuestState'):GetQuestByTitle("Sharptalon's Claw")
    if not q then return 'no quest' end
    return tostring(q.questId) .. '/' .. tostring(q.matchConfidence)
end)()""")))

# A server-modified title that has no Vanilla database record: the expected
# outcome is a clean "unmatched", recorded rather than silently dropped.
rt.execute("""
    table.insert(UQ_TEST_LOG, { "Emberveil Founders Errand", 14, nil, nil, nil, nil, {} })
    UnrealQuest:GetModule('QuestState'):Scan()
""")
check("server-only title reports unmatched", rt.eval("""(function()
    local q = UnrealQuest:GetModule('QuestState'):GetQuestByTitle('Emberveil Founders Errand')
    return q ~= nil and q.questId == nil and q.matchConfidence == 'unmatched'
end)()"""))
check("unmatched title recorded", rt.eval("""(function()
    return UnrealQuestDB.unmatchedQuests ~= nil
        and UnrealQuestDB.unmatchedQuests['Emberveil Founders Errand'] == 1
end)()"""))

check("quest events rejected without faulting", rt.eval("""(function()
    local e = UnrealQuest:GetModule('Events')
    return e:WasAccepted('QUEST_LOG_UPDATE') == false and e:WasAccepted('BAG_UPDATE') == true
end)()"""))

print("event observation")
rt.execute("UQ_TEST_FIRE('BAG_UPDATE', 0)")
check("event counted", rt.eval("UnrealQuest:GetModule('Events'):GetObservedCount('BAG_UPDATE') >= 1"))

print("item-use objectives (obj.IR / quests-itemreq)")
# Marla's Last Wish (6395). obj.O names Marla's Grave (178090) at 31.2/65.1 in
# Tirisfal (85); obj.IR names Samuel's Remains (16333), and quests-itemreq maps
# that item onto the same grave. The grave is therefore the target of a "use
# this there" step, not an unconditional objective source, and it sits twenty
# yards from Novice Elreth (1661), the quest's own turn-in NPC -- which is
# exactly why drawing it from the moment the quest was accepted read as a
# second, bogus quest area over Deathknell.
check("an item-use target is recognised from obj.IR", rt.eval("""(function()
    local db = UnrealQuest:GetModule('Database')
    local targets = db:GetQuestItemUseTargets(6395)
    if table.getn(targets) ~= 1 then return false end
    local t = targets[1]
    return t.itemId == 16333 and t.sourceType == 'object' and t.sourceId == 178090
end)()"""))
check("a quest with no obj.IR reports no item-use targets", rt.eval(
    "table.getn(UnrealQuest:GetModule('Database'):GetQuestItemUseTargets(380)) == 0"))
check("the item-use target is kept out of the plain objective locations", rt.eval("""(function()
    local db = UnrealQuest:GetModule('Database')
    local locations = db:GetQuestLocations(6395, nil, 85, 200)
    local sawGrave, sawSamuel = false, false
    for _, location in ipairs(locations) do
        if location.sourceType == 'object' and location.sourceId == 178090 then sawGrave = true end
        -- Samuel Fipps (1919) drops the remains and must still be drawn: he is
        -- the step the player can actually take.
        if location.sourceType == 'unit' and location.sourceId == 1919 then sawSamuel = true end
    end
    return sawSamuel and not sawGrave
end)()"""))
check("the turn-in relation is untouched by the exclusion", rt.eval("""(function()
    local locations = UnrealQuest:GetModule('Database'):GetQuestLocations(6395, true, 85, 8)
    return table.getn(locations) == 1 and locations[1].sourceId == 1661
end)()"""))
check("entity locations honour the area filter", rt.eval("""(function()
    local db = UnrealQuest:GetModule('Database')
    return table.getn(db:GetEntityLocations('object', 178090, 85, 8)) == 1
        and table.getn(db:GetEntityLocations('object', 178090, 1, 8)) == 0
end)()"""))

# The bag scan is round-robined one bag per tick and only publishes a whole
# cycle, so a partial pass must never look like empty bags.
rt.execute("UQ_TEST_BAGS = { [0] = {} }; UnrealQuest:GetModule('BagItems'):Invalidate()")
rt.execute("UQ_TEST_TICK(1.0, 8)")
check("an empty-bag cycle publishes a readable, empty set", rt.eval("""(function()
    local bags = UnrealQuest:GetModule('BagItems')
    return bags.available == true and bags:Carries(16333) == false
end)()"""))
rt.execute("UQ_TEST_BAGS[0][3] = 16333; UnrealQuest:GetModule('BagItems'):Invalidate()")
rt.execute("UQ_TEST_TICK(1.0, 8)")
check("looting the required item is observed", rt.eval(
    "UnrealQuest:GetModule('BagItems'):Carries(16333) == true"))
check("the carried-set token moves only when membership changes", rt.eval("""(function()
    local bags = UnrealQuest:GetModule('BagItems')
    local before = bags:GetToken()
    UQ_TEST_TICK(1.0, 8)
    return bags:GetToken() == before
end)()"""))
check("an unreadable container API reports unknown, not empty", rt.eval("""(function()
    local bags = UnrealQuest:GetModule('BagItems')
    UQ_TEST_BAG_API = false
    bags:Invalidate()
    UQ_TEST_TICK(1.0, 8)
    local unknown = bags.available == false and bags:Carries(16333) == nil
    UQ_TEST_BAG_API = true
    bags:Invalidate()
    UQ_TEST_TICK(1.0, 8)
    return unknown and bags:Carries(16333) == true
end)()"""))

# End to end on the real record that produced the report: with the quest
# accepted and the bags empty the map must show Samuel Fipps and nothing else,
# and Marla's Grave must appear only once the remains are carried.
rt.execute("""
    UQ_TEST_RESTORE_LOG = UQ_TEST_LOG
    UQ_TEST_MAP_FILE = "Tirisfal"
    UQ_TEST_ZONE_NAME = "Tirisfal Glades"
    UQ_TEST_SUBZONE_NAME = "Deathknell"
    UQ_TEST_LOG = {
        { "Tirisfal Glades", 0, nil, 1, nil, nil },
        { "Marla's Last Wish", 5, nil, nil, nil, nil,
          { { "Samuel's Remains: 0/1", "item", nil } } },
    }
    UQ_TEST_BAGS = { [0] = {} }
    UnrealQuest:GetModule('BagItems'):Invalidate()
    UnrealQuest:GetModule('QuestState'):Scan()
    UQ_TEST_TICK(1.0, 10)
    UQ_TEST_AREAS_WITHOUT = UnrealQuest:GetModule('WorldMapPins').areaVisibleCount
    UQ_TEST_BAGS[0][1] = 16333
    UnrealQuest:GetModule('BagItems'):Invalidate()
    UQ_TEST_TICK(1.0, 10)
    UQ_TEST_AREAS_WITH = UnrealQuest:GetModule('WorldMapPins').areaVisibleCount
""")
check("without the remains the map draws only Samuel Fipps", rt.eval(
    "UQ_TEST_AREAS_WITHOUT == 1"))
check("carrying the remains adds the grave as a second area", rt.eval(
    "UQ_TEST_AREAS_WITH == 2"))
check("the carried item alone repaints the map", rt.eval(
    "UnrealQuest:GetModule('WorldMapPins').rebuildCount >= 2"))
check("no item-use target was withheld for an unreadable bag", rt.eval(
    "UnrealQuestDB.mapDiagnostics.itemUseUnknown == 0"))
rt.execute("""
    UQ_TEST_MAP_FILE = "ElwynnForest"
    UQ_TEST_ZONE_NAME = "Elwynn Forest"
    UQ_TEST_SUBZONE_NAME = "Goldshire"
    UQ_TEST_LOG = UQ_TEST_RESTORE_LOG
    UQ_TEST_BAGS = { [0] = {} }
    UnrealQuest:GetModule('BagItems'):Invalidate()
    UnrealQuest:GetModule('QuestState'):Scan()
    UQ_TEST_TICK(1.0, 10)
""")

print("tracking")
rt.execute("""
    local state = UnrealQuest:GetModule('QuestState')
    local tracker = UnrealQuest:GetModule('Tracker')
    local quest = state:GetQuestByTitle('Kobold Camp Cleanup')
    UQ_TEST_TRACK_OK = tracker:Track(quest)
""")
check("track applied", rt.eval("UQ_TEST_TRACK_OK == true and IsQuestWatched(2) == true"))
check("tracking refreshes native watch panel", rt.eval("UQ_TEST_WATCH_REFRESHES >= 1"))
rt.execute("UQ_TEST_TICK(1.0, 3)")
check("tracked title remembered", rt.eval("""(function()
    return UnrealQuestDB.trackedQuests ~= nil
        and UnrealQuestDB.trackedQuests['Kobold Camp Cleanup'] == 1
end)()"""))

print("reload restore (watch list cleared, saved settings kept)")
rt.execute("""
    UQ_TEST_WATCHES = {}
    UnrealQuest:GetModule('Tracker').restored = false
    UnrealQuest:GetModule('Tracker').attempts = 0
    UnrealQuest:GetModule('Tracker'):Restore()
""")
check("tracking restored after simulated reload", rt.eval("IsQuestWatched(2) == true"))
check("restore refreshes native watch panel", rt.eval("UQ_TEST_WATCH_REFRESHES >= 2"))

print("late quest identity resolution")

# The database title index builds across driver ticks, so on a login with a
# full quest log every quest is first modelled with confidence "indexing" and
# no quest ID. The retry that resolves it later changes no row and no
# objective, so it used to notify nothing at all -- and anything keyed on quest
# IDs kept whatever it had derived while the whole log was unidentified.
rt.execute("""
    UQ_TEST_IDENTITY_NOTIFICATIONS = 0
    UnrealQuest:GetModule('QuestState'):AddListener(function(event)
        if event == 'QUEST_LOG_CHANGED' then
            UQ_TEST_IDENTITY_NOTIFICATIONS = UQ_TEST_IDENTITY_NOTIFICATIONS + 1
        end
    end)
    local quest = UnrealQuest:GetModule('QuestState'):GetQuestByTitle("Sharptalon's Claw")
    quest.questId = nil
    quest.matchConfidence = 'indexing'
    UnrealQuest:GetModule('QuestState'):Scan()
""")
check("a quest identified only on a later scan notifies listeners", rt.eval("""(function()
    local quest = UnrealQuest:GetModule('QuestState'):GetQuestByTitle("Sharptalon's Claw")
    return quest.questId ~= nil and UQ_TEST_IDENTITY_NOTIFICATIONS == 1
end)()"""))
rt.execute("UnrealQuest:GetModule('QuestState'):Scan()")
check("a scan that resolves nothing new stays quiet", rt.eval(
    "UQ_TEST_IDENTITY_NOTIFICATIONS == 1"))

print("quest removal detection")
rt.execute("table.remove(UQ_TEST_LOG, 2); UnrealQuest:GetModule('QuestState'):Scan()")
check("removed quest dropped from model", rt.eval("""(function()
    local state = UnrealQuest:GetModule('QuestState')
    return state:GetQuestByTitle('Kobold Camp Cleanup') == nil and state:GetQuestCount() == 2
end)()"""))

print("collapsed header safety")
rt.execute("""
    UQ_TEST_LOG[1][5] = 1
    UQ_TEST_LOG[2] = nil
    UnrealQuest:GetModule('QuestState'):Scan()
""")
check("incomplete snapshot does not invent removals", rt.eval("""(function()
    local state = UnrealQuest:GetModule('QuestState')
    return state:IsComplete() == false and state:GetQuestByTitle("Sharptalon's Claw") ~= nil
end)()"""))

print("the main quest + HUD waypoint layer is gated off")

# The layer ships disabled. These checks pin the disable itself: not that the
# marker is hidden, but that nothing was ever registered to hide. A layer that
# registers and then declines to act still costs a driver tick.
check("the shipped default is disabled", rt.eval(
    "UnrealQuest:IsFeatureEnabled('mainQuestWaypoint') == false"))

check("a disabled layer declares no capabilities", rt.eval(
    "UnrealQuest:GetCapability('mainQuestSelection') == nil"
    " and UnrealQuest:GetCapability('questLogRowClick') == nil"
    " and UnrealQuest:GetCapability('questWatchLineClick') == nil"))

check("a disabled layer schedules no driver job", rt.eval("""(function()
    local driver = UnrealQuest:GetModule('Driver')
    local names = { "mainquest.restore", "mainquest.validate",
                    "clicks.logrows", "clicks.watchoverlay", "clicks.diagnostics",
                    "hud.waypointcontext", "hud.waypoint", "hud.waypointdiagnostics" }
    local index = 1
    local total = table.getn(names)
    while index <= total do
        if driver.jobsByName[names[index]] then
            return false
        end
        index = index + 1
    end
    return true
end)()"""))

# The one that actually matters. SetScript(type, nil) does not detach a script
# on this client, so a chain installed once cannot be removed for the rest of
# the session -- there is no such thing as disabling this layer after
# QuestClicks:OnEnable has run.
check("a disabled layer chains nothing onto the native quest log", rt.eval(
    "UnrealQuest:GetModule('QuestClicks').chainedRows == 0"))

check("a disabled layer creates no marker frame", rt.eval(
    "UnrealQuest:GetModule('Waypoint').frame == nil"))

check("a disabled layer leaves the map's main-quest highlight unreachable", rt.eval(
    "UnrealQuest:GetModule('MainQuest'):Get() == nil"))

check("an unknown feature key reports enabled, so a typo cannot silently disable a layer",
      rt.eval("UnrealQuest:IsFeatureEnabled('noSuchFeatureKey') == true"))

# The commands have to say the layer is off. A module that answers with all its
# counters at zero reads like a broken feature, which is the report the gate
# exists to avoid producing.
_say_probe = rt.eval("""function(command, needle)
    local messages = UQ_TEST_MESSAGES
    local before = table.getn(messages)
    SlashCmdList.UNREALQUEST(command)
    local index = before + 1
    local total = table.getn(messages)
    while index <= total do
        if messages[index] and string.find(messages[index], needle, 1, true) then
            return true
        end
        index = index + 1
    end
    return false
end""")


def _said(needle, command):
    return _say_probe(command, needle)

check("/uq status names the disabled layer", _said("mainQuestWaypoint", "status"))
check("/uq main says the layer is disabled instead of reporting zeroes",
      _said("disabled", "main"))
check("/uq waypoint says the layer is disabled instead of reporting zeroes",
      _said("disabled", "waypoint"))
check("/uq main <target> does not select while disabled", rt.eval("""(function()
    SlashCmdList.UNREALQUEST('main camp cleanup')
    return UnrealQuest:GetModule('MainQuest'):Get() == nil
end)()"""))

print("main quest, click surfaces and the HUD waypoint")

# The layer is off in the shipped build, but its logic must not rot while it
# waits for a client that can carry it -- that is the whole point of keeping the
# code rather than deleting it. Turn the gate on for the rest of this section
# and run the lifecycle the bootstrap would have run, so every test below still
# exercises the real modules.
rt.execute("""
    UnrealQuest:DeclareFeature("mainQuestWaypoint", true, "enabled by tools/smoke.py")
    UnrealQuest:GetModule('MainQuest'):OnInit()
    UnrealQuest:GetModule('QuestClicks'):OnInit()
    UnrealQuest:GetModule('MainQuest'):OnEnable()
    UnrealQuest:GetModule('QuestClicks'):OnEnable()
    UnrealQuest:GetModule('Waypoint'):OnEnable()
""")

check("the gated layer comes back up when re-enabled", rt.eval("""(function()
    local driver = UnrealQuest:GetModule('Driver')
    return UnrealQuest:IsFeatureEnabled('mainQuestWaypoint') == true
        and driver.jobsByName["hud.waypoint"] ~= nil
        and driver.jobsByName["mainquest.validate"] ~= nil
        and UnrealQuest:GetCapability('mainQuestSelection') == "verified"
end)()"""))

# Put the native surfaces into the state the client would leave them in.
rt.execute("""
    UQ_TEST_LOG = {
        { "Elwynn Forest", 0, nil, 1, nil, nil },
        { "Kobold Camp Cleanup", 6, nil, nil, nil, nil,
          { { "Kobold Vermin slain: 4/10", "monster", nil } } },
        { "Sharptalon's Claw", 30, nil, nil, nil, 1,
          { { "Sharptalon's Claw: 1/1", "item", 1 } } },
    }
    UnrealQuest:GetModule('QuestState'):Scan()
    UQ_TEST_REFRESH_NATIVE_QUEST_UI()
    UQ_TEST_TICK(0.5, 4)
""")

# --- The angle arithmetic -----------------------------------------------------
# Pinned by hand rather than derived, because every sign error in this feature
# ends up here and a self-consistent wrong convention would still pass a
# round-trip test.
check("bearing: due north is 0", rt.eval("""(function()
    local h = UnrealQuest:GetModule('PlayerHeading')
    local b = h.BearingFromYards(0, -10)
    return b ~= nil and math.abs(b) < 0.001
end)()"""))
check("bearing: due west is +pi/2", rt.eval("""(function()
    local h = UnrealQuest:GetModule('PlayerHeading')
    local b = h.BearingFromYards(-10, 0)
    return b ~= nil and math.abs(b - math.pi / 2) < 0.001
end)()"""))
check("bearing: due east is 3pi/2", rt.eval("""(function()
    local h = UnrealQuest:GetModule('PlayerHeading')
    local b = h.BearingFromYards(10, 0)
    return b ~= nil and math.abs(b - 3 * math.pi / 2) < 0.001
end)()"""))
check("bearing: due south is pi", rt.eval("""(function()
    local h = UnrealQuest:GetModule('PlayerHeading')
    local b = h.BearingFromYards(0, 10)
    return b ~= nil and math.abs(b - math.pi) < 0.001
end)()"""))
check("angle delta wraps to the short way round", rt.eval("""(function()
    local h = UnrealQuest:GetModule('PlayerHeading')
    local d = h.NormalizeDelta(3 * math.pi / 2)
    return d ~= nil and math.abs(d + math.pi / 2) < 0.001
end)()"""))

# --- The screen projection -----------------------------------------------------
check("projection: dead ahead sits at screen centre", rt.eval("""(function()
    local w = UnrealQuest:GetModule('Waypoint')
    local x, clamped = w:ProjectToScreen(0, 800, 0.8727)
    return math.abs(x) < 0.001 and clamped == false
end)()"""))
check("projection: a target to the left goes left of centre", rt.eval("""(function()
    local w = UnrealQuest:GetModule('Waypoint')
    local x = w:ProjectToScreen(0.3, 800, 0.8727)
    return x < 0
end)()"""))
check("projection: a target to the right goes right of centre", rt.eval("""(function()
    local w = UnrealQuest:GetModule('Waypoint')
    local x = w:ProjectToScreen(-0.3, 800, 0.8727)
    return x > 0
end)()"""))
check("projection: a target behind the player pins to an edge", rt.eval("""(function()
    local w = UnrealQuest:GetModule('Waypoint')
    local left, leftClamped = w:ProjectToScreen(math.pi * 0.9, 800, 0.8727)
    local right, rightClamped = w:ProjectToScreen(-math.pi * 0.9, 800, 0.8727)
    return leftClamped and rightClamped
        and left == -800 * w.EDGE_FRACTION and right == 800 * w.EDGE_FRACTION
end)()"""))
check("projection: the marker never leaves the screen", rt.eval("""(function()
    local w = UnrealQuest:GetModule('Waypoint')
    local step = -math.pi
    while step <= math.pi do
        local x = w:ProjectToScreen(step, 800, 0.8727)
        if x < -800 or x > 800 then return false end
        step = step + 0.05
    end
    return true
end)()"""))

# --- The target is the map's own area centre -----------------------------------
check("the waypoint target is the same point the map draws", rt.eval("""(function()
    local target = UnrealQuest:GetModule('QuestTarget')
    local state = UnrealQuest:GetModule('QuestState')
    local quest = state:GetQuestByTitle("Kobold Camp Cleanup")
    if not quest then return false, "no quest" end

    local resolved = target:Resolve(quest, 12)
    if not resolved then return false end

    -- Recomputed exactly the way Map/WorldMapPins.lua does it, from the same
    -- entry points, so a future refactor that gives the map a second opinion
    -- fails here rather than in game.
    local locations = target:CollectLocations(quest, 12, false)
    local primary = target:SelectPrimary(target:BuildComponents(locations))
    return primary ~= nil and resolved.x == primary.x and resolved.y == primary.y
end)()"""))

check("a quest with no location in the viewed area resolves to nothing", rt.eval("""(function()
    local target = UnrealQuest:GetModule('QuestTarget')
    local state = UnrealQuest:GetModule('QuestState')
    local quest = state:GetQuestByTitle("Kobold Camp Cleanup")
    -- Area 1 is Dun Morogh; an Elwynn quest has nothing there.
    local resolved, why = target:Resolve(quest, 1)
    return resolved == nil and why == "noLocationsInArea"
end)()"""))

check("zone dimensions convert percentages into yards", rt.eval("""(function()
    local target = UnrealQuest:GetModule('QuestTarget')
    -- Elwynn Forest is 3470.84 x 2314.62 yards in the bundled minimap table,
    -- so 10% of the width is ~347 yards and 10% of the height is ~231. The
    -- difference between those two is exactly why raw percentages cannot be
    -- used for a bearing.
    local east, south = target:ToYards(12, 10, 10)
    return east ~= nil and math.abs(east - 347.084) < 0.5
        and math.abs(south - 231.462) < 0.5
end)()"""))

# --- Selection ------------------------------------------------------------------
check("no quest is followed to begin with", rt.eval("""
    UnrealQuest:GetModule('MainQuest'):Get() == nil"""))

rt.execute("""
    local state = UnrealQuest:GetModule('QuestState')
    local quest = state:GetQuestByTitle("Kobold Camp Cleanup")
    UnrealQuest:GetModule('MainQuest'):Set(quest.titleKey)
""")
check("a quest can be followed", rt.eval("""(function()
    local main = UnrealQuest:GetModule('MainQuest')
    local report = main:GetReport()
    return report.title == "Kobold Camp Cleanup"
end)()"""))
check("the followed quest is persisted as a title key, never an index", rt.eval("""(function()
    local stored = UnrealQuestDB.mainQuestTitleKey
    return type(stored) == "string" and stored == UnrealQuest.NameKey("Kobold Camp Cleanup")
end)()"""))
check("nothing persisted for the main quest can carry a backslash", rt.eval("""(function()
    local stored = UnrealQuestDB.mainQuestTitleKey
    return string.find(stored, "\\\\", 1, true) == nil
end)()"""))

check("selecting the followed quest again stops following it", rt.eval("""(function()
    local state = UnrealQuest:GetModule('QuestState')
    local main = UnrealQuest:GetModule('MainQuest')
    local quest = state:GetQuestByTitle("Kobold Camp Cleanup")
    main:Toggle(quest.titleKey)
    local cleared = main:Get() == nil
    main:Set(quest.titleKey)
    return cleared
end)()"""))

# --- Selection survives a reload -------------------------------------------------
check("the followed quest survives a reload", rt.eval("""(function()
    local main = UnrealQuest:GetModule('MainQuest')
    local expected = main:Get()

    -- Model the reload the way Tracker's own test does: wipe the in-memory
    -- state, leave SavedVariables alone, and let the restore job run.
    main.titleKey = nil
    main.restored = false
    main.restoreAttempts = 0
    UnrealQuest:GetModule('Driver'):Schedule("mainquest.restore", 0.5, function()
        UnrealQuest:GetModule('MainQuest'):Restore()
    end)
    UQ_TEST_TICK(0.5, 4)

    return main:Get() == expected and expected ~= nil
end)()"""))

# --- The collapsed-header trap ----------------------------------------------------
check("a collapsed header does not drop the followed quest", rt.eval("""(function()
    local state = UnrealQuest:GetModule('QuestState')
    local main = UnrealQuest:GetModule('MainQuest')
    local before = main:Get()

    -- Collapse the header: the client stops listing the quests under it, so
    -- the followed quest vanishes from the log without being turned in.
    local saved = { }
    for i = 1, table.getn(UQ_TEST_LOG) do saved[i] = UQ_TEST_LOG[i] end
    UQ_TEST_LOG[1][5] = 1
    UQ_TEST_LOG[2] = nil
    UQ_TEST_LOG[3] = nil
    state:Scan()
    main:Validate()
    local survived = main:Get() == before

    for i = 1, table.getn(saved) do UQ_TEST_LOG[i] = saved[i] end
    UQ_TEST_LOG[1][5] = nil
    state:Scan()
    return survived and before ~= nil
end)()"""))

check("the followed quest is dropped once it really leaves the log", rt.eval("""(function()
    local state = UnrealQuest:GetModule('QuestState')
    local main = UnrealQuest:GetModule('MainQuest')

    local saved = UQ_TEST_LOG[2]
    table.remove(UQ_TEST_LOG, 2)
    state:Scan()
    main:Validate()
    local dropped = main:Get() == nil

    table.insert(UQ_TEST_LOG, 2, saved)
    state:Scan()
    UQ_TEST_REFRESH_NATIVE_QUEST_UI()
    return dropped
end)()"""))

# --- Click surfaces ----------------------------------------------------------------
check("every quest log row is chained", rt.eval("""(function()
    local clicks = UnrealQuest:GetModule('QuestClicks')
    return clicks:GetReport().chainedRows >= 6
end)()"""))

check("clicking a quest log row follows that quest", rt.eval("""(function()
    local clicks = UnrealQuest:GetModule('QuestClicks')
    local main = UnrealQuest:GetModule('MainQuest')
    main:Clear("test")
    UQ_TEST_LOG_SELECTION = nil

    QuestLogTitle2:GetScript("OnClick")()

    local report = main:GetReport()
    return report.title == "Kobold Camp Cleanup" and clicks:GetReport().logClicks == 1
end)()"""))

check("chaining leaves the native row click working", rt.eval("""
    UQ_TEST_LOG_SELECTION == 2"""),
    "the native OnClick must still run; a swallowed row click would break quest selection")

check("clicking a header row follows nothing", rt.eval("""(function()
    local main = UnrealQuest:GetModule('MainQuest')
    local before = main:Get()
    QuestLogTitle1:GetScript("OnClick")()
    return main:Get() == before
end)()"""))

# --- The HUD tracker overlay --------------------------------------------------------
rt.execute("""
    AddQuestWatch(2)
    UQ_TEST_REFRESH_NATIVE_QUEST_UI()
    UnrealQuest:GetModule('QuestClicks'):RefreshWatchOverlay()
""")
check("the tracker overlay maps its lines to quests", rt.eval("""(function()
    local clicks = UnrealQuest:GetModule('QuestClicks')
    -- One title line plus one objective line for the watched quest.
    return clicks:GetReport().watchLinesMapped == 2
end)()"""))

check("clicking a tracker objective line follows its quest", rt.eval("""(function()
    local clicks = UnrealQuest:GetModule('QuestClicks')
    local main = UnrealQuest:GetModule('MainQuest')
    main:Clear("test")

    -- Line 2 is the objective, not the title: clicking any part of a tracked
    -- quest should follow it.
    local surface = clicks.surfaces[2]
    if not surface then return false end
    surface:GetScript("OnClick")()

    return main:GetReport().title == "Kobold Camp Cleanup"
        and clicks:GetReport().watchClicks == 1
end)()"""))

# --- The marker ----------------------------------------------------------------------
check("with no facing source at all the marker stays hidden and says why", rt.eval("""(function()
    local waypoint = UnrealQuest:GetModule('Waypoint')
    local heading = UnrealQuest:GetModule('PlayerHeading')
    UQ_TEST_ENABLE_CLIENT_FACING(nil)
    heading.heading = nil
    heading.headingAt = nil

    waypoint:Refresh()
    return waypoint.shown == false and waypoint:GetReport().hiddenReason == "noFacing"
end)()"""),
"a client with no readable facing must produce an honest hidden marker, not a marker pointing north")

check("movement is the direction source, since this client has no facing at all", rt.eval("""(function()
    local heading = UnrealQuest:GetModule('PlayerHeading')
    UQ_TEST_ENABLE_CLIENT_FACING(nil)
    heading.heading = nil
    heading.referenceX = nil
    UQ_TEST_MOVING = true

    -- Walk due west, far enough past MIN_FIX_YARDS for one fix.
    UQ_TEST_PLAYER_POSITION = { 0.42, 0.65 }
    heading:Sample(12)
    UQ_TEST_PLAYER_POSITION = { 0.40, 0.65 }
    heading:Sample(12)

    local facing, source = heading:Get()
    UQ_TEST_PLAYER_POSITION = { 0.42, 0.65 }
    UQ_TEST_MOVING = false
    return facing ~= nil and source == "movement"
        and math.abs(facing - math.pi / 2) < 0.01
end)()"""))

check("the movement heading survives the client's one-yard position quantization", rt.eval("""(function()
    local heading = UnrealQuest:GetModule('PlayerHeading')
    UQ_TEST_ENABLE_CLIENT_FACING(nil)
    heading.heading = nil
    heading.referenceX = nil
    heading.movementFixes = 0

    -- Walk north-west at Vanilla run speed, sampled at the marker's real 20Hz,
    -- through a client that rounds every coordinate to a whole yard.
    --
    -- This is the case that breaks a naive estimator rather than merely making
    -- it noisy: per-sample displacement is 0.35 yards, so after rounding, each
    -- individual step reads as 0 or 1 whole yards per axis and a bearing taken
    -- from one step lands on a multiple of 45 degrees. The probe recorded
    -- exactly that -- (-1,0) and (-1,-1) yard steps on one straight walk.
    --
    -- The assertion is on the WORST deviation over the walk, not the final
    -- reading. A jittering estimator passes a final-value check by luck: its
    -- readings straddle the true bearing, so any single sample has a fair
    -- chance of sitting near it. Measured worst-case steady-state error is
    -- 6 degrees at the 8-yard baseline and 27 at the naive 0.6-yard one.
    UQ_TEST_QUANTIZE_YARDS = true
    UQ_TEST_MOVING = true
    local trueBearing = math.pi / 4        -- north-west
    local perTick = 7 / 20                 -- yards
    local east = -perTick * math.sqrt(0.5)
    local south = -perTick * math.sqrt(0.5)

    UQ_TEST_PLAYER_POSITION = { 0.50, 0.50 }
    local worst = 0
    local readings = 0
    for tick = 1, 160 do                   -- eight seconds
        heading:Sample(12)
        UQ_TEST_PLAYER_POSITION = {
            UQ_TEST_PLAYER_POSITION[1] + east / UQ_TEST_ZONE_YARDS[1],
            UQ_TEST_PLAYER_POSITION[2] + south / UQ_TEST_ZONE_YARDS[2],
        }
        UQ_TEST_CLOCK = UQ_TEST_CLOCK + 0.05

        -- Skip the first two seconds: convergence is not jitter.
        if tick > 40 then
            local facing = heading:Get()
            if facing then
                readings = readings + 1
                local err = math.abs(heading.NormalizeDelta(facing - trueBearing))
                if err > worst then worst = err end
            end
        end
    end

    UQ_TEST_QUANTIZE_YARDS = false
    UQ_TEST_MOVING = false
    UQ_TEST_PLAYER_POSITION = { 0.42, 0.65 }

    -- 12 degrees: comfortably above the measured 6, comfortably below the 27 a
    -- per-sample baseline produces.
    return readings > 50 and worst < 0.21 and heading.movementFixes > 0
end)()"""),
"a bearing taken per 20Hz sample swings +/-45 degrees under the client's one-yard quantization; the multi-yard baseline is what prevents it")

check("blending a heading takes the short way round north", rt.eval("""(function()
    local h = UnrealQuest:GetModule('PlayerHeading')
    -- From 350 degrees to 10 degrees is twenty degrees clockwise, not 340 the
    -- other way. Blending the raw numbers would swing the marker through most
    -- of a full turn to move it a little.
    local from = math.rad(350)
    local to = math.rad(10)
    local blended = h.Blend(from, to, 0.5)
    local delta = math.abs(h.NormalizeDelta(blended - math.rad(0)))
    return delta < 0.01
end)()"""))

check("standing still marks the heading stale via IsPlayerMoving", rt.eval("""(function()
    local heading = UnrealQuest:GetModule('PlayerHeading')
    UQ_TEST_ENABLE_CLIENT_FACING(nil)
    heading.heading = math.pi / 2
    heading.headingAt = UQ_TEST_CLOCK
    heading.source = "movement"

    UQ_TEST_MOVING = true
    local _, _, movingStale = heading:Get()
    UQ_TEST_MOVING = false
    heading:Sample(12)
    local _, _, stoppedStale = heading:Get()

    -- A running player has a current heading however old it is; a player who
    -- stopped one tick ago has a stale one. No age threshold can tell those
    -- apart, which is why IsPlayerMoving carries it.
    return movingStale == false and stoppedStale == true
end)()"""))

check("a client facing source is preferred over the movement fallback", rt.eval("""(function()
    local heading = UnrealQuest:GetModule('PlayerHeading')
    UQ_TEST_ENABLE_CLIENT_FACING(1.234)
    local facing, source = heading:Get()
    return source == "GetPlayerFacing" and math.abs(facing - 1.234) < 0.001
end)()"""))

check("the marker is placed when a quest is followed and the heading is known", rt.eval("""(function()
    local waypoint = UnrealQuest:GetModule('Waypoint')
    local target = UnrealQuest:GetModule('QuestTarget')
    local heading = UnrealQuest:GetModule('PlayerHeading')
    local state = UnrealQuest:GetModule('QuestState')
    local main = UnrealQuest:GetModule('MainQuest')

    local quest = state:GetQuestByTitle("Kobold Camp Cleanup")
    main:Set(quest.titleKey)

    local resolved = target:Resolve(quest, 12)
    local east, south = target:ToYards(12,
        resolved.x - 42, resolved.y - 65)
    local bearing = heading.BearingFromYards(east, south)

    -- Face straight at it: the marker belongs at the centre of the screen.
    UQ_TEST_ENABLE_CLIENT_FACING(bearing)
    waypoint:Refresh()
    local centred = waypoint.shown and math.abs(waypoint.lastRelativeAngle) < 0.001

    return centred
end)()"""))

check("turning right moves the marker left, and vice versa", rt.eval("""(function()
    local waypoint = UnrealQuest:GetModule('Waypoint')
    local target = UnrealQuest:GetModule('QuestTarget')
    local heading = UnrealQuest:GetModule('PlayerHeading')
    local state = UnrealQuest:GetModule('QuestState')

    local quest = state:GetQuestByTitle("Kobold Camp Cleanup")
    local resolved = target:Resolve(quest, 12)
    local east, south = target:ToYards(12, resolved.x - 42, resolved.y - 65)
    local bearing = heading.BearingFromYards(east, south)

    -- Turning the player anticlockwise (towards west) leaves the target to
    -- the player's right, so the marker must move right of centre.
    UQ_TEST_ENABLE_CLIENT_FACING(bearing + 0.3)
    waypoint:Refresh()
    local frame = getglobal("UnrealQuestWaypointMarker")
    local rightOffset = frame.point[4]

    UQ_TEST_ENABLE_CLIENT_FACING(bearing - 0.3)
    waypoint:Refresh()
    local leftOffset = frame.point[4]

    return rightOffset > 0 and leftOffset < 0
end)()"""))

check("the marker reports a real yard distance", rt.eval("""(function()
    local waypoint = UnrealQuest:GetModule('Waypoint')
    local report = waypoint:GetReport()
    -- Elwynn is 3470 yards across, so any in-zone target is under that.
    return type(report.distanceYards) == "number"
        and report.distanceYards > 0 and report.distanceYards < 4200
end)()"""))

check("the marker carries exactly one BACKGROUND texture with a real file path", rt.eval("""(function()
    local frame = getglobal("UnrealQuestWaypointMarker")
    local texture = frame.texture
    return texture ~= nil and texture:GetDrawLayer() == "BACKGROUND"
        and type(texture:GetTexture()) == "string"
        and texture.allPoints == frame
end)()"""),
"the confirmed material contract: one BACKGROUND texture, a real file, SetAllPoints")

check("the marker label inherits a real font template", rt.eval("""(function()
    local frame = getglobal("UnrealQuestWaypointMarker")
    local label = frame.fontString
    -- A FontString created without a font template renders nothing while
    -- reporting no failure -- the same silent-invisibility class as this
    -- client's numeric map textures. SetFontObject is not in the documented
    -- FontString surface here, so the template has to arrive via
    -- CreateFontString, which is what the confirmed map pin labels do.
    return label ~= nil and label.inherits == "GameFontNormalSmall"
end)()"""))

check("the marker hides when nothing is followed", rt.eval("""(function()
    local waypoint = UnrealQuest:GetModule('Waypoint')
    UnrealQuest:GetModule('MainQuest'):Clear("test")
    waypoint:Refresh()
    return waypoint.shown == false and waypoint:GetReport().hiddenReason == "noMainQuest"
end)()"""))

check("waypoint diagnostics are persisted for a post-mortem", rt.eval("""(function()
    local waypoint = UnrealQuest:GetModule('Waypoint')
    waypoint:RecordDiagnostics()
    local section = UnrealQuestDB.waypointDiagnostics
    return section ~= nil and type(section.placements) == "number"
        and section.placements > 0 and type(section.hiddenReason) == "string"
end)()"""))

check("the waypoint runs on two jobs at two cadences", rt.eval("""(function()
    local jobs = UnrealQuest:GetModule('Driver'):GetJobReport()
    local fast, slow
    for _, job in ipairs(jobs) do
        if job.name == "hud.waypoint" then fast = job end
        if job.name == "hud.waypointcontext" then slow = job end
    end
    -- The expensive half (map view + area component reduction) must not run at
    -- the marker's rate; that is the stuttering failure mode this client has
    -- already been reported with.
    return fast ~= nil and slow ~= nil and slow.interval > fast.interval
end)()"""))

check("/uq main runs", rt.eval("function() return pcall(SlashCmdList.UNREALQUEST, 'main') end")())
check("/uq waypoint runs", rt.eval("function() return pcall(SlashCmdList.UNREALQUEST, 'waypoint') end")())
check("/uq main <fragment> follows a quest", rt.eval("""(function()
    SlashCmdList.UNREALQUEST('main camp cleanup')
    return UnrealQuest:GetModule('MainQuest'):GetReport().title == "Kobold Camp Cleanup"
end)()"""))
check("/uq main clear stops following", rt.eval("""(function()
    SlashCmdList.UNREALQUEST('main clear')
    return UnrealQuest:GetModule('MainQuest'):Get() == nil
end)()"""))

print("slash commands")
rt.execute("""
    UQ_TEST_LOG = {
        { "Elwynn Forest", 0, nil, 1, nil, nil },
        { "Kobold Camp Cleanup", 6, nil, nil, nil, nil,
          { { "Kobold Vermin slain: 4/10", "monster", nil } } },
        { "Sharptalon's Claw", 30, nil, nil, nil, 1,
          { { "Sharptalon's Claw: 1/1", "item", 1 } } },
    }
    UnrealQuest:GetModule('QuestState'):Scan()
""")
for cmd in ("", "status", "quests", "events", "map", "db"):
    ok = rt.eval("function(c) return pcall(SlashCmdList.UNREALQUEST, c) end")(cmd)
    check(f"/uq {cmd or '(help)'} runs", ok)

rt.execute("RemoveQuestWatch(2); SlashCmdList.UNREALQUEST('track kobold')")
check("/uq track title fragment tracks quest", rt.eval("IsQuestWatched(2) == true"))
rt.execute("SlashCmdList.UNREALQUEST('toggle 2')")
check("/uq toggle index untracks quest", rt.eval("IsQuestWatched(2) == false"))
rt.execute("SlashCmdList.UNREALQUEST('untrack claw')")
check("/uq untrack title fragment is safe when not tracked", rt.eval("IsQuestWatched(3) == false"))
rt.execute("""
    table.insert(UQ_TEST_LOG, { "Kobold Patrol", 7, nil, nil, nil, nil, {} })
    UnrealQuest:GetModule('QuestState'):Scan()
    SlashCmdList.UNREALQUEST('track kobold')
""")
check("/uq track refuses an ambiguous title fragment", rt.eval("IsQuestWatched(2) == false and IsQuestWatched(4) == false"))

print()
print("chat output sample:")
sample = rt.eval("UQ_TEST_MESSAGES")
lines = [sample[i] for i in range(1, min(len(sample), 400) + 1)]
for line in lines[-28:]:
    print("   ", line)

print()
if failures:
    print(f"{len(failures)} FAILURE(S): {failures}")
    sys.exit(1)
print("all checks passed")
