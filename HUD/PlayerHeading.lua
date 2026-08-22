--[[
UnrealQuest / HUD/PlayerHeading.lua

Which way the player is heading, in radians, or an honest nil.

**This client has no readable player facing. That is measured, not assumed.**
UnrealRuntimeProbe 1.37.0 (group `facing`, 2026-08-22) found every candidate
absent: `GetPlayerFacing`, every camera getter, `WorldToScreen`,
`MiniMapCompassRing`. The Minimap has seven children and none is a Model, and
`CreateFrame("Model")` carries `SetFacing` and `SetRotation` but **not**
`GetFacing` -- so the technique the installed pfQuest uses on Vanilla has no
method to call here. A 60-sample run recorded the player turning a full circle
with every candidate unchanged. The facing exists inside the engine, since
`UpdateWorldMapArrowFrames` is documented to rotate the arrow to it; nothing
hands it to Lua.

So movement is the mechanism, not the fallback. Two consequences the caller
must respect and must never paper over:

  * it is a **heading, not a facing**. It reports which way the player is
    *moving*, which differs from where they are looking whenever they strafe,
    walk backwards, or stand still and turn on the spot. Turning is completely
    invisible to this addon.
  * it says **nothing while the player stands still**. The last measured
    heading is held and reported stale rather than decaying to north, because a
    marker that swings north when you stop is worse than one that holds.

## The one-yard quantization, and why the baseline is long

`GetPlayerMapPosition` is quantized to **exactly one yard** on this client.
Probe 1.37.0 recorded X moving only in steps of 0.0002215 and Y only in steps
of 0.000332 while walking through Tirisfal Glades, whose bundled dimensions are
4518.75 x 3012.5 yards -- 0.0002215 x 4518.75 = 1.000 yd, 0.000332 x 3012.5 =
1.000 yd.

That is what makes a naive implementation useless rather than merely noisy. At
20Hz a running player covers 1-2 yards per sample, so a bearing taken from one
sample is built from a displacement of one or two quantization units: the
recorded walk produced per-sample deltas of (-1,0) and (-1,-1) yards, which are
due west and north-west -- **45 degrees apart, on a straight line**.

The estimator therefore accumulates displacement from a held reference point
and only takes a bearing once the player has covered `MIN_FIX_YARDS`. Over 8
yards the same +/-1 yard of quantization is worth about 7 degrees instead of
45. The reference is re-anchored only when a fix is produced, so the sample
rate does not enter into it at all.

`IsPlayerMoving()` -- documented in the client's `Azeroth` category, and
measured by the same probe returning a real boolean that tracked standing
versus running -- decides staleness, which a time threshold alone cannot do.

Displacements are converted to yards before the angle is taken. Map percentages
are not isotropic -- a Vanilla zone map is roughly 1.5x wider than tall in
yards -- so an angle taken from raw UV deltas is skewed by up to about 19
degrees at the diagonals.

Angle convention throughout UnrealQuest: radians, 0 = north, increasing towards
west. That is the convention every Vanilla facing source uses, so a client
source needs no conversion.
]]

-- Gating note: this module has no OnInit and no OnEnable, and schedules
-- nothing. `Sample` is called only from HUD/Waypoint.lua's driver job, so it is
-- inert by construction whenever the `mainQuestWaypoint` feature gate is off --
-- which it is in the shipped build. Do not give it its own driver job.

local UQ = UnrealQuest
local Client = UQ.Client
local PlayerHeading = UQ:NewModule("PlayerHeading")

local TWO_PI = 6.2831853071796
local HALF_PI = 1.5707963267949

-- How far the player must travel before a bearing is taken.
--
-- Chosen from a parameter sweep over the client's measured one-yard
-- quantization, simulating a 20Hz walk at run speed across a range of true
-- bearings, and reading off the worst and mean angular error in steady state:
--
--     baseline   blend 1.0        blend 0.6
--     0.6 yd     45.0d / 24.0d    27.0d / 10.6d      <- the naive value
--     2   yd     18.4d / 10.1d    11.1d /  4.8d
--     6   yd      6.3d /  3.2d     3.8d /  1.8d
--     8   yd      6.0d /  1.0d     6.0d /  1.0d      <- chosen
--     16  yd      2.5d /  2.5d     2.5d /  1.2d
--
-- Bigger is steadier and slower to react; 8 yards buys single-digit worst-case
-- error at a fix roughly every 1.1 seconds at Vanilla run speed, and
-- proportionally faster mounted. The sweep lives in the scratch analysis that
-- produced these numbers, not in the addon -- what matters here is that the
-- value is measured rather than guessed.
local MIN_FIX_YARDS = 8

