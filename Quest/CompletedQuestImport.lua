--[[
UnrealQuest / Quest/CompletedQuestImport.lua

Seeds Quest/QuestHistory.lua from the server's own list of quests this
character has turned in (QueryQuestsCompleted / GetQuestsCompleted, wrapped in
Compatibility/ClientAPI.lua). Behind the Import page's single button.

Format and timing verified in game (probe questquery.v1; compat record
quest.completed_quest_list_questquery_v1): t[questId] = 1, event ~0.3 s after
the query, a throttled re-query is silent and keeps the previous answer.

A round trip, not a read: the button sends the query, then a driver job polls
the answer for a bounded window. QUEST_QUERY_COMPLETE only wakes the job early.
An empty list is "no answer yet" until either the event fired or the window
closed -- the two lead to different player-facing text.

The getter keeps the previous answer, so a list that was already there before
the press is held for FRESH_WAIT (longer than the two-second server throttle)
unless the event announces the new answer first; only then is the old list
taken as the answer.

With the `completedQuestAutoImport` option (on by default) the same import
runs once, quietly, LOGIN_DELAY seconds after the addon is enabled: it prints
only when it brought new quests in. With the option off the login query still
runs, silently and without touching QuestHistory: Data/QuestMatch.lua uses the
answer to rule out same-title candidates already turned in.

Every answer is also kept for the session as a set (IsServerCompleted). It is
the server's own word, unlike QuestHistory, which also holds pfQuest imports
and the addon's own turn-in guesses -- so it is the only history the matcher
reads.

Imported quests go into QuestHistory's IMPORTED provenance section, so the
whole import stays reversible as one act (`/uq pfquest undo` clears every
imported completion, whichever source brought it in). IDs the bundled Vanilla
data does not know are counted and skipped.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local CompletedQuestImport = UQ:NewModule("CompletedQuestImport")

local CAPABILITY = "completedQuestHistory"
local EVENT = "QUEST_QUERY_COMPLETE"
local POLL_JOB = "completedquests.import"
-- The answer measured at ~0.3 s; a fast poll keeps the wait short and drives
-- the button's dot animation.
local POLL_INTERVAL = 0.25
-- Covers the server's two-second answer throttle several times over.
local POLL_SECONDS = 10
-- How long a list cached from an earlier answer waits for a fresh one.
local FRESH_WAIT = 3
local DOT_PERIOD = 0.4
-- After enable, so the login burst of events and pins is out of the way.
local LOGIN_DELAY = 5
local LOGIN_JOB = "completedquests.login"

local function Now()
    return Client.Now() or 0
end

local function Database()
    return UQ:GetModule("Database")
end

local function History()
    return UQ:GetModule("QuestHistory")
end

-- Both map layers cache the "done" set in their view signature.
local function MarkMapDirty()
    local pins = UQ:GetModule("WorldMapPins")
    if pins then
        pins.dirty = true
    end
    local minimap = UQ:GetModule("MinimapPins")
    if minimap then
        minimap.dirty = true
    end
end

-- Server answer kept for the matcher ----------------------------------------

function CompletedQuestImport:HasServerAnswer()
    return self.serverDone ~= nil
end

function CompletedQuestImport:IsServerCompleted(questId)
    local done = self.serverDone
    return done ~= nil and done[questId] == true
end

-- Replaces the session set and asks QuestState to re-match its ambiguous rows.
function CompletedQuestImport:StoreServerAnswer(ids)
    local done = {}
    local count = 0
    local index = 1
    local total = table.getn(ids)
    while index <= total do
        if not done[ids[index]] then
            done[ids[index]] = true
            count = count + 1
        end
        index = index + 1
    end
    self.serverDone = done
    self.serverDoneCount = count
    local matcher = UQ:GetModule("QuestMatch")
    if matcher then
        matcher:ClearCache()
    end
    local state = UQ:GetModule("QuestState")
    if state and state.RecheckAmbiguous then
        state:RecheckAmbiguous()
    end
end

-- "unsupported" | "waiting" | "idle"
function CompletedQuestImport:GetState()
    if not Client.HasCompletedQuestQuery() then
        return "unsupported"
    end
    if self.waiting then
        return "waiting"
    end
    return "idle"
end

-- Marks every known, not-yet-done ID as imported. Returns the report.
function CompletedQuestImport:Import(ids)
    local report = { received = 0, imported = 0, alreadyDone = 0, unknown = 0 }
    local database = Database()
    local history = History()
    if not history or type(ids) ~= "table" then
        return report
    end

    local index = 1
    local total = table.getn(ids)
    report.received = total
    while index <= total do
        local questId = ids[index]
        if not database or not database:GetQuest(questId) then
            report.unknown = report.unknown + 1
        elseif history:IsDone(questId) then
            report.alreadyDone = report.alreadyDone + 1
        elseif history:MarkDoneImported(questId) then
            report.imported = report.imported + 1
        end
        index = index + 1
    end

    if report.imported > 0 then
        MarkMapDirty()
    end
    return report
end

-- Ends a request: unschedules the poll, stores the outcome, tells the player
-- and the options page.
function CompletedQuestImport:Finish(outcome, report)
    self.waiting = nil
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Unschedule(POLL_JOB)
    end
    -- The login import speaks only when it changed something.
    local quiet = self.quiet
    self.quiet = nil
    local lookupOnly = self.lookupOnly
    self.lookupOnly = nil
    -- A lookup imported nothing, so the options page keeps the last import.
    if not lookupOnly then
        self.lastOutcome = outcome
        self.lastReport = report
    end
    if outcome == "imported" then
        UQ:DeclareCapability(CAPABILITY, "verified",
            "probe questquery.v1; this session the server answered with "
            .. tostring(report.received) .. " quest ID(s), " .. tostring(report.unknown)
            .. " unknown to the bundled data")
    end
    if lookupOnly then
        UQ:Debug("login completed-quest lookup ended: " .. tostring(outcome))
    elseif outcome == "imported" then
        if report.imported > 0 then
            UQ:Print(UQ.LN("COMPLETED_IMPORTED", report.imported))
        elseif not quiet then
            UQ:Print(UQ.L("COMPLETED_NOTHING_NEW"))
        end
    elseif quiet then
        UQ:Debug("login completed-quest import ended: " .. tostring(outcome))
    elseif outcome == "empty" then
        UQ:Print(UQ.L("COMPLETED_SERVER_EMPTY"))
    else
        UQ:Print(UQ.L("COMPLETED_NO_ANSWER"))
    end

    self:Notify()
end

function CompletedQuestImport:Notify()
    if type(self.onChanged) == "function" then
        pcall(self.onChanged)
    end
end

function CompletedQuestImport:Poll()
    if not self.waiting then
        return
    end
    self.waited = Now() - (self.startedAt or Now())
    local ids = Client.GetCompletedQuestIds()
    if ids and table.getn(ids) > 0 then
        if not self.cachedBefore or self.answered or self.waited >= FRESH_WAIT then
            self:StoreServerAnswer(ids)
            local report
            if self.lookupOnly then
                report = { received = table.getn(ids), imported = 0, alreadyDone = 0, unknown = 0 }
            else
                report = self:Import(ids)
            end
            self:Finish("imported", report)
            return
        end
    elseif self.answered then
        self:Finish("empty")
        return
    end
    if self.waited >= POLL_SECONDS then
        self:Finish("timeout")
        return
    end
    self:Notify()
end

-- The options-page button, and the login import with `quiet` set: a quiet
-- run prints nothing unless it imports something. `lookupOnly` (login with
-- auto-import off) only refreshes the matcher's set: no import, no output.
-- Returns the state it acted on.
function CompletedQuestImport:Press(quiet, lookupOnly)
    local state = self:GetState()
    if state == "unsupported" then
        if not quiet then
            UQ:Print(UQ.L("COMPLETED_UNSUPPORTED"))
        end
        return state
    end
    if state == "waiting" then
        if not quiet then
            UQ:Print(UQ.L("COMPLETED_STILL_WAITING"))
        end
        return state
    end

    if not Client.RequestCompletedQuests() then
        if not quiet then
            UQ:Print(UQ.L("COMPLETED_REQUEST_FAILED"))
        end
        return state
    end

    local before = Client.GetCompletedQuestIds()
    self.cachedBefore = before and table.getn(before) > 0 or nil
    self.waiting = true
    self.answered = nil
    self.waited = 0
    self.startedAt = Now()
    self.quiet = quiet and true or nil
    self.lookupOnly = lookupOnly and true or nil
    if not quiet then
        UQ:Print(UQ.L("COMPLETED_ASKING"))
    end
    self:Notify()

    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Schedule(POLL_JOB, POLL_INTERVAL, function()
            CompletedQuestImport:Poll()
        end)
    else
        self:Poll()
    end
    return state
end

-- ONE line for the options page (it reserves a single body line).
function CompletedQuestImport:DescribeShort()
    local state = self:GetState()
    if state == "unsupported" then
        return UQ.L("COMPLETED_SHORT_UNSUPPORTED")
    end
    if state == "waiting" then
        return UQ.L("COMPLETED_SHORT_WAITING")
    end
    local report = self.lastReport
    if self.lastOutcome == "imported" and report then
        return UQ.L("COMPLETED_SHORT_RESULT", tostring(report.imported),
            tostring(report.alreadyDone))
    end
    if self.lastOutcome == "empty" then
        return UQ.L("COMPLETED_SERVER_EMPTY")
    end
    if self.lastOutcome == "timeout" then
        return UQ.L("COMPLETED_NO_ANSWER")
    end
    return UQ.L("COMPLETED_SHORT_IDLE")
end

-- While waiting the label animates "." / ".." / "..." from the clock, so any
-- refresh (the poll calls one every tick) shows the current frame.
function CompletedQuestImport:GetButtonLabel()
    if self:GetState() == "waiting" then
        local elapsed = Now() - (self.startedAt or 0)
        local step = math.floor(elapsed / DOT_PERIOD)
        local dots = step - math.floor(step / 3) * 3 + 1
        return UQ.L("COMPLETED_BUTTON_WAITING") .. string.rep(".", dots)
    end
    return UQ.L("COMPLETED_BUTTON_IMPORT")
end

function CompletedQuestImport:IsButtonEnabled()
    return self:GetState() == "idle"
end

-- One quiet query per load, LOGIN_DELAY after enable: an import when the
-- option is on, a silent lookup for the matcher when it is off.
function CompletedQuestImport:RunLoginImport()
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Unschedule(LOGIN_JOB)
    end
    local config = UQ:GetModule("Config")
    local import = config and config:Get("completedQuestAutoImport") and true or false
    self:Press(true, not import)
end

-- The event only accelerates the poll; the poll alone still finishes.
function CompletedQuestImport:OnEnable()
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Schedule(LOGIN_JOB, LOGIN_DELAY, function()
            CompletedQuestImport:RunLoginImport()
        end)
    end

    local events = UQ:GetModule("Events")
    if events then
        events:Register(EVENT, function()
            if not CompletedQuestImport.waiting then
                return
            end
            CompletedQuestImport.answered = true
            local driver = UQ:GetModule("Driver")
            if driver then
                driver:Wake(POLL_JOB)
            end
        end)
    end
end
