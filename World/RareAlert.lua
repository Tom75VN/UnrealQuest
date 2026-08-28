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
-- default range is 150.
local POLL_INTERVAL = 1.0

-- The distance on a shown card is rewritten this often, so it counts down as
-- the player walks instead of freezing at whatever it was when the card went
-- up. 0.05 is a ceiling, not a promise: this runs on the addon's ONE shared
-- driver (Core/Driver.lua), which ticks with the client's own frames, so a
-- client rendering at 30fps refreshes it every ~33ms and one at 15fps every
-- ~67ms. A job cannot run more often than the client draws, and no second
-- OnUpdate frame exists to make it.
--
-- A tick costs one GetPlayerMapPosition and a square root: the zone and its
-- yard dimensions are carried over from the pass that raised the card, so
-- nothing here re-resolves the map twenty times a second.
local LIVE_INTERVAL = 0.05

-- Yards. 150 puts the card up while the spawn is still well ahead -- a bit
-- under a third of the minimap's measured 466.6-yard zoom-0 span, so the
-- creature's own minimap dot is comfortably on screen when the alert lands.
local DEFAULT_RANGE = 150
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

-- The line the card OPENS on: what happened, before who it was. One key per
-- rank rather than one pattern with the rank substituted, because a language
-- with grammatical gender cannot build "a rare elite is nearby" out of a
-- sentence and a noun -- French alone needs "un rare" against "une elite
-- rare". KEYS, not text: read at file load, before the language is resolved.
local RANK_NEARBY_KEYS = {
    [RANK_ELITE] = "RARE_NEARBY_ELITE",
    [RANK_RARE_ELITE] = "RARE_NEARBY_RARE_ELITE",
    [RANK_BOSS] = "RARE_NEARBY_BOSS",
    [RANK_RARE] = "RARE_NEARBY_RARE",
}

-- Where the card sits until the player drags it somewhere else: centred under
-- the top edge, clear of the default minimap and of the native error text.
-- "/uq rare reset" brings it back here.
local DEFAULT_POINT = "TOP"
local DEFAULT_X = 0
local DEFAULT_Y = -160

local DIRECTION_KEYS = {
    N = "RARE_DIR_N", NE = "RARE_DIR_NE", E = "RARE_DIR_E", SE = "RARE_DIR_SE",
    S = "RARE_DIR_S", SW = "RARE_DIR_SW", W = "RARE_DIR_W", NW = "RARE_DIR_NW",
}

-- State ---------------------------------------------------------------------

RareAlert.frame = nil
RareAlert.shownUntil = nil
RareAlert.areaId = nil

-- Drags of the card the client accepted. A refused one warns the player on the
-- spot instead of being counted here.
RareAlert.drags = 0

-- What the shown card is about, so its distance row can be rebuilt without a
-- full scan. The zone and its yard dimensions are snapshotted here on purpose:
-- re-resolving the map twenty times a second would cost eight client calls a
-- tick, and a zone change is picked up by the next ordinary pass anyway.
RareAlert.shownEntry = nil
RareAlert.shownOthers = 0
RareAlert.shownYardsX = nil
RareAlert.shownYardsY = nil
RareAlert.shownAreaId = nil

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

