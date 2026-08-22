--[[
UnrealQuest / Core/Events.lua

Defensive event layer.

The client API reference does not document event names or payloads at all, and
the runtime compatibility database has records for sixteen events, none of them
quest-related. UnrealQuest therefore treats events as unproven:

  * Registration is pcall-guarded, so an event name this client does not know
    costs nothing and is recorded as rejected rather than faulting the addon.
  * Nothing depends on an event firing. Handlers only wake a polling job, so
    correctness is identical whether an event exists, exists but never fires,
    or does not exist at all.
  * Handlers read the event name and payload through the legacy globals as well
    as the direct arguments, because OnEvent on a plain frame was measured on
    this client to deliver neither name nor payload as a direct argument.
  * A native frame's own OnEvent handler is never invoked to force a refresh;
    that is confirmed to crash this client rather than raise a Lua error.

Every event this addon registers is also counted, and the counts are persisted.
That turns normal play into the evidence the compatibility database is missing:
after a session, the observed set can be read back with /uq events and promoted
into the compact DB with proper provenance.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local Events = UQ:NewModule("Events")

Events.handlers = {}
Events.registration = {}
Events.registrationOrder = {}
-- observed is the running session total and is never cleared, so /uq events
-- keeps reporting the whole session. pending is the not-yet-written delta.
Events.observed = {}
Events.pending = {}
Events.frame = nil

local function Note(event, accepted)
    if Events.registration[event] == nil then
        table.insert(Events.registrationOrder, event)
    end
    Events.registration[event] = accepted and true or false
end

-- Captures the legacy argument globals. They are read once, immediately, since
-- the same globals are reused by every subsequent dispatch.
local function CaptureArgs()
    local ok1, a1 = pcall(getglobal, "arg1")
    local ok2, a2 = pcall(getglobal, "arg2")
    local ok3, a3 = pcall(getglobal, "arg3")
    if not ok1 then a1 = nil end
    if not ok2 then a2 = nil end
    if not ok3 then a3 = nil end
    return a1, a2, a3
end

local function Dispatch(first, second)
    local event = Client.ResolveEventName(first, second)
    if not event then
        return
    end

    local a1, a2, a3 = CaptureArgs()

    Events.observed[event] = (Events.observed[event] or 0) + 1
    Events.pending[event] = (Events.pending[event] or 0) + 1

    local list = Events.handlers[event]
    if not list then
        return
    end

    local index = 1
    local total = table.getn(list)
    while index <= total do
        local ok, err = pcall(list[index], event, a1, a2, a3)
        if not ok then
            UQ:Debug("handler for " .. event .. " failed: " .. tostring(err))
        end
        index = index + 1
    end
end

function Events:OnInit()
    local ok, frame = pcall(CreateFrame, "Frame", "UnrealQuestEvents", UIParent)
    if not ok then
        frame = nil
    end
    if not frame then
        UQ:Warn("could not create the event frame; UnrealQuest will rely on polling alone")
        return
    end
    frame:SetScript("OnEvent", Dispatch)
    self.frame = frame
end

function Events:OnEnable()
    -- There is no verified logout hook on this client, so observations are
    -- flushed into saved settings periodically rather than at shutdown.
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Schedule("events.persist", 30.0, function() Events:PersistObservations() end)
    end
end

-- Subscribes callback to event. Returns true when the client accepted the
-- registration. A false return is informational only: callers must stay correct
-- without the event.
function Events:Register(event, callback)
    if type(event) ~= "string" or type(callback) ~= "function" then
        return false
    end
    if not self.frame then
        return false
    end

    local accepted = self.registration[event]
    if accepted == nil then
        accepted = Client.RegisterEvent(self.frame, event)
        Note(event, accepted)
        if not accepted then
            UQ:Debug("client rejected event registration: " .. event)
        end
    end

    if not self.handlers[event] then
        self.handlers[event] = {}
    end
    table.insert(self.handlers[event], callback)
    return accepted
end

function Events:WasAccepted(event)
    return self.registration[event] == true
end

function Events:GetObservedCount(event)
    return self.observed[event] or 0
end

function Events:GetRegistrationReport()
    local report = {}
    local index = 1
    local total = table.getn(self.registrationOrder)
    while index <= total do
        local event = self.registrationOrder[index]
        table.insert(report, {
            event = event,
            accepted = self.registration[event],
            observed = self.observed[event] or 0,
        })
        index = index + 1
    end
    return report
end

-- Persists the observed counts so a play session becomes reportable evidence
-- about which quest events this client actually fires.
function Events:PersistObservations()
    local config = UQ:GetModule("Config")
    if not config or not config.store then
        return
    end
    local section = config:GetSection("observedEvents")
    if not section then
        return
    end
    local index = 1
    local total = table.getn(self.registrationOrder)
    while index <= total do
        local event = self.registrationOrder[index]
        local count = self.pending[event]
        if count and count > 0 then
            if config:SetSectionEntry("observedEvents", event, (section[event] or 0) + count) then
                self.pending[event] = 0
            end
        end
        index = index + 1
    end
end
