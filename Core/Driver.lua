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

local lastClock = nil

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
            if job.accumulated >= job.interval then
                local elapsed = job.accumulated
                job.accumulated = 0
                local ok, err = pcall(RunJob, job, elapsed)
                if not ok then
                    job.failures = job.failures + 1
                    UQ:Debug("job " .. job.name .. " failed: " .. tostring(err))
                    if job.failures >= 5 then
                        job.active = false
                        UQ:Warn("job " .. job.name .. " disabled after repeated failures")
                    end
                end
            end
        end
        index = index + 1
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
        UQ:Warn("could not create the shared driver frame; periodic work is disabled")
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