-- A reference point older than this is abandoned even without a fix. Without
-- it, a player who shuffles half a yard and stops leaves a reference behind
-- that silently contributes to the next real fix minutes later.
local MAX_REFERENCE_SECONDS = 6

-- New fixes are blended rather than snapped, to take the residual quantization
-- wobble out of the marker. Per the sweep above it roughly halves the mean
-- error at every baseline, and it converges in about two fixes -- a couple of
-- seconds of lag after a genuine change of direction, which is the price of
-- not having a facing API at all.
local FIX_BLEND = 0.6

-- A held heading older than this stops being reported at all. Long enough to
-- survive a pause mid-fight, short enough that it cannot silently describe a
-- direction from before a flight path.
local MAX_HELD_SECONDS = 30

PlayerHeading.source = nil
PlayerHeading.heading = nil
PlayerHeading.headingAt = nil
PlayerHeading.stale = false
PlayerHeading.referenceX = nil
PlayerHeading.referenceY = nil
PlayerHeading.referenceAt = nil
PlayerHeading.lastAreaId = nil
PlayerHeading.moving = nil
PlayerHeading.samples = 0
PlayerHeading.movementFixes = 0

local function QuestTarget()
    return UQ:GetModule("QuestTarget")
end

-- atan2 without depending on it existing. Lua 5.0's math library carries
-- math.atan2 and Vanilla additionally exposes a degree-based global atan2, but
-- the client documentation describes the environment only as "Lua
-- 5.1-compatible" and that is DOCUMENTED_NOT_RUNTIME_VERIFIED. Rather than
-- assume either, the real one is used when present and a math.atan fallback
-- covers the quadrants by hand.
local function Atan2(y, x)
    if type(math.atan2) == "function" then
        local ok, value = pcall(math.atan2, y, x)
        if ok and type(value) == "number" then
            return value
        end
    end
    if x > 0 then
        return math.atan(y / x)
    elseif x < 0 then
        if y >= 0 then
            return math.atan(y / x) + math.pi
        end
        return math.atan(y / x) - math.pi
    end
    if y > 0 then
        return HALF_PI
    elseif y < 0 then
        return -HALF_PI
    end
    return 0
end

PlayerHeading.Atan2 = Atan2

-- Normalizes any angle into [0, 2pi).
function PlayerHeading.Normalize(angle)
    if type(angle) ~= "number" or angle ~= angle then
        return nil
    end
    while angle < 0 do
        angle = angle + TWO_PI
    end
    while angle >= TWO_PI do
        angle = angle - TWO_PI
    end
    return angle
end

-- Normalizes a difference of two angles into (-pi, pi], which is what a
-- "how far left or right" reading needs: +pi/2 means a quarter turn to the
-- left, not three quarters to the right.
function PlayerHeading.NormalizeDelta(angle)
    if type(angle) ~= "number" or angle ~= angle then
        return nil
    end
    while angle <= -math.pi do
        angle = angle + TWO_PI
    end
    while angle > math.pi do
        angle = angle - TWO_PI
    end
    return angle
end

-- The bearing from one map point to another, in the addon's angle convention.
--
-- Map UV grows east along x and SOUTH along y, so north is -y. Converting to a
-- conventional maths frame gives east = +x and north = -y, and a bearing
-- measured counter-clockwise from north is then atan2(-east, north): due north
-- yields 0, due west yields +pi/2, due east yields -pi/2 (that is, 3pi/2 once
-- normalized). Those three checks are what the offline test pins.
--
-- eastYards / southYards must already be in yards, not percentages.
function PlayerHeading.BearingFromYards(eastYards, southYards)
    if type(eastYards) ~= "number" or type(southYards) ~= "number" then
        return nil
    end
    if eastYards == 0 and southYards == 0 then
        return nil
    end
    local north = -southYards
    return PlayerHeading.Normalize(Atan2(-eastYards, north))
end

