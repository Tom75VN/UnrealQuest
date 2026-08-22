--[[
UnrealQuest / Map/MapContext.lua

Map identification and the verified current-zone coordinate boundary.

Measured evidence now establishes the conservative first slice: after the map
is initialized to the player zone, GetPlayerMapPosition returns non-zero UVs;
GetZoneText resolves Elwynn Forest uniquely to area ID 12; and an addon-owned
coloured child renders on the fullscreen map while its view changes. The tile
file name "Elwynn" still does not itself join to "Elwynn Forest", and child
area/continent transforms remain unverified. This module therefore converts
only direct coordinates in the player's uniquely resolved current area, and
only while the current map view can project the player.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local MapContext = UQ:NewModule("MapContext")

MapContext.zoneNameIndex = nil

local function Database()
    return UQ:GetModule("Database")
end

-- Reverse index from normalized area name to area ID, built from the static
-- database. Built on demand: nothing polls it.
function MapContext:BuildZoneNameIndex()
    if self.zoneNameIndex then
        return self.zoneNameIndex
    end
    local database = Database()
    if not database or not database.available then
        return nil
    end

    local names = database:GetZoneNames()
    if not names then
        return nil
    end

    local index = {}
    for zoneId, name in pairs(names) do
        local key = UQ.NameKey(name)
        if key then
            local bucket = index[key]
            if not bucket then
                bucket = {}
                index[key] = bucket
            end
            table.insert(bucket, zoneId)
        end
    end
    self.zoneNameIndex = index
    return index
end

-- Best-effort area ID for a client-supplied name. Returns the ID and how it was
-- reached, or nil plus the reason. Callers must treat a hit as a hypothesis.
function MapContext:ResolveAreaId(name)
    if type(name) ~= "string" or name == "" then
        return nil, "noName"
    end
    local index = self:BuildZoneNameIndex()
    if not index then
        return nil, "noDatabase"
    end
    local key = UQ.NameKey(name)
    if not key then
        return nil, "noName"
    end
    local bucket = index[key]
    if not bucket then
        return nil, "noMatch"
    end
    if table.getn(bucket) == 1 then
        return bucket[1], "unique"
    end
    return nil, "ambiguous"
end

-- Snapshot of everything the client will tell us about the current map, with
-- the database-side resolution attempts alongside. Purely observational.
function MapContext:Inspect()
    local report = {}

    report.mapFile, report.tileHeight, report.tileWidth = Client.GetCurrentMapFile()
    report.continent = Client.GetCurrentMapContinent()
    report.zoneIndex = Client.GetCurrentMapZone()
    report.zoneText = Client.GetZoneText()
    report.subZoneText = Client.GetSubZoneText()

    local x, y = Client.GetPlayerMapPosition("player")
    report.playerX = x
    report.playerY = y

    report.areaIdFromMapFile, report.areaIdFromMapFileHow = self:ResolveAreaId(report.mapFile)
    report.areaIdFromZoneText, report.areaIdFromZoneTextHow = self:ResolveAreaId(report.zoneText)

    local database = Database()
    if database and report.areaIdFromZoneText then
        report.areaName = database:GetZoneName(report.areaIdFromZoneText)
        report.zoneTransform = database:GetZoneTransform(report.areaIdFromZoneText)
        report.zoneYards = database:GetZoneYards(report.areaIdFromZoneText)
    end

    return report
end

-- Returns the uniquely resolved player area only when the selected map view
-- can project the player. A continent or another-zone view returns nil and the
-- pin layer hides its pool rather than guessing a transform.
--
-- GetPlayerMapPosition alone does not detect a zoomed-out view: this client
-- projects the player's blue arrow onto the continent map too, whenever the
-- viewed continent is the player's own, so playerX/playerY stay non-nil while
-- zoomed out to Eastern Kingdoms and the direct-current-zone percentages were
-- being drawn straight onto the continent canvas -- reported 2026-08-23 as
-- every marker surviving a zoom-out. GetCurrentMapZone is documented
-- (OFFICIAL_CLIENT_DOCUMENTATION, capability mapZoomLevel) to return 0
-- specifically when no individual zone is selected, i.e. a continent or world
-- view, so that is checked first and independently of the player-projection
-- guard below.
function MapContext:GetCurrentZoneView()
    local report = self:Inspect()
    if not report.zoneIndex or report.zoneIndex == 0 then
        return nil, report, "continentView"
    end
    if not report.playerX or not report.playerY then
        return nil, report, "playerNotOnView"
    end
    if not report.areaIdFromZoneText then
        return nil, report, report.areaIdFromZoneTextHow or "areaUnresolved"
    end
    return report.areaIdFromZoneText, report, report.areaIdFromZoneTextHow
end

-- Converts direct database percentages to UV coordinates on the current-zone
-- map. Child-area and continent transforms remain intentionally unsupported.
function MapContext:DatabaseToCurrentMap(areaId, x, y, report)
    if type(areaId) ~= "number" or type(x) ~= "number" or type(y) ~= "number"
        or x < 0 or x > 100 or y < 0 or y > 100 then
        return nil, "invalidCoordinate"
    end
    local viewedAreaId
    if report then
        if report.playerX and report.playerY then
            viewedAreaId = report.areaIdFromZoneText
        end
    else
        viewedAreaId, report = self:GetCurrentZoneView()
    end
    if viewedAreaId ~= areaId then
        return nil, "differentArea"
    end
    return x / 100, y / 100
end

-- Places a pooled frame on the detected native world-map canvas.
function MapContext:PlaceOnWorldMap(frame, x, y)
    if Client.PositionWorldMapPin(frame, x, y) then
        return true
    end
    return nil, "canvasUnavailable"
end

-- Places a frame at a world position around the minimap. Pending measured
-- evidence: the minimap surface is known to render in a special pass beneath
-- ordinary frames on this client, and no rotation or zoom behaviour has been
-- measured.
function MapContext:PlaceOnMinimap(frame, x, y)
    return nil, "pendingVerification"
end

function MapContext:OnInit()
    UQ:DeclareCapability("mapIdentity", "verified",
        "GetZoneText uniquely joins the current player zone to area ID 12; map-file and player UVs are view-dependent")
    UQ:DeclareCapability("worldMapPins", "verified",
        "production level-120 Button pins confirmed visible in game; first slice is limited to direct current-zone coordinates")
    UQ:DeclareCapability("worldMapAreas", "verified",
        "runtime probes and production confirm 0.5-alpha file-backed tiles, edge-to-edge composition without dark bands, and one numbered marker above each quest area")
    UQ:DeclareCapability("worldMapProbeIsolation", "verified",
        "the completed questarea sequence isolated and persisted each visual property before production rendering was enabled")
    -- The CLIENT capability is measured; the addon feature is not built yet.
    -- Both halves belong in the note, because /uq status prints the state and
    -- "verified" alone would read as "there are pins on your minimap".
    UQ:DeclareCapability("minimapPins", "verified",
        "probe 1.38.0 confirmed in game: children of Minimap render with the world-map contract, the mask does not clip them, and the zoom-0 span is 466.6 yards across a 140px minimap; IsIndoors is absent so the indoor scale cannot be selected; NO pin layer is implemented yet")
    UQ:DeclareCapability("mapZoomLevel", "documented",
        "GetCurrentMapZone is documented to return 0 when no individual zone is selected (continent or world view); used to hide the pin layer on zoom-out since GetPlayerMapPosition alone does not detect it -- the client also projects the player onto a same-continent view")
end
