--[[
UnrealQuest / Quest/QuestState.lua

The addon's model of the player's quest log, and the only place quest change
detection happens.

Why this polls instead of reacting to events: no quest event has any record in
the runtime compatibility database, and the client's API reference does not
document event names at all. A quest addon built on QUEST_LOG_UPDATE here would
be building on an assumption. So the model is rebuilt from the quest log on a
driver job, diffed against the previous snapshot, and change notifications are
derived from that diff. Events are still registered, and when one arrives it
simply wakes the scan job early. If every candidate event turns out not to
exist, the addon behaves identically, only with poll-interval latency.

Two client details shape the scan:

  * Quest log rows are identified by index, and indices shift whenever a quest
    is accepted or turned in, so the model keys quests by normalized title.
    Same-title rows share one entry. A scan collects them before diffing, using
    the last visible row consistently for both identity and objectives.
  * A collapsed header hides its quests from GetNumQuestLogEntries entirely.
    A snapshot taken while any header is collapsed is incomplete, and emitting
    "removed" from an incomplete snapshot would invent quest removals that
    never happened. Incomplete snapshots update state but never emit removals.
    The addon does not expand headers itself: that mutates a native UI the
    player is looking at, and header collapse handling on this client is
    already known to be partly broken.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local QuestState = UQ:NewModule("QuestState")

-- Objective refresh is round-robined across ticks so a large quest log never
-- turns one tick into a burst of guarded calls.
local OBJECTIVE_BUDGET = 6

-- Candidate quest-related events. None of these is verified on this client;
-- registration failures are expected and harmless.
local CANDIDATE_EVENTS = {
    "QUEST_LOG_UPDATE",
    "QUEST_WATCH_UPDATE",
    "UNIT_QUEST_LOG_CHANGED",
    "QUEST_ACCEPTED",
    "QUEST_FINISHED",
    "QUEST_COMPLETE",
    "QUEST_ITEM_UPDATE",
    "BAG_UPDATE",
    "PLAYER_LEVEL_UP",
}

QuestState.quests = {}
QuestState.order = {}
QuestState.listeners = {}
QuestState.complete = false
QuestState.collapsedHeaders = 0
QuestState.lastScan = nil
QuestState.scanCount = 0

local objectiveCursor = 1

local function Notify(event, quest, targetsChanged)
    local index = 1
    local total = table.getn(QuestState.listeners)
    while index <= total do
        local ok, err = pcall(
            QuestState.listeners[index], event, quest, targetsChanged)
        if not ok then
            UQ:Debug("quest listener failed on " .. event .. ": " .. tostring(err))
        end
        index = index + 1
    end
end

-- Objective counters are presentation state, not map topology. Turning
-- "Kobolds slain: 3/10" into "Kobolds slain: 4/10" must refresh the tracker
-- and tooltip, but it must not make every map consumer rebuild the same static
-- spawn set. The counter is removed before comparing objective identity; the
-- finished state and the have>=need transition are compared separately below.
local function ObjectiveTargetKey(text)
    if type(text) ~= "string" then
        return nil
    end
    local withoutProgress = string.gsub(text, "%d+%s*/%s*%d+", "")
    return UQ.NameKey(withoutProgress)
end

local function ObjectiveSatisfied(objective)
    if not objective then
        return false
    end
    if objective.finished then
        return true
    end
    return type(objective.have) == "number" and type(objective.need) == "number"
        and objective.have >= objective.need
end

-- Objective progress counters are embedded in the formatted objective line
-- (for example "Kobold Vermin slain: 2/5"). Extracting them is best effort:
-- an objective whose text carries no counter simply reports nil, nil.
local function ParseProgress(text)
    if type(text) ~= "string" then
        return nil, nil
    end
    local _, _, have, need = string.find(text, "(%d+)%s*/%s*(%d+)")
    if have and need then
        return tonumber(have), tonumber(need)
    end
    return nil, nil
end

local function ReadObjectives(quest)
    local count = Client.GetObjectiveCount(quest.index)
    local objectives = {}
    local changed = false
    local targetsChanged = false

    local index = 1
    while index <= count do
        local text, objectiveType, isFinished = Client.GetObjective(quest.index, index)
        local have, need = ParseProgress(text)
        -- Ordinary collected items can exceed the requirement (4/3). Cap the
        -- shared progress model and its text before diffing so every display
        -- and party report stops at 3/3, and surplus loot is not another step.
        if have and need and have > need then
            have = need
            text = string.gsub(text, "%d+(%s*/%s*%d+)", tostring(need) .. "%1", 1)
        end
        local objective = {
            text = text,
            objectiveType = objectiveType,
            finished = isFinished and true or false,
            have = have,
            need = need,
        }

        local previous = quest.objectives and quest.objectives[index]
        if not previous or previous.text ~= objective.text or previous.finished ~= objective.finished then
            changed = true
        end
        if not previous or previous.objectiveType ~= objective.objectiveType
            or ObjectiveTargetKey(previous.text) ~= ObjectiveTargetKey(objective.text)
            or ObjectiveSatisfied(previous) ~= ObjectiveSatisfied(objective) then
            targetsChanged = true
        end

        objectives[index] = objective
        index = index + 1
    end

    if quest.objectives and table.getn(quest.objectives) ~= count then
        changed = true
        targetsChanged = true
    end

    quest.objectives = objectives
    quest.objectiveCount = count
    return changed, targetsChanged
end

-- The completion flag the rest of the addon reads. The client's own flag is
-- kept as quest.clientComplete, but it is not trusted on its own: the user
-- reported a quest ("The Dead Fields") whose log line read "Essence of
-- Nightlash: 0/1" while the row still came back complete -- most likely the
-- item was destroyed or sold after it had been looted. Believing the flag
-- turned the map, tracker and navigator over to the turn-in NPC and left no
-- way back to the objective. So a counter the log itself shows as short
-- demotes the quest. Only a parsed shortfall does: an objective without a
-- counter, or a finished flag the client left unset, is not evidence against
-- the client, and demoting on it could strand a scripted quest the other way.
-- The reverse is never inferred either -- all counters full with the client
-- saying not complete stays not complete.
local function EffectiveComplete(clientComplete, quest)
    if clientComplete ~= 1 then
        return clientComplete
    end
    local objectives = quest.objectives or {}
    local index = 1
    local total = table.getn(objectives)
    while index <= total do
        local objective = objectives[index]
        if objective and type(objective.have) == "number"
            and type(objective.need) == "number"
            and objective.have < objective.need then
            return nil
        end
        index = index + 1
    end
    return clientComplete
end

local function ResolveIdentity(quest)
    local matcher = UQ:GetModule("QuestMatch")
    if not matcher then
        return
    end
    local questId, confidence, candidates, mapCandidates = matcher:Resolve(
        quest.title, quest.level, quest.index, quest.rawTitle)
    quest.questId = questId
    quest.matchConfidence = confidence
    quest.matchCandidates = candidates
    quest.matchMapCandidates = mapCandidates
end

function QuestState:Scan()
    local total = Client.GetQuestLogCount()
    local seen = {}
    local order = {}
    local collapsed = 0
    local added = {}
    local completed = {}
    -- Objective re-reads done by the scan itself, notified after the diff.
    local objectiveChanges = {}
    -- Quests whose identity was still "indexing" on a previous scan and has
    -- now resolved. The database title index builds across driver ticks, so on
    -- a login with a full quest log every quest is first modelled without a
    -- quest ID; anything keyed on quest IDs has to be told when that changes.
    local resolvedIdentities = 0

    -- The zone a quest belongs to is not a property of the quest row: it is
    -- whichever header row was passed last on the way down the log. Captured
    -- here because it is free at this point and impossible to recover later --
    -- the model keys quests by title and never revisits the raw index order.
    local currentZone = nil

    local index = 1
    while index <= total do
        -- rawTitle is non-nil only when the client (or an addon hooking it)
        -- decorated the title and Client.CleanQuestTitle took the decoration
        -- back off. It is carried on the quest so the matcher can try the
        -- client's own spelling against the database before the cleaned one.
        local title, level, questTag, isHeader, isCollapsed, isComplete, rawTitle =
            Client.GetQuestLogEntry(index)
        if title then
            if isHeader then
                currentZone = title
                if isCollapsed then
                    collapsed = collapsed + 1
                end
            else
                local titleKey = UQ.NameKey(title)
                if titleKey then
                    -- Preserve the existing last-row representative, but do
                    -- not mutate the live quest while collecting duplicates.
                    -- Otherwise a completed and an unfinished copy toggle the
                    -- same table twice every poll, inventing accept/complete
                    -- transitions and rebuilding every target scene forever.
                    local row = seen[titleKey]
                    if not row then
                        row = { count = 0 }
                        seen[titleKey] = row
                        table.insert(order, titleKey)
                    end
                    row.count = row.count + 1
                    row.index = index
                    row.title = title
                    row.rawTitle = rawTitle
                    row.level = level
                    row.questTag = questTag
                    row.zone = currentZone
                    row.isComplete = isComplete
                end
            end
        end
        index = index + 1
    end

    -- Diff once per title against the previous completed snapshot, never
    -- against another row from this same scan. Order also contains each title
    -- only once so every map, tracker and objective slice visits it once.
    local orderIndex = 1
    while orderIndex <= table.getn(order) do
        local titleKey = order[orderIndex]
        local row = seen[titleKey]
        local level = row.level
        local isComplete = row.isComplete
        local quest = self.quests[titleKey]
        local isNew = false
        if not quest then
            quest = { titleKey = titleKey, objectives = nil }
            self.quests[titleKey] = quest
            isNew = true
        end

        -- Identity and acceptance logic below compares the CLIENT's flag
        -- between scans, exactly as before EffectiveComplete existed: a
        -- demotion for a short counter is not a same-title follow-up being
        -- accepted, and must not be announced or re-matched as one.
        local previousComplete = quest.isComplete
        local previousClientComplete = quest.clientComplete
        local previousLevel = quest.level
        local previousSeenAt = quest.seenAt
        local previousRowCount = quest.rowCount or 1
        quest.index = row.index
        quest.title = row.title
        quest.rawTitle = row.rawTitle
        quest.level = level
        quest.questTag = row.questTag
        quest.zone = row.zone
        quest.clientComplete = isComplete
        quest.isComplete = isComplete
        quest.seenAt = self.scanCount
        quest.rowCount = row.count

        local identityMayHaveChanged = not isNew and (
            previousLevel ~= level
            or previousRowCount ~= row.count
            or (previousClientComplete == 1 and isComplete ~= 1)
            or (type(previousSeenAt) == "number"
                and previousSeenAt < self.scanCount - 1)
        )

        if isNew then
            ResolveIdentity(quest)
            ReadObjectives(quest)
            table.insert(added, quest)
        elseif quest.matchConfidence == "indexing" then
            -- The title index was not ready when this quest first
            -- appeared; retry now that it may be.
            ResolveIdentity(quest)
            if quest.matchConfidence ~= "indexing" then
                resolvedIdentities = resolvedIdentities + 1
            end
        elseif identityMayHaveChanged then
            -- A completed same-title chain step can be replaced by its
            -- follow-up between polls. A duplicate count change can also
            -- replace the representative with a different same-level step.
            -- Level changes and collapsed-header gaps carry the same risk.
            local previousQuestId = quest.questId
            local previousConfidence = quest.matchConfidence
            ResolveIdentity(quest)
            if quest.questId ~= previousQuestId
                or quest.matchConfidence ~= previousConfidence then
                resolvedIdentities = resolvedIdentities + 1
            end
        end

        -- A same-title follow-up is still a new acceptance, but losing a
        -- duplicate representative is not. Do not auto-track or announce
        -- acceptance merely because another copy remains unfinished.
        if not isNew and previousClientComplete == 1 and isComplete ~= 1
            and previousRowCount == 1 and row.count == 1 then
            table.insert(added, quest)
        end

        -- A quest the client calls complete has its counters re-read on
        -- every scan instead of waiting for the round-robin slice, so a quest
        -- item destroyed or sold is noticed within one poll -- and on the
        -- very first scan after login or a reload, where every quest is new
        -- and was just read above. BAG_UPDATE wakes this scan early.
        if not isNew and isComplete == 1 then
            local changed, targetsChanged = ReadObjectives(quest)
            if changed then
                table.insert(objectiveChanges, { quest = quest, targetsChanged = targetsChanged })
            end
        end
        quest.isComplete = EffectiveComplete(isComplete, quest)

        if quest.isComplete == 1 and previousComplete ~= 1 then
            table.insert(completed, quest)
        end

        -- A changed copy count or completion reset can alter map state even
        -- if the ID stays the same and no acceptance was announced above.
        if not isNew and (previousRowCount ~= row.count
            or (previousComplete == 1 and quest.isComplete ~= 1)) then
            resolvedIdentities = resolvedIdentities + 1
        end

        orderIndex = orderIndex + 1
    end

    self.scanCount = self.scanCount + 1
    self.collapsedHeaders = collapsed
    self.complete = (collapsed == 0)
    self.order = order
    self.lastScan = Client.Now()

    -- Removals are only trustworthy when the whole log was visible.
    local removed = {}
    if self.complete then
        for titleKey, quest in pairs(self.quests) do
            if not seen[titleKey] then
                table.insert(removed, quest)
            end
        end
        local removedIndex = 1
        local removedTotal = table.getn(removed)
        while removedIndex <= removedTotal do
            local removedKey = removed[removedIndex].titleKey
            self.quests[removedKey] = nil
            -- Hands the quest's colour back to the palette so the colours
            -- still on screen stay as far apart as the palette allows.
            UQ.ReleaseQuestColor(removedKey)
            removedIndex = removedIndex + 1
        end

        -- Colours are remembered across sessions, so the saved map can name
        -- quests this character finished under a previous login and that the
        -- loop above never saw leave. A complete scan is the only moment the
        -- live set is authoritative enough to drop them.
        UQ.PruneQuestColors(seen)
    end

    local notifyIndex = 1
    local notifyTotal = table.getn(added)
    while notifyIndex <= notifyTotal do
        Notify("QUEST_ADDED", added[notifyIndex])
        notifyIndex = notifyIndex + 1
    end

    notifyIndex = 1
    notifyTotal = table.getn(removed)
    while notifyIndex <= notifyTotal do
        Notify("QUEST_REMOVED", removed[notifyIndex])
        notifyIndex = notifyIndex + 1
    end

    notifyIndex = 1
    notifyTotal = table.getn(objectiveChanges)
    while notifyIndex <= notifyTotal do
        local entry = objectiveChanges[notifyIndex]
        Notify("QUEST_OBJECTIVES_CHANGED", entry.quest, entry.targetsChanged)
        notifyIndex = notifyIndex + 1
    end

    notifyIndex = 1
    notifyTotal = table.getn(completed)
    while notifyIndex <= notifyTotal do
        Notify("QUEST_COMPLETED", completed[notifyIndex])
        notifyIndex = notifyIndex + 1
    end

    -- A late identity resolution changes no row and no objective, so it would
    -- otherwise be invisible to listeners -- and anything that keys off quest
    -- IDs (map pins, entity tooltips) would keep whatever it derived while
    -- every quest was still unidentified.
    if table.getn(added) > 0 or table.getn(removed) > 0 or resolvedIdentities > 0 then
        Notify("QUEST_LOG_CHANGED", nil)
    end
end

-- Refreshes objective text for a bounded slice of the quest log each tick.
-- Counters move without anything changing at row level, so this has to run on
-- its own cadence rather than only when the quest set changes.
function QuestState:RefreshObjectiveSlice()
    local total = table.getn(self.order)
    if total == 0 then
        return
    end
    if objectiveCursor > total then
        objectiveCursor = 1
    end

    local processed = 0
    while processed < OBJECTIVE_BUDGET and processed < total do
        local titleKey = self.order[objectiveCursor]
        local quest = titleKey and self.quests[titleKey]
        if quest then
            local changed, targetsChanged = ReadObjectives(quest)
            if changed then
                -- The third argument lets geometry consumers ignore a pure
                -- counter movement. Existing listeners that only need to know
                -- that displayed progress changed continue to ignore it.
                Notify("QUEST_OBJECTIVES_CHANGED", quest, targetsChanged)
            end
        end
        objectiveCursor = objectiveCursor + 1
        if objectiveCursor > total then
            objectiveCursor = 1
        end
        processed = processed + 1
    end
end

-- Public read access --------------------------------------------------------

function QuestState:GetQuest(titleKey)
    return self.quests[titleKey]
end

function QuestState:GetQuestByTitle(title)
    return self.quests[UQ.NameKey(title)]
end

function QuestState:GetOrderedQuests()
    local list = {}
    local index = 1
    local total = table.getn(self.order)
    while index <= total do
        local quest = self.quests[self.order[index]]
        if quest then
            table.insert(list, quest)
        end
        index = index + 1
    end
    return list
end

function QuestState:GetQuestCount()
    return table.getn(self.order)
end

function QuestState:IsComplete()
    return self.complete
end

function QuestState:AddListener(callback)
    if type(callback) == "function" then
        table.insert(self.listeners, callback)
    end
end

-- Lifecycle -----------------------------------------------------------------

function QuestState:OnEnable()
    local driver = UQ:GetModule("Driver")
    local config = UQ:GetModule("Config")
    local events = UQ:GetModule("Events")

    local interval = 0.5
    if config then
        local configured = config:Get("pollInterval")
        if type(configured) == "number" and configured > 0 then
            interval = configured
        end
    end

    if driver then
        driver:Schedule("quest.scan", interval, function() QuestState:Scan() end)
        driver:Schedule("quest.objectives", interval, function() QuestState:RefreshObjectiveSlice() end)
    end

    if events then
        local wake = function()
            local d = UQ:GetModule("Driver")
            if d then
                d:Wake("quest.scan")
                d:Wake("quest.objectives")
            end
        end
        local index = 1
        local total = table.getn(CANDIDATE_EVENTS)
        while index <= total do
            events:Register(CANDIDATE_EVENTS[index], wake)
            index = index + 1
        end
    end

    self:Scan()
end

QuestState.CANDIDATE_EVENTS = CANDIDATE_EVENTS