-- Accumulates displacement from a held reference point and takes a bearing
-- once the player has covered enough ground for the quantization not to
-- dominate it. Called from the waypoint's driver job, never on its own timer:
-- one driver, one cadence.
--
-- `x`/`y` are optional map UVs. The waypoint already reads the player position
-- for its own bearing, so it passes that reading in rather than making a
-- second guarded client call for the same number twenty times a second.
function PlayerHeading:Sample(areaId, x, y)
    self.samples = self.samples + 1
    self.moving = Client.IsPlayerMoving()

    if type(x) ~= "number" or type(y) ~= "number" then
        x, y = Client.GetPlayerMapPosition("player")
    end
    if not x or not y or type(areaId) ~= "number" then
        -- No projection onto the current view, so this sample teaches nothing.
        -- The reference is dropped too: keeping it would eventually produce a
        -- displacement measured across a gap of unknown length.
        self:DropReference()
        return
    end

    -- Map UV is 0..1; the database and QuestTarget both work in percentages.
    local percentX = x * 100
    local percentY = y * 100
    local now = Client.Now()

    if not self.referenceX or self.lastAreaId ~= areaId then
        self:SetReference(percentX, percentY, areaId, now)
        return
    end

    local questTarget = QuestTarget()
    if not questTarget then
        return
    end
    local eastYards, southYards = questTarget:ToYards(
        areaId, percentX - self.referenceX, percentY - self.referenceY)
    if not eastYards or not southYards then
        return
    end

    local travelled = math.sqrt(eastYards * eastYards + southYards * southYards)
    if travelled >= MIN_FIX_YARDS then
        local bearing = PlayerHeading.BearingFromYards(eastYards, southYards)
        if bearing then
            self.heading = PlayerHeading.Blend(self.heading, bearing, FIX_BLEND)
            self.headingAt = now
            self.source = "movement"
            self.movementFixes = self.movementFixes + 1
        end
        self:SetReference(percentX, percentY, areaId, now)
        return
    end

    -- Not far enough yet. Hold the reference so the sample rate is irrelevant
    -- -- but not indefinitely: a reference left over from a half-yard shuffle
    -- would otherwise contribute to a fix taken much later from somewhere else
    -- entirely.
    if now and self.referenceAt and (now - self.referenceAt) > MAX_REFERENCE_SECONDS then
        self:SetReference(percentX, percentY, areaId, now)
    end
end

function PlayerHeading:SetReference(percentX, percentY, areaId, now)
    self.referenceX = percentX
    self.referenceY = percentY
    self.referenceAt = now
    self.lastAreaId = areaId
end

function PlayerHeading:DropReference()
    self.referenceX = nil
    self.referenceY = nil
    self.referenceAt = nil
end

-- Moves `from` a fraction of the way towards `to` along the SHORT arc. Blending
-- the raw numbers would take the long way round whenever a heading crosses
-- north, swinging the marker through a full turn to move it one degree.
function PlayerHeading.Blend(from, to, factor)
    if type(from) ~= "number" then
        return to
    end
    local delta = PlayerHeading.NormalizeDelta(to - from)
    if not delta then
        return to
    end
    return PlayerHeading.Normalize(from + delta * factor)
end

-- Returns heading, source, stale.
--
-- `stale` is not a failure: it means the value is the last one measured rather
-- than a current reading, and the caller is expected to SHOW that rather than
-- hide it. A movement heading is stale the moment the player stops, which on
-- this client is the normal resting state.
function PlayerHeading:Get()
    local clientFacing, clientSource = Client.GetPlayerFacing()
    if clientFacing then
        -- Measured absent on this client, kept because it costs one
        -- negative-cached lookup and makes the addon start using a real facing
        -- by itself if a future build ever exposes one.
        self.source = clientSource
        self.heading = clientFacing
        self.headingAt = Client.Now()
        self.stale = false
        return clientFacing, clientSource, false
    end

    if not self.heading then
        return nil
    end

    local now = Client.Now()
    if now and self.headingAt and (now - self.headingAt) > MAX_HELD_SECONDS then
        return nil
    end

    -- IsPlayerMoving is the real staleness signal and a time threshold is only
    -- the backstop: a player running in a straight line for ten seconds has a
    -- perfectly current heading that any age-based rule would call stale, and a
    -- player who stopped one tick ago has a stale one that no age-based rule
    -- would catch.
    local stale
    if self.moving == nil then
        stale = not (now and self.headingAt and (now - self.headingAt) < 1.0)
    else
        stale = not self.moving
    end
    self.stale = stale
    return self.heading, self.source or "movement", stale
end

function PlayerHeading:GetReport()
    local facing, source, stale = self:Get()
    return {
        facing = facing,
        source = source,
        stale = stale,
        moving = self.moving,
        samples = self.samples,
        movementFixes = self.movementFixes,
        clientSource = Client.GetPlayerFacingSource(),
        minFixYards = MIN_FIX_YARDS,
    }
end
