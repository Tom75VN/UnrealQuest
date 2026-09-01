--[[
UnrealQuest / HUD/PlayerHeading.lua

Which way the player is facing, in radians, or an honest nil.

## Two sources, and which one is the mechanism

`GetPlayerFacing()` is the mechanism. The updated client documents it as
returning the CHARACTER's rotation in radians, and that is exactly the input
the HUD marker was missing: a real facing, current while the player stands
still and turns on the spot.

Movement is the fallback, and it is not vestigial. It runs on every sample
even when the facing reads fine, because it does two jobs:

  * it covers a build without the symbol -- the PRECEDING build of this client
    had no readable facing by any route, measured rather than assumed
    (UnrealRuntimeProbe 1.37.0, group `facing`, 2026-08-22: `GetPlayerFacing`,
    every camera getter, `WorldToScreen` and `MiniMapCompassRing` all absent;
    Minimap has seven children and none is a Model; `CreateFrame("Model")`
    carries `SetFacing` and `SetRotation` but **not** `GetFacing`, so the
    technique the installed pfQuest uses on Vanilla had no method to call). A
    downgraded client must degrade, not point north.
  * it is the yardstick the facing's angle convention is measured against.
    See below -- that is the part worth reading before changing anything here.

A movement heading carries two properties a facing does not, and callers still
see them through `Get`'s `source` and `stale` returns:

  * it is a **heading, not a facing**. It reports which way the player is
    *moving*, which differs from where they are looking whenever they strafe,
    walk backwards, or stand still and turn on the spot.
  * it says **nothing while the player stands still**. The last measured
    heading is held and reported stale rather than decaying to north, because a
    marker that swings north when you stop is worse than one that holds.

Neither applies when the source is `GetPlayerFacing`: that reading is never
stale and turning on the spot is visible.

## The convention is checked, not assumed

`GetPlayerFacing` is `documented`, not `verified`. Nothing has probed its zero
axis, its rotation direction or its wrap point, and those three decide whether
the marker points at the target or away from it. A client that measures
rotation clockwise from east -- which is what an Unreal yaw would be -- would
produce a marker that looks plausible and is wrong everywhere.

So the addon assumes the convention this addon and the Vanilla API surface both
use (0 = north, increasing towards west), and then **measures whether the
assumption holds** rather than trusting it. Every movement fix produces a
bearing in the known convention; comparing it against the raw client reading at
that moment gives the transform between them. Two hypotheses are voted on at
once -- that the client counts the same way round (`heading - raw`) and that it
counts the opposite way (`heading + raw`) -- in eighth-turn buckets, and the
winner is adopted once it leads the runner-up by a clear margin.

Three properties make the vote work where a single comparison would not:

  * **a modal vote survives strafing.** A single fix cannot tell forward from
    backwards or sideways, and the estimator has no way to. But backpedalling
    lands in the half-turn bucket and strafing in the quarter-turn ones, so
    they scatter into other buckets and lose to the forward majority instead of
    poisoning an average.
  * **the wrong hypothesis cannot concentrate.** If the client counts the same
    way round, `heading + raw` varies with the heading itself and smears across
    every bucket, so the lead margin is what separates a real answer from a
    coincidence rather than a threshold picked by feel.
  * **a tie changes nothing.** A player who only ever runs in a straight line
    makes both hypotheses concentrate equally, so no lead is established and
    the assumed identity convention stays in force -- which is what a tie
    should mean. The vote never has to guess, because not settling is a
    perfectly good outcome.

Eighth-turn resolution is deliberate: a convention differs from another by a
quarter turn and a sign, never by six degrees, and the residual quantization
error in a movement fix is worth about six. Buckets fine enough to resolve
those six degrees would only let noise split the vote. The consequence, and it
is a real limit rather than an oversight: a client whose zero axis is offset by
some angle that is NOT a multiple of 45 degrees would be quantized to the
nearest one and left wrong by up to 22.5. Nothing suggests such a client
exists, and a probe would settle it properly.

The settled answer persists, so the marker is right from the first tick of the
next session rather than after another minute of running, and `/uq waypoint`
prints it -- so what the vote measured can be read back and turned into a real
probe result for the compatibility database.

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
west. That is the convention every Vanilla facing source uses, and the one the
raw client reading is assumed to share until the vote above says otherwise.
Everything this module RETURNS is in it; `Client.GetPlayerFacing` is the only
thing here that is not, and it never leaves this file unconverted.
]]

