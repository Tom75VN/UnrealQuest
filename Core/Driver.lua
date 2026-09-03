--[[
UnrealQuest / Core/Driver.lua

One shared OnUpdate driver for the whole addon.

Client constraints this is built around:
  * OnUpdate handlers receive no arguments here. The frame delta is only in the
    legacy arg1 global, which every event dispatch overwrites, so a handler
    that reads arg1 stalls as soon as a non-numeric event argument lands there.
    Elapsed time is therefore derived from successive GetTime readings.
  * SetScript(type, nil) does not remove a script on this client; the slot stays
    and HasScript keeps returning true. The driver never relies on clearing a
    script and gates work behind its own enabled flag instead.
  * Newly created child frames do not reliably receive OnUpdate ticks, so there
    is exactly one driver frame, created at load, and every periodic job runs
    on it. It is parented to WorldFrame rather than UIParent so that hiding the
    game UI -- which the fullscreen map does -- cannot stop the addon's
    periodic work; see OnInit.
  * A per-tick burst of pcalls and freshly allocated closures has been reported
    as visible stuttering on this client. Jobs are stored in a flat array and
    invoked through a named function, so a tick allocates nothing.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local Driver = UQ:NewModule("Driver")

-- A reload restarts the clock, which can hand us a negative delta; a hitch or a
-- loading screen can hand us a very large one. Both are clamped so no job sees
-- a nonsense elapsed value.
local MAX_DELTA = 1.0

Driver.jobs = {}
Driver.jobsByName = {}
Driver.enabled = false
Driver.frame = nil

-- Startup stagger -------------------------------------------------------------
--
-- Every module schedules its jobs while the addon loads, so without this they
-- all fall due in the same frame and the first tick of the session runs the
-- whole addon at once -- measured at 3.68s on a driver whose worst frame after
-- that was 0.31s. The jobs named in that frame were the first fires of
-- database.index, database.giverindex, quest.scan, bag.scan, tracker.restore
-- and twenty-seven others. Each newly registered job is therefore held a few
-- more ticks than the one before it, so first fires spread out instead of
-- landing together.
--
-- The delay is counted in TICKS, not seconds, and that is the load-bearing
-- part. A loading screen ends with one enormous frame delta, which MAX_DELTA
-- clamps to a full second; a stagger expressed in seconds would be swallowed
-- whole by that single clamped tick and every job would come due together
-- anyway -- which is exactly the frame this exists to protect.
--
-- Nothing depends on the stagger for correctness. It moves a job's FIRST run
-- and nothing else: the interval after that is untouched, Wake still overrides
-- it, and the accumulator keeps filling while a job is held, so a held job
-- runs on the tick it is released rather than waiting out a fresh interval on
-- top of the delay.
local STARTUP_STAGGER_TICKS = 1

local lastClock = nil

-- Stall census ---------------------------------------------------------------
--
-- GetTime does not advance inside a frame on this client and debugprofilestop
-- always returns 1, so no job can time itself. The one thing that IS observable
-- is the interval between two ticks, which contains everything the previous
-- frame did. So each raw (unclamped) interval is charged to the set of jobs
-- that ran in the tick before it, and the worst few are kept with the job list
-- and a timestamp. A stall the addon caused names the jobs that were running;
-- a loading screen or a client-side stall names a tick that ran nothing
-- expensive, which is what distinguishes the two.
local WORST_TICKS_KEPT = 5
Driver.worstGaps = {}
Driver.tickCount = 0
Driver.firstTickAt = nil
local ranLastTick = {}
local ranLastTickJobs = {}
local ranLastTickCount = 0

-- A slow frame, for attribution. Deliberately well under the 100ms the bucket
-- averages use: a stutter reported as "two or three times a second" is not made
-- of hundred-millisecond frames, and a threshold that only catches the worst
-- ones cannot see the beat.
local SLOW_FRAME = 0.05
-- How many jobs the ranking writes out. The saved store has a per-section
-- entry cap, and nothing below the top few carries any signal anyway.
local RANKED_JOBS = 8
local ATTRIBUTION_WRITE_INTERVAL = 5
local attribution = {
    frames = 0,
    slowFrames = 0,
    slowGapSum = 0,
    slowGaps = 0,
    lastSlowAt = nil,
    writtenAt = nil,
}

local function DescribeLastTick()
    if ranLastTickCount == 0 then
        return "(none)"
    end
    local description = nil
    local index = 1
    while index <= ranLastTickCount do
        if description then
            description = description .. "," .. ranLastTick[index]
        else
            description = ranLastTick[index]
        end
        index = index + 1
    end
    return description
end

local function RecordGap(gap, now)
    local worst = Driver.worstGaps
    local total = table.getn(worst)
    if total >= WORST_TICKS_KEPT and gap <= worst[total].gap then
        return
    end
    local entry = { gap = gap, at = now, jobs = DescribeLastTick() }
    local position = total + 1
    while position > 1 and worst[position - 1].gap < gap do
        worst[position] = worst[position - 1]
        position = position - 1
    end
    worst[position] = entry
    while table.getn(worst) > WORST_TICKS_KEPT do
        table.remove(worst)
    end
    local config = UQ:GetModule("Config")
    if not config then
        return
    end
    local index = 1
    total = table.getn(worst)
    while index <= total do
        config:SetSectionEntry("driverStalls", "gap" .. tostring(index),
            string.format("%.2fs at %.1f: %s",
                worst[index].gap, worst[index].at, worst[index].jobs))
        index = index + 1
    end
end

-- The top-five list above cannot see a SUSTAINED cost: a map that renders at
-- ten frames a second is 0.1s per frame, every frame, and never enters a list
-- whose floor is the session's startup burst. So frame time is also averaged,
-- in two buckets -- map open and map closed -- because the question the census
-- exists to answer is what the drawn scene costs while it is on screen. The
-- bucket is chosen by whether the game UI is hidden, which is what the
-- fullscreen map does on this client (see the parent choice in OnInit).
local census = {
    mapOpenFrames = 0, mapOpenSum = 0, mapOpenSlow = 0, mapOpenWorst = 0,
    mapShutFrames = 0, mapShutSum = 0, mapShutSlow = 0, mapShutWorst = 0,
}
local CENSUS_SLOW_FRAME = 0.1
local censusWriteAt = nil
-- Which bucket frames are currently landing in, resampled a few times a second
-- rather than every frame. This file's own header is the reason: a per-tick
-- burst of pcalls has been reported as visible stuttering on this client, and
-- a census that cost a guarded client call every frame would be paying exactly
-- the price it exists to detect. Opening or closing the map is mis-bucketed
-- for at most a quarter second either way, which is noise against samples of
-- thousands of frames.
local CENSUS_RESAMPLE = 0.25
local censusHidden = nil
local censusSampledAt = nil

local function RecordFrame(delta, now)
    if not censusSampledAt or now - censusSampledAt >= CENSUS_RESAMPLE then
        censusSampledAt = now
        censusHidden = Client.IsGameUIHidden()
    end
    local hidden = censusHidden
    if hidden then
        census.mapOpenFrames = census.mapOpenFrames + 1
        census.mapOpenSum = census.mapOpenSum + delta
        if delta >= CENSUS_SLOW_FRAME then
            census.mapOpenSlow = census.mapOpenSlow + 1
        end
        if delta > census.mapOpenWorst then
            census.mapOpenWorst = delta
        end
    elseif hidden == false then
        census.mapShutFrames = census.mapShutFrames + 1
        census.mapShutSum = census.mapShutSum + delta
        if delta >= CENSUS_SLOW_FRAME then
            census.mapShutSlow = census.mapShutSlow + 1
        end
        if delta > census.mapShutWorst then
            census.mapShutWorst = delta
        end
    end
    -- Once a second, not once a frame: this writes into the saved store.
    if censusWriteAt and now - censusWriteAt < 1 then
        return
    end
    censusWriteAt = now
    local config = UQ:GetModule("Config")
    if not config then
        return
    end
    if census.mapOpenFrames > 0 then
        config:SetSectionEntry("driverStalls", "framesMapOpen",
            string.format("%d frames, mean %.0fms (%.0f fps), worst %.0fms, %d over 100ms",
                census.mapOpenFrames, census.mapOpenSum / census.mapOpenFrames * 1000,
                census.mapOpenFrames / census.mapOpenSum,
                census.mapOpenWorst * 1000, census.mapOpenSlow))
    end
    if census.mapShutFrames > 0 then
        config:SetSectionEntry("driverStalls", "framesMapShut",
            string.format("%d frames, mean %.0fms (%.0f fps), worst %.0fms, %d over 100ms",
                census.mapShutFrames, census.mapShutSum / census.mapShutFrames * 1000,
                census.mapShutFrames / census.mapShutSum,
                census.mapShutWorst * 1000, census.mapShutSlow))
    end
end

-- Sub-attribution inside one job.
--
-- Naming the job is not always the answer: map.worldpins does several quite
-- different things behind one schedule, and "this job is in every stall" cannot
-- say which of them. A job may therefore label what it just did, and the census
-- counts slow frames per label as well as per job.
--
-- Why the job cannot measure this itself: an interval job's accumulator absorbs
-- its own cost -- fire at t, take 60ms, and the next fire is still 250ms after
-- the last, so a pass timed against its own schedule sees nothing. Only the
-- driver, which ticks every frame, can see the frame the pass ran in. The label
-- survives until the job runs again, which is exactly what the backwards
-- charging needs: the frame being charged is the one the labelled pass ran in.
function Driver:Label(name, label)
    local job = self.jobsByName[name]
    if job then
        job.label = label
    end
end

local function ChargeLabel(job, slow)
    local label = job.label
    if not label then
        return
    end
    if not job.labelRuns then
        job.labelRuns = {}
        job.labelSlow = {}
    end
    job.labelRuns[label] = (job.labelRuns[label] or 0) + 1
    if slow then
        job.labelSlow[label] = (job.labelSlow[label] or 0) + 1
    end
end

-- One job's label breakdown, worst share of slow frames first: "rebuild 31/33,
-- reapply 1/44". Only labels that actually ran appear.
local function DescribeLabels(job)
    if not job or not job.labelRuns then
        return nil
    end
    local ranked = {}
    local label, runs
    for label, runs in pairs(job.labelRuns) do
        local slow = (job.labelSlow and job.labelSlow[label]) or 0
        local entry = { label = label, runs = runs, share = slow / runs, slow = slow }
        local position = table.getn(ranked) + 1
        while position > 1 and ranked[position - 1].share < entry.share do
            ranked[position] = ranked[position - 1]
            position = position - 1
        end
        ranked[position] = entry
    end
    local description = nil
    local index = 1
    local total = table.getn(ranked)
    if total > 4 then
        total = 4
    end
    while index <= total do
        local entry = ranked[index]
        local text = string.format("%s %d/%d", entry.label, entry.slow, entry.runs)
        if description then
            description = description .. ", " .. text
        else
            description = text
        end
        index = index + 1
    end
    return description
end

-- Which job is in the stutter.
--
-- A job that runs every frame appears in every slow frame too, which says
-- nothing -- the sibling addon's own stutter hunt called that definitional
-- noise and it is the trap this has to avoid. So a job is scored by ENRICHMENT:
-- the share of slow frames it ran in, divided by its share of all frames. A job
-- that runs in 5% of frames but 90% of the slow ones scores 18 and is the
-- suspect; a job that runs in every frame scores 1 whatever the stutter is
-- doing, and ranks last.
--
-- Charged backwards, like every other reading here: the jobs credited with a
-- frame are the ones that ran in the tick BEFORE the delta that measured it.
local function RecordAttribution(delta, now)
    attribution.frames = attribution.frames + 1
    local slow = delta >= SLOW_FRAME
    if slow then
        attribution.slowFrames = attribution.slowFrames + 1
        if attribution.lastSlowAt then
            attribution.slowGapSum = attribution.slowGapSum + (now - attribution.lastSlowAt)
            attribution.slowGaps = attribution.slowGaps + 1
        end
        attribution.lastSlowAt = now
    end
    local index = 1
    while index <= ranLastTickCount do
        local job = ranLastTickJobs[index]
        if job then
            job.runs = (job.runs or 0) + 1
            if slow then
                job.slowRuns = (job.slowRuns or 0) + 1
            end
            ChargeLabel(job, slow)
        end
        index = index + 1
    end
    if attribution.writtenAt
        and now - attribution.writtenAt < ATTRIBUTION_WRITE_INTERVAL then
        return
    end
    attribution.writtenAt = now
    local config = UQ:GetModule("Config")
    if not config or attribution.slowFrames < 10 then
        return
    end
    -- Insertion sort into a short ranked list: the job table is small, this
    -- runs once every few seconds, and it allocates one table per report.
    local ranked = {}
    index = 1
    local total = table.getn(Driver.jobs)
    while index <= total do
        local job = Driver.jobs[index]
        local runs = job.runs or 0
        if runs > 0 then
            local slowShare = (job.slowRuns or 0) / attribution.slowFrames
            local runShare = runs / attribution.frames
            local entry = {
                name = job.name,
                slowRuns = job.slowRuns or 0,
                runs = runs,
                score = slowShare / runShare,
            }
            local position = table.getn(ranked) + 1
            while position > 1 and ranked[position - 1].score < entry.score do
                ranked[position] = ranked[position - 1]
                position = position - 1
            end
            ranked[position] = entry
            while table.getn(ranked) > RANKED_JOBS do
                table.remove(ranked)
            end
        end
        index = index + 1
    end
    config:SetSectionEntry("driverStalls", "slowFrames", string.format(
        "%d of %d frames over %.0fms, one every %.2fs",
        attribution.slowFrames, attribution.frames, SLOW_FRAME * 1000,
        attribution.slowGaps > 0 and attribution.slowGapSum / attribution.slowGaps or 0))
    index = 1
    total = table.getn(ranked)
    while index <= total do
        local entry = ranked[index]
        config:SetSectionEntry("driverStalls", "job" .. tostring(index), string.format(
            "%.1fx %s (%d of %d slow, ran %d of %d)",
            entry.score, entry.name, entry.slowRuns, attribution.slowFrames,
            entry.runs, attribution.frames))
        local labels = DescribeLabels(Driver.jobsByName[entry.name])
        if labels then
            config:SetSectionEntry("driverStalls",
                "job" .. tostring(index) .. "parts", labels)
        end
        index = index + 1
    end
end

local function RunJob(job, elapsed)
    job.callback(elapsed)
end

local function OnUpdate()
    if not Driver.enabled then
        return
    end

    local now = Client.Now()
    if not now then
        return
    end

    if not lastClock then
        lastClock = now
        return
    end

    local delta = now - lastClock
    lastClock = now
    -- Charged before the clamp below: the whole point of this reading is the
    -- outliers MAX_DELTA exists to hide from jobs.
    Driver.tickCount = Driver.tickCount + 1
    if not Driver.firstTickAt then
        Driver.firstTickAt = now
    elseif delta > 0 then
        RecordGap(delta, now)
        RecordFrame(delta, now)
        RecordAttribution(delta, now)
    end
    ranLastTickCount = 0
    if delta < 0 then
        delta = 0
    elseif delta > MAX_DELTA then
        delta = MAX_DELTA
    end

    local index = 1
    local total = table.getn(Driver.jobs)
    while index <= total do
        local job = Driver.jobs[index]
        if job.active then
            job.accumulated = job.accumulated + delta
            local held = job.readyTick and Driver.tickCount < job.readyTick
            if not held and job.accumulated >= job.interval then
                job.readyTick = nil
                local elapsed = job.accumulated
                job.accumulated = 0
                ranLastTickCount = ranLastTickCount + 1
                ranLastTick[ranLastTickCount] = job.name
                ranLastTickJobs[ranLastTickCount] = job
                local ok, err = pcall(RunJob, job, elapsed)
                if not ok then
                    job.failures = job.failures + 1
                    UQ:Debug("job " .. job.name .. " failed: " .. tostring(err))
                    if job.failures >= 5 then
                        job.active = false
                        UQ:Warn(UQ.L("DRIVER_JOB_DISABLED", job.name))
                    end
                end
            end
        end
        index = index + 1
    end

    -- How many jobs made their FIRST run in the driver's first tick. This is
    -- the number the startup stagger exists to hold down -- unstaggered it is
    -- every job the addon owns, in one frame -- so it is kept as the direct
    -- observable rather than inferred from the holds, which are cleared as
    -- soon as they are spent.
    if Driver.tickCount == 1 then
        Driver.firstTickJobs = ranLastTickCount
        local config = UQ:GetModule("Config")
        if config then
            config:SetSectionEntry("driverStalls", "firstTickJobs", ranLastTickCount)
        end
    end
end

function Driver:OnInit()
    -- Parented to WorldFrame, not UIParent, and that choice is load-bearing.
    --
    -- A frame receives no OnUpdate while it or any ancestor is hidden. UIParent
    -- is part of the game UI and gets hidden -- the fullscreen map presentation
    -- being the case that bit us: the whole addon's periodic work stopped for
    -- as long as the map was open, so marking a quest giver done left its "!"
    -- on screen until the map was closed (which resumed the driver) and
    -- reopened. WorldFrame is the 3D viewport and is never hidden by the UI.
    --
    -- This is exactly how the installed pfQuest drives its own map layer
    -- (pfMap = CreateFrame("Frame", "pfQuestMap", WorldFrame)), whose markers
    -- do update live on this client. That is prior art on the same client
    -- rather than a probe, so UIParent is kept as a fallback: a driver on the
    -- wrong parent still ticks whenever the UI is up, which is strictly better
    -- than no driver at all.
    local ok, frame = pcall(CreateFrame, "Frame", "UnrealQuestDriver", WorldFrame)
    if not ok or not frame then
        ok, frame = pcall(CreateFrame, "Frame", "UnrealQuestDriver", UIParent)
    end
    if not ok then
        frame = nil
    end
    if not frame then
        UQ:Warn(UQ.L("DRIVER_NO_FRAME"))
        return
    end
    frame:SetScript("OnUpdate", OnUpdate)
    self.frame = frame
    self.enabled = true
    lastClock = Client.Now()
end

-- Registers a repeating job. interval is in seconds; 0 means every tick.
function Driver:Schedule(name, interval, callback)
    if type(callback) ~= "function" then
        return false
    end
    local job = self.jobsByName[name]
    if not job then
        job = { name = name, failures = 0 }
        self.jobsByName[name] = job
        table.insert(self.jobs, job)
        -- Only a job seen for the first time is held. Re-scheduling an
        -- existing one -- a new callback, or a changed interval -- is a live
        -- module reconfiguring itself, not startup, and must not be delayed.
        -- ...and only while the driver has not ticked yet, which is exactly
        -- the load window every module registers in. A job that appears later
        -- belongs to a module coming up mid-session and is never held: without
        -- this test the counter would keep growing and a job scheduled an hour
        -- in would inherit the whole accumulated delay.
        if self.tickCount == 0 then
            self.scheduledCount = (self.scheduledCount or 0) + 1
            job.readyTick = self.scheduledCount * STARTUP_STAGGER_TICKS
        end
    end
    job.interval = interval or 0
    job.callback = callback
    job.accumulated = 0
    job.active = true
    job.failures = 0
    return true
end

function Driver:Unschedule(name)
    local job = self.jobsByName[name]
    if job then
        job.active = false
    end
end

-- Makes a scheduled job run on the next tick instead of waiting out its
-- interval. This is how event handlers accelerate polling without any module
-- having to trust that the event exists.
function Driver:Wake(name)
    local job = self.jobsByName[name]
    if job and job.active then
        job.accumulated = job.interval
    end
end

function Driver:GetJobReport()
    local report = {}
    local index = 1
    local total = table.getn(self.jobs)
    while index <= total do
        local job = self.jobs[index]
        table.insert(report, {
            name = job.name,
            interval = job.interval,
            active = job.active,
            failures = job.failures,
        })
        index = index + 1
    end
    return report
end
