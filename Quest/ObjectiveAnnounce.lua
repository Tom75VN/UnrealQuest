--[[
UnrealQuest / Quest/ObjectiveAnnounce.lua

Repeats the player's own objective progress to their group: one line per step,
"[UQ] Kobold Vermin: 4/8", so a party farming the same quest can watch each
other's counters move instead of asking.

The line carries the objective's own name and its counter. The "[UQ]" tag in
front marks the line as this addon's rather than something the player typed.

On by default (`announceObjectivesParty`), because a group questing together
is the case this exists for. It speaks under the player's own name, so the
setting stays the first thing they can turn off, and it is silent while solo.

`announceCompletedQuestsOnly` filters that report to each objective reaching
its target count, or finishing when it has no counter. Partial progress stays
silent in that mode, including progress already queued when the filter changes.
The stored key is retained so existing selections survive the corrected label.
This mode reports completions to the current group without requiring another
member's quest log to be known. In the Westfall Stew capture, Okra reached 3/3
but the shared-quest gate discarded it before any chat send was attempted.

SHARING CHECK FOR EVERY-STEP REPORTS
-----------------------------------
The every-step mode reports only when another member has the same quest.
This client can answer that itself: `IsUnitOnQuest(index, unit)` is documented
here as "whether a party member has the same quest as that quest log row", so
every party member counts, addon or not. `CountSharingPeers` below asks that
first.

It cannot answer everything, and the gap is covered rather than papered over:
the call is party-only (a raid outside the player's own sub-group is beyond
it), and it is `documented`, not probed. Where it says nothing, the fallback is
what other UnrealQuest clients have said about themselves over the hidden addon
channel -- see `Quest/QuestSync.lua`. A member who is neither answered for by
the client nor running the addon is not knowable, and an unknown member is
never counted: the report stays silent rather than guessing.

WHAT IT IS BUILT ON, AND THE ONE RISK IN IT
-------------------------------------------
`SendChatMessage` is in this client's API reference with the full
(msg, chatType, language, channel) signature -- and is marked PROTECTED there:
"addons cannot call this; only the default FrameXML UI can". No probe has ever
exercised it. So the honest position is that this module may be refused at
runtime on a client where the symbol resolves perfectly well, and there is no
way to find out except to try.

In fact the reference goes further on its Communication page: "SendChatMessage
is protected: it errors unless called from a secure (Blizzard UI) context.
DoEmote and SendAddonMessage are not." Documentation is not measurement, so the
visible line is still attempted -- if this client allows it, it is exactly what
was asked for, and one guarded call settles a question no probe has answered.

But nothing is staked on it. The call is pcall-guarded in
`Compatibility/ClientAPI.lua` and answers false rather than faulting; refusals
are counted; and after REFUSAL_LIMIT consecutive ones this stops attempting the
visible line for the session and DELIVERS OVER THE ADDON CHANNEL INSTEAD, which
the same sentence says is not protected. That fallback only reaches other
UnrealQuest users holding the quest. It cannot
replace visible party chat for members without the addon or the quest. The
capability stays `unverified` either way; see the `chatSend` note there.

WHAT COUNTS AS A STEP
---------------------
The model in `Quest/QuestState.lua` already re-reads objective text on its own
cadence and notifies on change; this module keeps the previous counters per
objective and announces only:

  * a counter that went UP (4/8 -> 5/8). A counter going down is an item
    handed in or destroyed, and is nobody's progress;
  * an objective with no counter at all that flipped to finished.

The previous values are kept whether or not the option is on, so switching it
on mid-session reports the next step correctly instead of announcing a jump
from nothing. An objective whose name changed under the same index -- the quest
log reshuffled beneath us -- is re-seeded silently rather than announced, and
so is a quest seen for the first time, which is what keeps a login with a
half-finished log quiet.

WHAT ARRIVES FROM A PEER
------------------------
The same module prints the lines other players' clients send, under their name,
and only for a quest this player also holds -- the sender's rule checked a
second time against a set that cannot be stale. Peer text is another player's
words: `Quest/QuestSync.lua` strips the client's markup escape from it and cuts
it to length before it reaches this module, so a peer can put a line in the
chat frame and nothing else.

WHY IT IS QUEUED
----------------
Several objectives can move in one tick (a kill that counts for two quests, a
loot that fills two lines). Chat is rate-limited server-side and a burst is
what gets a player muted, so lines leave one per SEND_INTERVAL from a short
queue, and a queue that overflows drops the oldest and counts it.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local ObjectiveAnnounce = UQ:NewModule("ObjectiveAnnounce")

-- Seconds between two lines leaving the queue. Slow enough that a multi-quest
-- loot does not arrive as a burst, fast enough that the report still reads as
-- a reaction to what just happened.
local SEND_INTERVAL = 0.4

-- Lines waiting to go out. Small on purpose: if more than this is pending, the
-- oldest of them are already stale progress the player has moved past.
local QUEUE_LIMIT = 8

-- Consecutive refusals after which the visible chat line is abandoned for the
-- session and delivery moves to the addon channel. The protected marking on
-- SendChatMessage means "refused" is a real possible steady state here, not a
-- transient, and retrying forever would be a blocked call every few seconds
-- for the rest of the session.
local REFUSAL_LIMIT = 3

ObjectiveAnnounce.baseline = {}
ObjectiveAnnounce.queue = {}
ObjectiveAnnounce.announced = 0
ObjectiveAnnounce.sent = 0
ObjectiveAnnounce.relayed = 0
ObjectiveAnnounce.refused = 0
ObjectiveAnnounce.dropped = 0
-- Steps that WERE progress but that nobody in the group is doing the quest
-- for. Counted rather than discarded silently: "the option is on and my party
-- sees nothing" has this as its most likely answer, and only a number can say
-- so. See "/uq announce".
ObjectiveAnnounce.unshared = 0
ObjectiveAnnounce.received = 0
ObjectiveAnnounce.consecutiveRefusals = 0
ObjectiveAnnounce.blocked = false
ObjectiveAnnounce.lastLine = nil
ObjectiveAnnounce.lastPeerLine = nil
ObjectiveAnnounce.nextSend = 0

-- Identity of an objective, independent of the counter riding in its text.
-- "Kobold Vermin: 4/8" and "Kobold Vermin: 5/8" are the same objective; a
-- different name under the same index is a different one and must not be
-- compared against it. Same reduction QuestState uses for its target keys.
local function ObjectiveKey(text)
    if type(text) ~= "string" then
        return nil
    end
    return UQ.NameKey(string.gsub(text, "%d+%s*/%s*%d+", ""))
end

-- The objective's own name, without the counter. ObjectiveMatch reads it out
-- of the client's own QUEST_MONSTERS_KILLED / QUEST_OBJECTS_FOUND /
-- QUEST_ITEMS_NEEDED format strings, which is the only way to split the line
-- correctly in every language. When the client defines none of them the
-- counter is stripped by hand instead, so the line still names something.
local function ObjectiveName(objective)
    local matcher = UQ:GetModule("ObjectiveMatch")
    if matcher then
        local name = matcher:ParseLine(objective.text, objective.objectiveType)
        if type(name) == "string" and name ~= "" then
            return name
        end
    end
    if type(objective.text) ~= "string" then
        return nil
    end
    local stripped = string.gsub(objective.text, "%s*%d+%s*/%s*%d+%s*$", "")
    stripped = string.gsub(stripped, ":%s*$", "")
    stripped = UQ.Trim(stripped)
    if not stripped or stripped == "" then
        return nil
    end
    return stripped
end

function ObjectiveAnnounce:IsEnabled()
    local config = UQ:GetModule("Config")
    if not config then
        return false
    end
    return config:Get("announceObjectivesParty") and true or false
end

function ObjectiveAnnounce:IsCompletionOnly()
    local config = UQ:GetModule("Config")
    return config and config:Get("announceCompletedQuestsOnly") and true or false
end

-- Queue ---------------------------------------------------------------------

-- The quest travels with the line: the addon-channel fallback needs its tokens
-- so the receiving client can check the quest against its own log.
function ObjectiveAnnounce:Queue(quest, line, completion)
    if type(line) ~= "string" or line == "" then
        return
    end
    table.insert(self.queue, { quest = quest, text = line, completion = completion })
    while table.getn(self.queue) > QUEUE_LIMIT do
        table.remove(self.queue, 1)
        self.dropped = self.dropped + 1
    end
    self.announced = self.announced + 1
end

-- Drains at most one line per call, and only once the channel is known. Lines
-- queued for a group the player has since left are dropped: they belong to a
-- group that is no longer there to read them.
function ObjectiveAnnounce:Flush()
    if table.getn(self.queue) == 0 then
        return
    end
    -- `blocked` is not a reason to drop anything: it only means the visible
    -- chat line is off the table and delivery moves to the addon channel
    -- further down.
    if not self:IsEnabled() then
        self.queue = {}
        return
    end

    -- A queued partial step must not escape after the player selects completions.
    if self:IsCompletionOnly() then
        local index = table.getn(self.queue)
        while index >= 1 do
            if not self.queue[index].completion then
                table.remove(self.queue, index)
            end
            index = index - 1
        end
        if table.getn(self.queue) == 0 then
            return
        end
    end

    local channel = Client.GetGroupChatChannel()
    if not channel then
        self.queue = {}
        return
    end

    local now = Client.Now()
    if type(now) == "number" and now < self.nextSend then
        return
    end

    local entry = table.remove(self.queue, 1)
    local delivered = false

    if not self.blocked then
        if Client.SendChatMessage(entry.text, channel) then
            self.sent = self.sent + 1
            self.consecutiveRefusals = 0
            self.lastLine = entry.text
            delivered = true
        else
            self.refused = self.refused + 1
            self.consecutiveRefusals = self.consecutiveRefusals + 1
            if self.consecutiveRefusals >= REFUSAL_LIMIT then
                -- Said once, out loud, in the player's own chat frame. The
                -- player asked for a visible line and is not getting one;
                -- the fallback reaches only other UnrealQuest users holding
                -- the quest, so the reduced delivery needs to be stated.
                self.blocked = true
                UQ:Warn(UQ.L("ANNOUNCE_BLOCKED"))
            end
        end
    end

    -- Once visible sending is blocked, the addon fallback can reach peers
    -- running UnrealQuest and holding this quest.
    if not delivered and self.blocked then
        local sync = UQ:GetModule("QuestSync")
        if sync and sync:BroadcastProgress(entry.quest, entry.text) then
            self.relayed = self.relayed + 1
            self.lastLine = entry.text
        end
    end
    if type(now) == "number" then
        self.nextSend = now + SEND_INTERVAL
    end
end

-- Change detection ----------------------------------------------------------

-- Records the quest's current counters without announcing anything. Used for a
-- quest seen for the first time and for an objective whose identity changed.
local function Snapshot(quest)
    local state = {}
    local objectives = quest.objectives or {}
    local index = 1
    local total = table.getn(objectives)
    while index <= total do
        local objective = objectives[index]
        state[index] = {
            key = ObjectiveKey(objective.text),
            have = objective.have,
            need = objective.need,
            finished = objective.finished and true or false,
        }
        index = index + 1
    end
    return state
end

function ObjectiveAnnounce:Observe(quest)
    if not quest or not quest.titleKey then
        return
    end
    local previous = self.baseline[quest.titleKey]
    self.baseline[quest.titleKey] = Snapshot(quest)
    if not previous then
        return
    end
    if not self:IsEnabled() then
        return
    end

    local completionOnly = self:IsCompletionOnly()

    -- Completion reports need only a group. Requiring a known shared quest
    -- silently lost Okra 3/3 when neither source identified a sharing peer.
    -- Keep the shared-quest filter for the more frequent every-step mode.
    local canReport = Client.GetGroupChatChannel() ~= nil
    if canReport and not completionOnly then
        canReport = self:CountSharingPeers(quest) > 0
    end

    local objectives = quest.objectives or {}
    local index = 1
    local total = table.getn(objectives)
    while index <= total do
        local objective = objectives[index]
        local before = previous[index]
        local key = ObjectiveKey(objective.text)
        if before and key and before.key == key then
            local name = ObjectiveName(objective)
            if name then
                local line = nil
                local completion = false
                if type(objective.have) == "number" and type(objective.need) == "number"
                    and type(before.have) == "number" and objective.have > before.have then
                    completion = objective.have >= objective.need and before.have < objective.need
                    if not completionOnly or completion then
                        line = UQ.L("ANNOUNCE_OBJECTIVE_LINE", name,
                            tostring(objective.have), tostring(objective.need))
                    end
                elseif type(objective.have) ~= "number" and objective.finished
                    and not before.finished then
                    line = UQ.L("ANNOUNCE_OBJECTIVE_DONE", name)
                    completion = true
                end
                if line then
                    if canReport then
                        self:Queue(quest, line, completion)
                    elseif not completionOnly then
                        self.unshared = self.unshared + 1
                    end
                end
            end
        end
        index = index + 1
    end
end

-- How many group members are on this quest as well. Zero whenever the answer
-- is not knowable, because an unknown group member is not a sharing one.
--
-- Two sources, in this order:
--
--   1. The CLIENT's own answer. IsUnitOnQuest(index, unit) is documented here
--      as "whether a party member has the same quest as that quest log row",
--      which is precisely the question -- and it covers every party member,
--      whether or not they run this addon. Client.GetQuestLogPartyCount wraps
--      it; a party member who does not share the quest yields no value rather
--      than false, so a missing answer is already "no".
--   2. What other UnrealQuest clients have said about themselves, over
--      Quest/QuestSync.lua. This is the fallback for the two cases the first
--      source cannot reach: a client without IsUnitOnQuest at all, and a RAID,
--      where the documented call only answers for the player's own party.
function ObjectiveAnnounce:CountSharingPeers(quest)
    if not quest then
        return 0
    end
    local count = Client.GetQuestLogPartyCount(quest.index)
    if type(count) == "number" and count > 0 then
        return count
    end
    local sync = UQ:GetModule("QuestSync")
    if not sync then
        return 0
    end
    return sync:CountPeersWithQuest(quest)
end

-- One line from another player's UnrealQuest. `tokens` identifies the quest it
-- is about, in the shape Quest/QuestSync.lua issues; `text` has already been
-- stripped of client markup and cut to length there.
--
-- The sender only sent this because it believed somebody in the group shared
-- the quest. That belief is re-checked here against this client's own quest
-- set, which cannot be stale, so a peer whose record of us is out of date
-- cannot put a line about a quest we do not have in our chat frame.
function ObjectiveAnnounce:ReceivePeerProgress(sender, tokens, text)
    if type(sender) ~= "string" or sender == "" then
        return
    end
    if type(text) ~= "string" or text == "" then
        return
    end
    if not self:IsEnabled() then
        return
    end
    local sync = UQ:GetModule("QuestSync")
    if not sync then
        return
    end

    local held = false
    local start = 1
    local length = string.len(tokens or "")
    while start <= length and not held do
        local stop = string.find(tokens, ".", start, true)
        local token
        if stop then
            token = string.sub(tokens, start, stop - 1)
            start = stop + 1
        else
            token = string.sub(tokens, start)
            start = length + 1
        end
        if sync:HoldsToken(token) then
            held = true
        end
    end
    if not held then
        return
    end

    self.received = self.received + 1
    self.lastPeerLine = sender .. ": " .. text
    UQ:Print(UQ.L("ANNOUNCE_PEER_LINE", sender, text))
end

function ObjectiveAnnounce:Forget(quest)
    if quest and quest.titleKey then
        self.baseline[quest.titleKey] = nil
    end
end

-- Reporting -----------------------------------------------------------------

function ObjectiveAnnounce:GetStatus()
    local sync = UQ:GetModule("QuestSync")
    return {
        enabled = self:IsEnabled(),
        completionOnly = self:IsCompletionOnly(),
        available = Client.HasChatSend(),
        partyCheck = Client.HasFunction("IsUnitOnQuest"),
        channel = Client.GetGroupChatChannel(),
        blocked = self.blocked,
        announced = self.announced,
        sent = self.sent,
        relayed = self.relayed,
        refused = self.refused,
        dropped = self.dropped,
        unshared = self.unshared,
        received = self.received,
        queued = table.getn(self.queue),
        lastLine = self.lastLine,
        lastPeerLine = self.lastPeerLine,
        sync = sync and sync:GetStatus() or nil,
    }
end

-- Lifecycle -----------------------------------------------------------------

function ObjectiveAnnounce:OnEnable()
    local state = UQ:GetModule("QuestState")
    local driver = UQ:GetModule("Driver")

    if state then
        -- QuestState has already scanned by the time this runs, so the log the
        -- player logged in with is recorded here as the starting point and is
        -- never reported.
        local quests = state:GetOrderedQuests()
        local index = 1
        local total = table.getn(quests)
        while index <= total do
            local quest = quests[index]
            if quest.titleKey then
                self.baseline[quest.titleKey] = Snapshot(quest)
            end
            index = index + 1
        end

        state:AddListener(function(event, quest)
            if event == "QUEST_REMOVED" then
                ObjectiveAnnounce:Forget(quest)
            elseif event == "QUEST_ADDED" or event == "QUEST_OBJECTIVES_CHANGED" then
                ObjectiveAnnounce:Observe(quest)
            end
        end)
    end

    if driver then
        driver:Schedule("quest.announce", SEND_INTERVAL, function()
            ObjectiveAnnounce:Flush()
        end)
    end
end