-- Gating note: this module has no OnInit and no OnEnable, and schedules
-- nothing. `Sample` and `Get` are called only from HUD/Waypoint.lua's driver
-- job, so it is inert by construction whenever the `mainQuestWaypoint` feature
-- gate is off. Do not give it its own driver job -- and note that this is also
-- why the persisted convention is loaded lazily from those two entry points
-- rather than from an OnInit that does not exist.

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

-- Convention calibration ------------------------------------------------------

-- Eighth-turn buckets. Fine enough to separate every convention a client could
-- plausibly use -- they differ by quarter turns and a sign -- and coarse enough
-- that the estimator's own residual error, about six degrees over the chosen
-- baseline, cannot split one vote across two buckets. See the header for why
-- finer would be worse rather than better.
local CONVENTION_BUCKETS = 8
local CONVENTION_BUCKET_RADIANS = TWO_PI / CONVENTION_BUCKETS

-- What it takes to overrule the assumed convention. The margin, not the count,
-- is what carries the decision: the losing hypothesis smears across all eight
-- buckets, so a genuine answer pulls ahead quickly and a coincidence does not
-- pull ahead at all. Eight fixes is roughly ten seconds of running.
local CONVENTION_MIN_VOTES = 8
local CONVENTION_MIN_LEAD = 4

-- Where the settled answer is kept between sessions. Two small integers and the
-- bucket count they were measured at -- never a path, per the SavedVariables
-- backslash hazard. The bucket count is stored so that changing the resolution
-- above discards old answers instead of reinterpreting them at the new scale.
local CONVENTION_SECTION = "facingConvention"

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

-- The assumed convention until a vote overrules it: the client reading is taken
-- to be this addon's own convention already. `settled` distinguishes "measured
-- and it agrees" from "never measured", which /uq waypoint prints, because
-- those are very different things to read in a bug report.
PlayerHeading.conventionSign = 1
PlayerHeading.conventionBucket = 0
PlayerHeading.conventionSettled = false
PlayerHeading.conventionVotes = nil
PlayerHeading.conventionSamples = 0
PlayerHeading.conventionLoaded = false

local function QuestTarget()
    return UQ:GetModule("QuestTarget")
end

local function Config()
    return UQ:GetModule("Config")
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
    self:LoadConvention()

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
            -- The bearing is the one direction here that is known to be in
            -- this addon's convention, so this is the only moment at which the
            -- client's convention can be measured rather than assumed. The RAW
            -- reading is what gets voted on -- feeding it back through
            -- ApplyConvention would only ever confirm the transform already in
            -- force.
            self:VoteConvention(bearing, Client.GetPlayerFacing())

            -- Blended into the fallback heading whether or not a client facing
            -- is available. Keeping the estimator warm costs one blend per fix
            -- and means a client that loses the symbol has something current
            -- to fall back to instead of starting from nothing.
            self.heading = PlayerHeading.Blend(self.heading, bearing, FIX_BLEND)
            self.headingAt = now
            if not Client.GetPlayerFacingSource() then
                self.source = "movement"
            end
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

-- Convention calibration ------------------------------------------------------
--
-- Turns a raw `GetPlayerFacing` reading into this addon's convention using
-- whatever transform is currently in force -- the assumed identity one, or the
-- one a vote settled on. The two degrees of freedom are the direction the
-- client counts in and the bucket its zero axis sits at; nothing else is
-- correctable from a bearing comparison, and nothing else needs to be.
function PlayerHeading:ApplyConvention(raw)
    if type(raw) ~= "number" or raw ~= raw then
        return nil
    end
    local value = raw
    if self.conventionSign < 0 then
        value = -value
    end
    return PlayerHeading.Normalize(
        value + self.conventionBucket * CONVENTION_BUCKET_RADIANS)