-- The index carries every rank, because Map/NpcPins.lua draws all of them.
-- The ALERT is narrower, and asks the database which creatures are worth
-- interrupting the player for: the curated `meta.rares` list plus bosses,
-- never ordinary elites. See Database:IsAlertWorthy for why rank alone is the
-- wrong test here.
--
-- There is no per-rank setting. One switch turns the alert on or off and that
-- is the whole of the choice (the user's call, 2026-08-28).
function RareAlert:IsWanted(entry)
    if not entry or not entry.rank or not RANK_NAME_KEYS[entry.rank] then
        return false
    end
    local database = UQ:GetModule("Database")
    return database and database:IsAlertWorthy(entry.unitId) == true
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
    self.frame = frame
    self:ApplyStoredPosition()
    Client.SetAlertWindowClose(frame, function()
        RareAlert:Dismiss()
    end)
    -- Dragged by anywhere on the card. A refused drag is warned about
    -- visibly rather than logged: an immovable frame that says nothing is the
    -- failure this client already produced once for the tracker.
    Client.SetAlertWindowDrag(frame, function()
        if Client.StartFrameDrag(frame) then
            RareAlert.drags = RareAlert.drags + 1
        else
            UQ:Warn(UQ.L("RARE_WARN_DRAG_FAILED"))
        end
    end, function()
        Client.StopFrameDrag(frame)
        RareAlert:CapturePosition()
    end)
    return frame
end

-- Position -------------------------------------------------------------------
--
-- The player drags the card wherever they want it and it stays there, across
-- alerts and across sessions. The stored anchor is a point name and two
-- numbers and nothing else -- always UIParent-relative, because a relative
-- frame is a live object that cannot be persisted -- and it is read back
-- through Client.GetFrameAnchor, which undoes the two ways GetPoint lies on
-- this client (docs/QUEST-TRACKER.md).

function RareAlert:ApplyStoredPosition()
    local frame = self.frame
    if not frame then
        return false
    end
    local config = UQ:GetModule("Config")
    local point = config and config:Get("rareAlertPoint")
    local relativePoint = config and config:Get("rareAlertRelativePoint")
    local x = config and config:Get("rareAlertX")
    local y = config and config:Get("rareAlertY")
    if type(point) ~= "string" or type(x) ~= "number" or type(y) ~= "number" then
        return Client.PositionAlertWindow(frame, DEFAULT_POINT, DEFAULT_X, DEFAULT_Y)
    end
    return Client.SetFrameAnchor(frame, point, "UIParent",
        type(relativePoint) == "string" and relativePoint or point, x, y)
end

function RareAlert:CapturePosition()
    local frame = self.frame
    local config = UQ:GetModule("Config")
    if not frame or not config then
        return false
    end
    -- The relative frame's name is read and deliberately not stored: whatever
    -- the drag left the card anchored to is normalized to UIParent on the way
    -- in, which is what makes the stored pair of numbers mean the same thing
    -- next session.
    local point, relativeName, relativePoint, x, y = Client.GetFrameAnchor(frame)
    if type(point) ~= "string" or type(x) ~= "number" or type(y) ~= "number" then
        return false
    end
    config:Set("rareAlertPoint", point)
    config:Set("rareAlertRelativePoint",
        type(relativePoint) == "string" and relativePoint or point)
    config:Set("rareAlertX", x)
    config:Set("rareAlertY", y)
    return true
end

function RareAlert:ResetPosition()
    local config = UQ:GetModule("Config")
    if config then
        config:Set("rareAlertPoint", DEFAULT_POINT)
        config:Set("rareAlertRelativePoint", DEFAULT_POINT)
        config:Set("rareAlertX", DEFAULT_X)
        config:Set("rareAlertY", DEFAULT_Y)
    end
    if not self.frame then
        return true
    end
    return self:ApplyStoredPosition()
end

function RareAlert:Dismiss()
    self.shownUntil = nil
    self.shownEntry = nil
    if self.frame then
        Client.HideObject(self.frame)
    end
end

-- "A rare is nearby", and the rest of the distance row's wording. Both are
-- here rather than inline in Show so the live tick below rebuilds exactly the
-- string Show wrote, down to the "+2 more nearby" suffix.
function RareAlert:NearbyText(rank)
    local key = rank and RANK_NEARBY_KEYS[rank]
    if not key then
        return UQ.L("RARE_NEARBY_RARE")
    end
    return UQ.L(key)
end

function RareAlert:DistanceText(distance, dx, dy)
    local text = UQ.L("RARE_ALERT_BODY", tostring(distance), self:DirectionText(dx, dy))
    if self.shownOthers and self.shownOthers > 0 then
        text = text .. "  " .. UQ.LN("RARE_ALERT_MORE", self.shownOthers)
    end
    return text
end

-- Rewrites the distance row of a card that is already up. Runs on the shared
-- driver at LIVE_INTERVAL and does nothing at all when no card is shown, which
-- is almost always -- so it is scheduled once at enable rather than started
-- and stopped around each alert.
--
-- It deliberately does NOT re-resolve the zone. GetPlayerMapPosition answers
-- against whatever map is currently OPEN, so a player who opens the world map
-- on another zone would otherwise see the number jump to a distance measured
-- from the wrong origin. This client answers 0, 0 for a view that cannot
-- project the player, and that is the case guarded below; a genuine zone
-- change is picked up by the next ordinary pass a second later.
function RareAlert:LiveTick()
    if not self.shownUntil or not self.shownEntry or not self.frame then
        return
    end
    if not self.shownYardsX or not self.shownYardsY then
        return
    end
    local x, y = Client.GetPlayerMapPosition("player")
    if type(x) ~= "number" or type(y) ~= "number" or (x == 0 and y == 0) then
        return
    end
    local distance, dx, dy = self:NearestPoint(self.shownEntry,
        x * self.shownYardsX, y * self.shownYardsY,
        self.shownYardsX, self.shownYardsY)
    if not distance then
        return
    end
    Client.SetAlertWindowDistance(self.frame,
        self:DistanceText(math.floor(distance + 0.5), dx, dy))
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

    self.shownEntry = entry
    self.shownOthers = others or 0

    Client.SetAlertWindowText(frame, self:NearbyText(entry.rank), name, subtitle,
        self:DistanceText(distance, dx, dy))
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
        if self:IsWanted(entry) then
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
        self.shownYardsX, self.shownYardsY = yards[1], yards[2]
        self.shownAreaId = areaId
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
        if self:IsWanted(entry) then
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
    self.shownYardsX, self.shownYardsY = yards[1], yards[2]
    self.shownAreaId = areaId
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
    driver:Schedule("world.rarealert.live", LIVE_INTERVAL, function()
        RareAlert:LiveTick()
    end)
end
