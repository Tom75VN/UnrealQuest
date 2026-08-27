--[[
UnrealQuest / World/RareAlert.lua

Pings the player -- a card on screen and a sound -- on walking into range of a
rare, rare-elite, boss or elite creature.

WHAT "IN RANGE" MEANS HERE, AND WHY IT CANNOT MEAN MORE
-------------------------------------------------------
It means the player is within N yards of a spawn point the bundled world data
records for that creature. It does NOT mean the creature is standing there
right now, and the addon has no way to find out whether it is:

  * this client's nameplates are not Lua widgets. A full inventory of
    WorldFrame's children found 26, all identifiable FrameXML furniture and not
    one plate (knowledge record `world.nameplates_are_not_lua_widgets`,
    BEHAVIOR_VERIFIED). There is no creature list to read;
  * no client global enumerates units in the world. The only unit tokens an
    addon can name here are "target" and "mouseover", which answer "what am I
    already looking at", not "what is near me";
  * there is no unit world position and no unit screen position by any route.

`TargetByName` would confirm presence -- it targets a nearby unit matching a
name -- but it takes the player's target to do it, mid-combat included. That is
a trade this module deliberately does not make, and the user chose the same on
2026-08-27: the alert is a proximity alert over recorded spawn data, and it
says so rather than implying a live sighting.

The honest consequence: this fires whether or not the rare is up. It is a
"there is a rare's ground here, go look" prompt.

WHAT MAKES IT CHEAP
-------------------
`Data/Database.lua` builds an area-bucketed index of every bundled creature
that carries a `rnk` AND a world coordinate -- 1182 of the 2635 ranked records,
over 1391 (creature, area) buckets -- once, in chunks on the shared driver, and
only when this module asks for it. A pass then walks one zone's bucket (nine
entries in Elwynn Forest, all ranks counted) and does flat arithmetic on
coordinate tables it does not copy.

THE ONE STRUCTURAL LIMIT
------------------------
Distances come from `MapContext:GetCurrentZoneView`, so while the world map is
browsed to a continent or another zone the player cannot be projected and the
scan pauses. That is the same gate the minimap pins and the HUD waypoint sit
behind, and `/uq rare` prints the state rather than pretending to scan. The
minimap layer's INDOOR limit does not apply here: this measures in zone yards
off the zone map, not in minimap pixels, so a cave or a town hall is scanned
like anywhere else.

WHAT THE ALERT IS NOT
---------------------
Not modal. It takes no keyboard, dims nothing, and blocks no input outside its
own small card. A creature walking past is not worth taking the player's hands
away for.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local RareAlert = UQ:NewModule("RareAlert")

-- One second. The card is worth a small delay and the player cannot outrun the
-- alert range in one tick: sprint speed is well under 20 yards a second and the
-- default range is 120.
local POLL_INTERVAL = 1.0

-- Yards. 120 puts the card up while the spawn is still comfortably ahead --
-- roughly a quarter of the minimap's measured 466.6-yard zoom-0 span, so the
-- creature's own minimap dot is on screen when the alert lands.
local DEFAULT_RANGE = 120
local MIN_RANGE = 20
local MAX_RANGE = 500

-- A creature stops counting as near only past range * this, so a player
-- standing on the boundary cannot flap in and out of it once a second.
local FORGET_FACTOR = 1.35

-- Seconds before the same creature may alert again, even after leaving and
-- re-entering range. Circling one spawn point should not re-ping every lap.
local REALERT_SECONDS = 180

-- How long the card stays up on its own.
local DEFAULT_SECONDS = 12
local MIN_SECONDS = 3
local MAX_SECONDS = 60

-- The SoundEntries kit played by default. It is a NAME, not a file: this
-- client documents PlaySound only, has no PlaySoundFile, and is silent for a
-- kit name it does not know -- so nothing here can verify that this one makes
-- a noise, and "/uq rare sound <kit>" exists so the player's ears can.
local DEFAULT_SOUND = "RaidWarning"

-- Ranks, as stored in the bundled data (Data/Database.lua:GetUnitRank turns
-- the string into one of these).
local RANK_ELITE = 1
local RANK_RARE_ELITE = 2
local RANK_BOSS = 3
local RANK_RARE = 4

-- KEYS, not text: this table is built at file load, before Core/Locale.lua has
-- resolved the language.
local RANK_NAME_KEYS = {
    [RANK_ELITE] = "RARE_RANK_ELITE",
    [RANK_RARE_ELITE] = "RARE_RANK_RARE_ELITE",
    [RANK_BOSS] = "RARE_RANK_BOSS",
    [RANK_RARE] = "RARE_RANK_RARE",
}

local DIRECTION_KEYS = {
    N = "RARE_DIR_N", NE = "RARE_DIR_NE", E = "RARE_DIR_E", SE = "RARE_DIR_SE",
    S = "RARE_DIR_S", SW = "RARE_DIR_SW", W = "RARE_DIR_W", NW = "RARE_DIR_NW",
}

-- State ---------------------------------------------------------------------

RareAlert.frame = nil
RareAlert.shownUntil = nil
RareAlert.areaId = nil

-- unitId -> true while that creature is inside the forget radius. Reset on
-- leaving the area, because the same creature in a different zone is a
-- different sighting.
RareAlert.inRange = {}

-- unitId -> GetTime of its last alert, for the re-alert cooldown. Kept across
-- zone changes on purpose: walking out and back is not new news.
RareAlert.alertedAt = {}

RareAlert.state = "idle"
RareAlert.stats = {
    alerts = 0,
    scanned = 0,
    candidates = 0,
    lastName = nil,
    lastRank = nil,
    lastDistance = nil,
    soundPlayed = 0,
}

-- Settings -------------------------------------------------------------------

function RareAlert:IsEnabled()
    local config = UQ:GetModule("Config")
    return not (config and config:Get("rareAlert") == false)
end

function RareAlert:GetRange()
    local config = UQ:GetModule("Config")
    local value = config and config:Get("rareAlertRange")
    if type(value) ~= "number" or value < MIN_RANGE or value > MAX_RANGE then
        return DEFAULT_RANGE
    end
    return value
end

function RareAlert:GetSeconds()
    local config = UQ:GetModule("Config")
    local value = config and config:Get("rareAlertSeconds")
    if type(value) ~= "number" or value < MIN_SECONDS or value > MAX_SECONDS then
        return DEFAULT_SECONDS
    end
    return value
end

function RareAlert:GetSound()
    local config = UQ:GetModule("Config")
    local value = config and config:Get("rareAlertSound")
    if type(value) ~= "string" or value == "" then
        return DEFAULT_SOUND
    end
    return value
end

-- Rank 1 is ordinary elite: 816 of the 1182 creatures in the index, and every
-- elite camp in the open world. Alerting on those by default would make the
-- card furniture, so they are opt-in and the three genuinely notable ranks --
-- 257 rare, 81 rare elite, 28 boss -- are on.
function RareAlert:WantsRank(rank)
    if not rank then
        return false
    end
    if rank == RANK_ELITE then
        local config = UQ:GetModule("Config")
        return config and config:Get("rareAlertElites") == true
    end
    return true
end

-- Geometry -------------------------------------------------------------------

-- Compass direction on the MAP, which is north-up. This is not a heading
-- relative to the player: this client has no readable player facing by any
-- route (`input.no_readable_player_facing`, BEHAVIOR_VERIFIED), so "north-east
-- of you" is the strongest true statement available and "ahead of you" would
-- be an invented one.
--
-- Map y grows DOWNWARD, so a negative dy is north.
local function Direction(dx, dy)
    local ax = dx >= 0 and dx or -dx
    local ay = dy >= 0 and dy or -dy
    local ns = dy < 0 and "N" or "S"
    local ew = dx < 0 and "W" or "E"
    -- tan(67.5 degrees); splits the circle into eight equal 45-degree sectors.
    if ay > ax * 2.414 then
        return ns
    end
    if ax > ay * 2.414 then
        return ew
    end
    return ns .. ew
end

function RareAlert:DirectionText(dx, dy)
    local key = DIRECTION_KEYS[Direction(dx, dy)]
    if not key then
        return ""
    end
    return UQ.L(key)
end

function RareAlert:RankText(rank)
    local key = RANK_NAME_KEYS[rank]
    if not key then
        return UQ.L("COMMON_UNKNOWN")
    end
    return UQ.L(key)
end

-- The card -------------------------------------------------------------------

function RareAlert:EnsureFrame()
    if self.frame then
        return self.frame
    end
    -- No "-" in the name: this client mangles hyphenated widget names.
    local frame = Client.CreateAlertWindow("UnrealQuestRareAlert")
    if not frame then
        return nil
    end
    Client.PositionAlertWindow(frame, "TOP", 0, -160)
    Client.SetAlertWindowClose(frame, function()
        RareAlert:Dismiss()
    end)
    self.frame = frame
    return frame
end

function RareAlert:Dismiss()
    self.shownUntil = nil
    if self.frame then
        Client.HideObject(self.frame)
    end
end

function RareAlert:Show(entry, distance, dx, dy, others)
    local frame = self:EnsureFrame()
    if not frame then
        return false
    end

    local database = UQ:GetModule("Database")
    local name = database and database:GetUnitName(entry.unitId)
    if type(name) ~= "string" or name == "" then
        name = UQ.L("COMMON_UNKNOWN")
    end

    local record = database and database:GetUnit(entry.unitId)
    -- `lvl` is a STRING in the bundled data and may be a range ("24-25"). It is
    -- shown as it is stored; nothing here parses it into a number.
    local level = record and record.lvl
    local subtitle
    if type(level) == "string" and level ~= "" then
        subtitle = UQ.L("RARE_ALERT_SUBTITLE_LEVEL", self:RankText(entry.rank), level)
    else
        subtitle = self:RankText(entry.rank)
    end

    local body = UQ.L("RARE_ALERT_BODY", tostring(distance), self:DirectionText(dx, dy))
    if others and others > 0 then
        body = body .. "  " .. UQ.LN("RARE_ALERT_MORE", others)
    end

    Client.SetAlertWindowText(frame, name, subtitle, body)
    Client.ShowObject(frame)

    local now = Client.Now()
    self.shownUntil = now and (now + self:GetSeconds()) or nil
    if now then
        self.alertedAt[entry.unitId] = now
    end

    if Client.PlayAlertSound(self:GetSound()) then
        self.stats.soundPlayed = self.stats.soundPlayed + 1
    end

    -- Also to chat, because the card times out and a line does not: a player
    -- who was looking at their bags still gets to know what it was.
    UQ:Print(UQ.L("RARE_ALERT_CHAT", name, self:RankText(entry.rank), tostring(distance)))

    self.stats.alerts = self.stats.alerts + 1
    self.stats.lastName = name
    self.stats.lastRank = entry.rank
    self.stats.lastDistance = distance
    return true
end

-- Scanning --------------------------------------------------------------------

function RareAlert:LeaveArea()
    self.areaId = nil
    self.inRange = {}
end

-- The nearest recorded spawn of one creature, in zone yards, or nil when none
-- of its coordinates are usable. Reads the index's coordinate tables in place
-- and allocates nothing.
function RareAlert:NearestPoint(entry, playerYardX, playerYardY, widthYards, heightYards)
    local coords = entry.coords
    local best, bestDX, bestDY
    local index = 1
    local total = table.getn(coords)
    while index <= total do
        local coordinate = coords[index]
        -- Coordinates are percentages of the zone (0-100); the player's are a
        -- fraction (0-1). The two scales are converted at the same place, once,
        -- exactly as Map/MinimapPins.lua does it.
        local dx = (coordinate[1] * widthYards / 100) - playerYardX
        local dy = (coordinate[2] * heightYards / 100) - playerYardY
        local squared = dx * dx + dy * dy
        if not best or squared < best then
            best = squared
            bestDX = dx
            bestDY = dy
        end
        index = index + 1
    end
    if not best then
        return nil
    end
    return math.sqrt(best), bestDX, bestDY
end

function RareAlert:Poll()
    if not self:IsEnabled() then
        self.state = "off"
        self:Dismiss()
        return
    end

    -- Time the card out first, so it still disappears on a pass that finds
    -- nothing or cannot scan at all.
    local now = Client.Now()
    if self.shownUntil and now and now >= self.shownUntil then
        self:Dismiss()
    end

    local database = UQ:GetModule("Database")
    local mapContext = UQ:GetModule("MapContext")
    if not database or not mapContext or not database.available then
        self.state = "unavailable"
        return
    end

    database:StartRankIndex()
    if not database:IsRankIndexReady() then
        self.state = "indexing"
        return
    end

    local areaId, report, how = mapContext:GetCurrentZoneView()
    if not areaId then
        -- The map is on a continent or another zone, so the player cannot be
        -- projected and no distance here would be a real one.
        self.state = how or "noZoneView"
        self:LeaveArea()
        return
    end

    local yards = report.zoneYards
    if type(yards) ~= "table" or type(yards[1]) ~= "number" or type(yards[2]) ~= "number" then
        self.state = "noZoneSize"
        self:LeaveArea()
        return
    end

    if self.areaId ~= areaId then
        self:LeaveArea()
        self.areaId = areaId
    end

    local bucket = database:GetAreaRankedUnits(areaId)
    if not bucket then
        self.state = "noneHere"
        self.stats.candidates = 0
        return
    end

    self.state = "scanning"
    self.stats.candidates = table.getn(bucket)

    local range = self:GetRange()
    local forget = range * FORGET_FACTOR
    local playerYardX = report.playerX * yards[1]
    local playerYardY = report.playerY * yards[2]

    -- One pass decides everything: which creatures are still near, which just
    -- arrived, and which of the arrivals is closest. Only that one raises a
    -- card; the rest are counted so the card can say how many.
    local best, bestDistance, bestDX, bestDY
    local arrivals = 0
    local index = 1
    local total = table.getn(bucket)
    while index <= total do
        local entry = bucket[index]
        if self:WantsRank(entry.rank) then
            local distance, dx, dy = self:NearestPoint(entry, playerYardX, playerYardY,
                yards[1], yards[2])
            if distance and distance <= forget then
                if distance <= range and not self.inRange[entry.unitId] then
                    local last = self.alertedAt[entry.unitId]
                    if not last or not now or (now - last) >= REALERT_SECONDS then
                        arrivals = arrivals + 1
                        if not bestDistance or distance < bestDistance then
                            best = entry
                            bestDistance = distance
                            bestDX = dx
                            bestDY = dy
                        end
                    end
                end
                if distance <= range then
                    self.inRange[entry.unitId] = true
                end
            else
                self.inRange[entry.unitId] = nil
            end
        end
        index = index + 1
    end

    self.stats.scanned = self.stats.scanned + 1

    if best then
        -- Marked in range before the card goes up, so a failed Show cannot
        -- leave the creature eligible to re-alert on every following pass.
        self.inRange[best.unitId] = true
        self:Show(best, math.floor(bestDistance + 0.5), bestDX, bestDY, arrivals - 1)
    end
end

-- Testing ---------------------------------------------------------------------

-- Raises the card on the nearest ranked creature in the zone whatever its
-- distance, so "/uq rare test" answers "does this work here" without walking
-- anywhere. Returns the creature's name, or nil and a reason.
function RareAlert:Test()
    local database = UQ:GetModule("Database")
    local mapContext = UQ:GetModule("MapContext")
    if not database or not mapContext or not database.available then
        return nil, "unavailable"
    end
    database:StartRankIndex()
    if not database:IsRankIndexReady() then
        return nil, "indexing"
    end

    local areaId, report, how = mapContext:GetCurrentZoneView()
    if not areaId then
        return nil, how or "noZoneView"
    end
    local yards = report.zoneYards
    if type(yards) ~= "table" or type(yards[1]) ~= "number" or type(yards[2]) ~= "number" then
        return nil, "noZoneSize"
    end
    local bucket = database:GetAreaRankedUnits(areaId)
    if not bucket then
        return nil, "noneHere"
    end

    local playerYardX = report.playerX * yards[1]
    local playerYardY = report.playerY * yards[2]
    local best, bestDistance, bestDX, bestDY
    local index = 1
    local total = table.getn(bucket)
    while index <= total do
        local entry = bucket[index]
        if self:WantsRank(entry.rank) then
            local distance, dx, dy = self:NearestPoint(entry, playerYardX, playerYardY,
                yards[1], yards[2])
            if distance and (not bestDistance or distance < bestDistance) then
                best = entry
                bestDistance = distance
                bestDX = dx
                bestDY = dy
            end
        end
        index = index + 1
    end

    if not best then
        return nil, "noneHere"
    end
    -- A test must not consume the real alert's cooldown, so the record of when
    -- this creature last alerted is put back exactly as it was.
    local previous = self.alertedAt[best.unitId]
    self:Show(best, math.floor(bestDistance + 0.5), bestDX, bestDY, 0)
    self.alertedAt[best.unitId] = previous
    local name = database:GetUnitName(best.unitId)
    return type(name) == "string" and name or UQ.L("COMMON_UNKNOWN"), nil
end

-- Diagnostics ------------------------------------------------------------------

function RareAlert:GetStatus()
    local database = UQ:GetModule("Database")
    return {
        enabled = self:IsEnabled(),
        elites = self:WantsRank(RANK_ELITE),
        range = self:GetRange(),
        seconds = self:GetSeconds(),
        sound = self:GetSound(),
        soundAvailable = Client.HasAlertSound(),
        state = self.state,
        areaId = self.areaId,
        indexReady = database and database:IsRankIndexReady() or false,
        indexedCreatures = database and database.rankedUnitCount or 0,
        candidates = self.stats.candidates,
        alerts = self.stats.alerts,
        scans = self.stats.scanned,
        soundPlayed = self.stats.soundPlayed,
        lastName = self.stats.lastName,
        lastRank = self.stats.lastRank and self:RankText(self.stats.lastRank) or nil,
        lastDistance = self.stats.lastDistance,
        shown = self.shownUntil ~= nil,
    }
end

-- Lifecycle ---------------------------------------------------------------------

function RareAlert:OnEnable()
    local driver = UQ:GetModule("Driver")
    if not driver then
        return
    end
    driver:Schedule("world.rarealert", POLL_INTERVAL, function()
        RareAlert:Poll()
    end)
end