end

-- Which bucket an angle falls in, rounded to the nearest rather than floored:
-- a true offset of zero must land in bucket 0 from both sides, not split
-- between bucket 0 and bucket 7 according to the sign of the noise.
function PlayerHeading.ConventionBucket(angle)
    local normalized = PlayerHeading.Normalize(angle)
    if not normalized then
        return nil
    end
    local index = math.floor(normalized / CONVENTION_BUCKET_RADIANS + 0.5)
    while index >= CONVENTION_BUCKETS do
        index = index - CONVENTION_BUCKETS
    end
    while index < 0 do
        index = index + CONVENTION_BUCKETS
    end
    return index
end

-- Casts one movement fix's vote on both hypotheses.
--
-- `bearing` is a travel direction already in this addon's convention, and
-- `raw` is what the client reported at the same moment. Voting stops once the
-- question is settled: continuing would cost a table walk every fix to
-- re-decide something that cannot change within a session, and a long stretch
-- of backpedalling could eventually overturn a correct answer.
function PlayerHeading:VoteConvention(bearing, raw)
    if self.conventionSettled then
        return
    end
    if type(bearing) ~= "number" or type(raw) ~= "number" then
        return
    end
    local votes = self.conventionVotes
    if not votes then
        votes = { same = {}, mirrored = {} }
        self.conventionVotes = votes
    end

    -- `same`: the client counts the way this addon does, so the offset is
    -- bearing - raw. `mirrored`: it counts the other way, so negating the
    -- reading first leaves bearing + raw. Exactly one of these is constant
    -- across headings; the other varies with the heading and cannot cluster.
    local same = PlayerHeading.ConventionBucket(bearing - raw)
    local mirrored = PlayerHeading.ConventionBucket(bearing + raw)
    if same == nil or mirrored == nil then
        return
    end
    votes.same[same] = (votes.same[same] or 0) + 1
    votes.mirrored[mirrored] = (votes.mirrored[mirrored] or 0) + 1
    self.conventionSamples = self.conventionSamples + 1
    self:SettleConvention()
end

-- Adopts the leading hypothesis, or leaves the assumption in force.
--
-- Ties are resolved towards doing nothing rather than towards a coin flip:
-- `same` is scanned first and a later cell must strictly beat what is already
-- held, so a run that cannot separate the two hypotheses -- a player who only
-- ever travels one direction -- ends with no lead and no change.
function PlayerHeading:SettleConvention()
    local votes = self.conventionVotes
    if self.conventionSettled or not votes then
        return
    end
    if self.conventionSamples < CONVENTION_MIN_VOTES then
        return
    end

    local bestSign, bestBucket, bestCount = 1, 0, -1
    local secondCount = 0
    local sign = 1
    local tally = votes.same
    local pass = 1
    while pass <= 2 do
        local bucket, count
        for bucket, count in pairs(tally) do
            if count > bestCount then
                secondCount = bestCount
                bestSign, bestBucket, bestCount = sign, bucket, count
            elseif count > secondCount then
                secondCount = count
            end
        end
        pass = pass + 1
        sign = -1
        tally = votes.mirrored
    end

    if bestCount < CONVENTION_MIN_VOTES then
        return
    end
    if (bestCount - secondCount) < CONVENTION_MIN_LEAD then
        return
    end

    self.conventionSign = bestSign
    self.conventionBucket = bestBucket
    self.conventionSettled = true
    self.conventionVotes = nil
    self:SaveConvention()
end

-- Reads back an answer settled in an earlier session, so the marker is right
-- from the first tick rather than after another minute of running. Lazy rather
-- than in an OnInit, because this module deliberately has none -- see the
-- gating note at the top.
function PlayerHeading:LoadConvention()
    if self.conventionLoaded then
        return
    end
    self.conventionLoaded = true

    local config = Config()
    if not config or not config.GetSection then
        return
    end
    local section = config:GetSection(CONVENTION_SECTION)
    if type(section) ~= "table" then
        return
    end
    -- A stored answer measured at a different bucket resolution is discarded,
    -- not rescaled: the bucket index means nothing without the count it was
    -- taken against.
    if section.buckets ~= CONVENTION_BUCKETS then
        return
    end
    if section.sign ~= 1 and section.sign ~= -1 then
        return
    end
    if type(section.bucket) ~= "number" then
        return
    end
    local bucket = math.floor(section.bucket)
    if bucket < 0 or bucket >= CONVENTION_BUCKETS then
        return
    end
    self.conventionSign = section.sign
    self.conventionBucket = bucket
    self.conventionSettled = true
end

-- One short string naming the transform in force, for the diagnostic readouts.
-- Deliberately not localized: it is a measurement, and the whole point of it is
-- that it can be pasted back into the compatibility database unchanged.
--
-- "assumed" and "measured" are the leading word because they are the part a
-- reader needs first -- an offset of 0 means something quite different when
-- nothing has been measured yet.
function PlayerHeading:ConventionLabel()
    local label
    if self.conventionSettled then
        label = "measured"
    else
        label = "assumed"
    end
    if self.conventionSign < 0 then
        label = label .. " mirrored"
    else
        label = label .. " direct"
    end
    return label .. " +"
        .. tostring(self.conventionBucket * (360 / CONVENTION_BUCKETS)) .. "deg"
end

function PlayerHeading:SaveConvention()
    local config = Config()
    if not config then
        return
    end
    config:SetSectionEntry(CONVENTION_SECTION, "sign", self.conventionSign)
    config:SetSectionEntry(CONVENTION_SECTION, "bucket", self.conventionBucket)
    config:SetSectionEntry(CONVENTION_SECTION, "buckets", CONVENTION_BUCKETS)
end

-- Throws the measurement away and starts over from the assumption. Nothing in
-- the addon calls this on its own -- it is what `/uq waypoint recalibrate` and
-- the offline test need in order to re-run a vote within one session.
function PlayerHeading:ResetConvention()
    self.conventionSign = 1
    self.conventionBucket = 0
    self.conventionSettled = false
    self.conventionVotes = nil
    self.conventionSamples = 0
    self.conventionLoaded = true

    local config = Config()
    if config then
        config:SetSectionEntry(CONVENTION_SECTION, "sign", nil)
        config:SetSectionEntry(CONVENTION_SECTION, "bucket", nil)
        config:SetSectionEntry(CONVENTION_SECTION, "buckets", nil)
    end
end

-- Reading it ------------------------------------------------------------------

-- Returns heading, source, stale.
--
-- `stale` is not a failure: it means the value is the last one measured rather
-- than a current reading, and the caller is expected to SHOW that rather than
-- hide it. A movement heading is stale the moment the player stops; a client
-- facing never is, which is the whole reason the marker can be trusted now.
function PlayerHeading:Get()
    self:LoadConvention()

    local raw, clientSource = Client.GetPlayerFacing()
    local clientFacing = self:ApplyConvention(raw)
    if clientFacing then
        -- The real facing, and the reason this feature is on at all. It is
        -- written into the estimator's own state as well so that losing the
        -- symbol mid-session degrades from the last known facing rather than
        -- from whatever the estimator last managed on its own.
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
    local raw = Client.GetPlayerFacing()
    return {
        facing = facing,
        source = source,
        stale = stale,
        moving = self.moving,
        samples = self.samples,
        movementFixes = self.movementFixes,
        clientSource = Client.GetPlayerFacingSource(),
        minFixYards = MIN_FIX_YARDS,

        -- The convention, reported in the terms a probe would record it in:
        -- which way the client counts, and how far its zero axis sits from
        -- north. `settled` separates "measured, and it agrees" from "never
        -- measured" -- printing an offset of zero for both would hide exactly
        -- the thing worth knowing.
        rawFacing = raw,
        conventionSettled = self.conventionSettled,
        conventionSign = self.conventionSign,
        conventionOffsetDegrees =
            self.conventionBucket * (360 / CONVENTION_BUCKETS),
        conventionSamples = self.conventionSamples,
    }
end
