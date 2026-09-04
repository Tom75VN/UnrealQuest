--[[
UnrealQuest / Quest/QuestSync.lua

Who else in the group is on the same quest, and the hidden channel that answers
it. Used by Quest/ObjectiveAnnounce.lua, which must not say anything about a
quest nobody else in the group is doing.

WHY THIS EXISTS AT ALL
----------------------
For a PARTY, the client answers the question itself: `IsUnitOnQuest(index,
unit)` is documented here as "whether a party member has the same quest as that
quest log row", and `Client.GetQuestLogPartyCount` wraps it. That is the first
source `Quest/ObjectiveAnnounce.lua` asks, it covers every party member whether
or not they run this addon, and it is why this module is a FALLBACK rather than
the mechanism.

What it does not cover is what this module is for:

  * a RAID. The documented call yields no value for a player who is not in the
    caller's own party, so a raid outside the player's sub-group is beyond it;
  * a client where `IsUnitOnQuest` is not a callable global at all. It is
    `documented`, not probed (capability `questLogPartyPeers`);
  * delivery. When the client refuses the visible chat line -- which its own
    reference says it will -- the progress still has to reach somebody, and
    this is the only route left.

Outside those cases nothing here is load-bearing. Where it does answer, it
answers about players running UnrealQuest with the option on, because that is
all one addon can ever learn from another.

WHAT IS SENT
------------
`SendAddonMessage`, which the client's API reference explicitly exempts from
the protection on `SendChatMessage`: "SendChatMessage is protected: it errors
unless called from a secure (Blizzard UI) context. DoEmote and SendAddonMessage
are not." Its payload is hidden from chat entirely -- nothing here is visible
to a player who is not running the addon.

Three message kinds, all ASCII and all under the documented payload budget:

  H                      hello. "I am here, tell me what you are doing."
  S:<tok>,<tok>,...      my quest set, first chunk. Replaces what the receiver
  C:<tok>,<tok>,...      had recorded for me; C appends to it.
  P:<tok>.<tok>:<text>   one progress line -- "[UQ] Kobold Vermin: 4/8" -- for
                         the receiver to print if that quest is one of its own.
                         The tokens carry the quest identity, which is why the
                         text does not have to.

A quest contributes one or two TOKENS: `q<id>` when the title matched the
bundled database, and `t<hash>` of the normalized title. Both are sent where
both exist and any one shared token counts as a shared quest -- the ID survives
two clients running different interface languages, and the title hash survives
a quest the matcher could not resolve on one side. A hash is a 24-bit digest,
so a collision is possible in principle; the cost of one is a line about a
quest a group member does not have, which is why nothing but this report is
allowed to depend on it.

RECEIVING IS THE UNVERIFIED HALF
--------------------------------
This client documents no event names at all and the compatibility database has
no `CHAT_MSG_ADDON` record, so whether a peer's message ever arrives is settled
only by two UnrealQuest clients in one group. Registration is guarded like
every other event here, and the failure mode is the quiet one: a client that
never hears a peer knows of no peer, counts nobody as sharing a quest, and
therefore says nothing. `/uq announce` reports peers seen and messages received
so the answer is readable rather than guessed at.

EVERYTHING RECEIVED IS UNTRUSTED
--------------------------------
A peer's payload is another player's text. Progress text is stripped of the
escape character the client's own markup uses, cut to a fixed length, and
printed under the sender's name -- so a peer can put a line in the player's
chat frame, which is the whole point, but cannot forge a hyperlink, recolour
the frame, or send a wall of text through it. Token lists and peer counts are
bounded for the same reason.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local QuestSync = UQ:NewModule("QuestSync")

-- The addon prefix. Short because the client joins it to the payload with a
-- tab and the pair shares one message budget.
local PREFIX = "UQuest"

-- Payload characters per message, comfortably inside the documented limit.
local PAYLOAD_LIMIT = 200

-- Seconds between two outgoing messages. The group channel is rate limited
-- server-side and a chunked quest set is several messages in a row.
local SEND_INTERVAL = 0.4
local QUEUE_LIMIT = 12

-- The roster and heartbeat pass.
local TICK_INTERVAL = 2.0

-- Re-send the quest set this often even when nothing changed, so a peer who
-- missed a broadcast (loading screen, zoning) is never stuck with a stale set.
local HEARTBEAT_SECONDS = 60

-- ...but never more often than this, whatever changes.
local ADVERTISE_FLOOR_SECONDS = 5

-- A peer that has said nothing for this long is forgotten even if the roster
-- still lists them: it means their addon stopped talking, and a stale set must
-- not keep authorising lines about quests they may have finished.
local PEER_EXPIRY_SECONDS = 300

-- Bounds on anything a peer can grow in this client's memory.
local MAX_PEERS = 40
local MAX_TOKENS_PER_PEER = 80
local MAX_TEXT_LENGTH = 160

QuestSync.peers = {}
QuestSync.peerOrder = {}
QuestSync.queue = {}
QuestSync.tokens = {}
QuestSync.signature = nil
QuestSync.dirty = true
QuestSync.nextSend = 0
QuestSync.nextAdvertise = 0
QuestSync.lastAdvertise = 0
QuestSync.stats = { sent = 0, received = 0, refused = 0, dropped = 0, ignored = 0 }
QuestSync.eventAccepted = false

-- Identity ------------------------------------------------------------------

-- A 24-bit digest of a normalized quest title. djb2 over bytes, kept inside
-- the range a double holds exactly and reduced by hand: math.mod is not part
-- of the Lua subset this addon stays inside.
local HASH_RANGE = 16777216

local function Fingerprint(text)
    local key = UQ.NameKey(text)
    if not key then
        return nil
    end
    local hash = 5381
    local index = 1
    local length = string.len(key)
    while index <= length do
        hash = hash * 33 + string.byte(key, index)
        hash = hash - math.floor(hash / HASH_RANGE) * HASH_RANGE
        index = index + 1
    end
    return string.format("t%x", hash)
end

-- The tokens that identify one quest to a peer. Both are sent when both are
-- known: see the header for why neither alone is enough.
function QuestSync:QuestTokens(quest)
    local tokens = {}
    if not quest then
        return tokens
    end
    if type(quest.questId) == "number" then
        table.insert(tokens, "q" .. quest.questId)
    end
    local hash = Fingerprint(quest.title)
    if hash then
        table.insert(tokens, hash)
    end
    return tokens
end

-- Peers ---------------------------------------------------------------------

local function PeerRecord(name)
    local peer = QuestSync.peers[name]
    if peer then
        return peer
    end
    if table.getn(QuestSync.peerOrder) >= MAX_PEERS then
        return nil
    end
    peer = { name = name, tokens = {}, count = 0, lastSeen = 0 }
    QuestSync.peers[name] = peer
    table.insert(QuestSync.peerOrder, name)
    return peer
end

local function ForgetPeer(name)
    if not QuestSync.peers[name] then
        return
    end
    QuestSync.peers[name] = nil
    local index = 1
    local total = table.getn(QuestSync.peerOrder)
    while index <= total do
        if QuestSync.peerOrder[index] == name then
            table.remove(QuestSync.peerOrder, index)
            return
        end
        index = index + 1
    end
end

function QuestSync:ForgetAllPeers()
    self.peers = {}
    self.peerOrder = {}
end

-- How many group members are known to be on this quest. Zero is the answer
-- whenever nothing is known, which is the honest answer: an unknown group
-- member is not a sharing one.
function QuestSync:CountPeersWithQuest(quest)
    local tokens = self:QuestTokens(quest)
    local tokenCount = table.getn(tokens)
    if tokenCount == 0 then
        return 0
    end
    local sharing = 0
    local index = 1
    local total = table.getn(self.peerOrder)
    while index <= total do
        local peer = self.peers[self.peerOrder[index]]
        if peer then
            local tokenIndex = 1
            while tokenIndex <= tokenCount do
                if peer.tokens[tokens[tokenIndex]] then
                    sharing = sharing + 1
                    tokenIndex = tokenCount + 1
                else
                    tokenIndex = tokenIndex + 1
                end
            end
        end
        index = index + 1
    end
    return sharing
end

-- Whether one of the player's OWN quests carries this token. Used on the
-- receiving side, so a line is printed only under the quest the reader is also
-- doing -- the same rule the sender applied, checked again against a set that
-- cannot be stale.
function QuestSync:HoldsToken(token)
    if type(token) ~= "string" or token == "" then
        return false
    end
    return self.tokens[token] and true or false
end

-- Own quest set -------------------------------------------------------------

function QuestSync:RebuildTokens()
    local state = UQ:GetModule("QuestState")
    local tokens = {}
    local ordered = {}
    if state then
        local quests = state:GetOrderedQuests()
        local index = 1
        local total = table.getn(quests)
        while index <= total do
            local questTokens = self:QuestTokens(quests[index])
            local tokenIndex = 1
            local tokenTotal = table.getn(questTokens)
            while tokenIndex <= tokenTotal do
                local token = questTokens[tokenIndex]
                if not tokens[token] then
                    tokens[token] = true
                    table.insert(ordered, token)
                end
                tokenIndex = tokenIndex + 1
            end
            index = index + 1
        end
    end
    self.tokens = tokens
    self.ordered = ordered
    self.dirty = false
    return table.concat(ordered, ",")
end

-- Transport -----------------------------------------------------------------

function QuestSync:IsAvailable()
    return Client.HasAddonMessages()
end

function QuestSync:IsEnabled()
    local config = UQ:GetModule("Config")
    if not config then
        return false
    end
    return config:Get("announceObjectivesParty") and true or false
end

function QuestSync:Send(payload)
    if type(payload) ~= "string" or payload == "" then
        return
    end
    table.insert(self.queue, payload)
    while table.getn(self.queue) > QUEUE_LIMIT do
        table.remove(self.queue, 1)
        self.stats.dropped = self.stats.dropped + 1
    end
end

function QuestSync:Flush()
    if table.getn(self.queue) == 0 then
        return
    end
    if not self:IsEnabled() or not self:IsAvailable() then
        self.queue = {}
        return
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
    local payload = table.remove(self.queue, 1)
    if Client.SendAddonMessage(PREFIX, payload, channel) then
        self.stats.sent = self.stats.sent + 1
    else
        self.stats.refused = self.stats.refused + 1
    end
    if type(now) == "number" then
        self.nextSend = now + SEND_INTERVAL
    end
end

-- Breaks the token list into messages that fit the payload budget. The first
-- carries "S" and replaces whatever the receiver had recorded; the rest carry
-- "C" and add to it.
function QuestSync:Advertise()
    if not self:IsEnabled() or not self:IsAvailable() then
        return
    end
    if not Client.GetGroupChatChannel() then
        return
    end
    local now = Client.Now() or 0
    self.lastAdvertise = now
    self.nextAdvertise = now + HEARTBEAT_SECONDS

    local ordered = self.ordered or {}
    local total = table.getn(ordered)
    local index = 1
    local chunk = {}
    local length = 0
    local first = true
    while index <= total do
        local token = ordered[index]
        local cost = string.len(token) + 1
        if length + cost > PAYLOAD_LIMIT - 2 and table.getn(chunk) > 0 then
            self:Send((first and "S:" or "C:") .. table.concat(chunk, ","))
            first = false
            chunk = {}
            length = 0
        end
        table.insert(chunk, token)
        length = length + cost
        index = index + 1
    end
    -- Always sent, even empty: "I am running this and I have no quests" is a
    -- fact a peer needs, and it is also what clears a set it still holds.
    self:Send((first and "S:" or "C:") .. table.concat(chunk, ","))
end

function QuestSync:SayHello()
    if not self:IsEnabled() or not self:IsAvailable() then
        return
    end
    if not Client.GetGroupChatChannel() then
        return
    end
    self:Send("H")
end

-- Sends one progress line for the group's other UnrealQuest clients to print.
-- Only called when a peer is already known to share the quest.
function QuestSync:BroadcastProgress(quest, text)
    if not self:IsEnabled() or not self:IsAvailable() then
        return false
    end
    local tokens = self:QuestTokens(quest)
    if table.getn(tokens) == 0 then
        return false
    end
    self:Send("P:" .. table.concat(tokens, ".") .. ":" .. text)
    return true
end

-- Receiving -----------------------------------------------------------------

-- A peer's own words, reduced to something that can only be text. "|" is the
-- client's markup escape, so removing it removes hyperlinks, colour codes and
-- textures in one step.
local function SanitizeText(text)
    if type(text) ~= "string" then
        return nil
    end
    local clean = string.gsub(text, "|", "")
    clean = string.gsub(clean, "[%c]", " ")
    if string.len(clean) > MAX_TEXT_LENGTH then
        clean = string.sub(clean, 1, MAX_TEXT_LENGTH)
    end
    clean = UQ.Trim(clean)
    if not clean or clean == "" then
        return nil
    end
    return clean
end

local function StoreTokens(peer, list, replace)
    if replace then
        peer.tokens = {}
        peer.count = 0
    end
    local start = 1
    local length = string.len(list)
    while start <= length do
        local stop = string.find(list, ",", start, true)
        local token
        if stop then
            token = string.sub(list, start, stop - 1)
            start = stop + 1
        else
            token = string.sub(list, start)
            start = length + 1
        end
        -- Only the two token shapes this addon issues are stored, so a peer
        -- cannot fill this table with arbitrary strings.
        if string.find(token, "^[qt][0-9a-f]+$") and peer.count < MAX_TOKENS_PER_PEER then
            if not peer.tokens[token] then
                peer.tokens[token] = true
                peer.count = peer.count + 1
            end
        end
    end
end

function QuestSync:OnMessage(prefix, payload, channel, sender)
    if prefix ~= PREFIX or type(payload) ~= "string" then
        return
    end
    if type(sender) ~= "string" or sender == "" then
        return
    end
    if sender == self.playerName then
        -- This client's own message, echoed back by the channel.
        return
    end
    if not self:IsEnabled() then
        -- Opting out is symmetric: a player who is not reporting their own
        -- progress is not collecting anyone else's either.
        self.stats.ignored = self.stats.ignored + 1
        return
    end
    if not self.roster or not self.roster[sender] then
        -- Only the current group is listened to, whatever channel carried it.
        -- A member who joined between two roster passes would otherwise have
        -- their introduction thrown away, so an unknown sender is worth one
        -- fresh look at the roster -- rate limited, since anyone at all can
        -- put a name in front of this.
        local now = Client.Now() or 0
        if now - (self.rosterCheckedAt or 0) >= 1 then
            self:PollRoster()
        end
        if not self.roster or not self.roster[sender] then
            self.stats.ignored = self.stats.ignored + 1
            return
        end
    end

    self.stats.received = self.stats.received + 1
    local peer = PeerRecord(sender)
    if not peer then
        return
    end
    peer.lastSeen = Client.Now() or 0

    if payload == "H" then
        -- Someone arrived and wants the picture. Answered on the next pass
        -- rather than here: five addon users joining one party would otherwise
        -- each answer five hellos on the spot. Clearing the schedule makes the
        -- tick send it as soon as the floor between two broadcasts allows.
        self.nextAdvertise = 0
        return
    end

    local _, _, kind, body = string.find(payload, "^(%a):(.*)$")
    if not kind then
        return
    end

    if kind == "S" or kind == "C" then
        StoreTokens(peer, body, kind == "S")
        return
    end

    if kind == "P" then
        local _, _, tokens, text = string.find(body, "^([^:]*):(.*)$")
        if not tokens then
            return
        end
        local announce = UQ:GetModule("ObjectiveAnnounce")
        if announce then
            announce:ReceivePeerProgress(sender, tokens, SanitizeText(text))
        end
        return
    end
end

-- Roster --------------------------------------------------------------------

function QuestSync:PollRoster()
    self.rosterCheckedAt = Client.Now() or 0
    local roster = Client.GetGroupMemberNames()
    local previous = self.roster or {}
    self.roster = roster

    local joined = false
    for name in pairs(roster) do
        if not previous[name] then
            joined = true
        end
    end

    local index = table.getn(self.peerOrder)
    local now = Client.Now() or 0
    while index >= 1 do
        local name = self.peerOrder[index]
        local peer = self.peers[name]
        if not roster[name] or not peer
            or (peer.lastSeen > 0 and now - peer.lastSeen > PEER_EXPIRY_SECONDS) then
            ForgetPeer(name)
        end
        index = index - 1
    end

    if not self:IsEnabled() then
        return
    end

    -- A new face means both halves of the introduction: ask what they have,
    -- and say what we have, since their hello may never reach us.
    if joined then
        self:SayHello()
        self.nextAdvertise = 0
    end
end

function QuestSync:Tick()
    self:PollRoster()

    if not self:IsEnabled() or not self:IsAvailable() then
        return
    end
    if not Client.GetGroupChatChannel() then
        return
    end

    local now = Client.Now() or 0
    local signature = nil
    if self.dirty then
        signature = self:RebuildTokens()
    end

    local changed = signature ~= nil and signature ~= self.signature
    if changed then
        self.signature = signature
    end

    if now < self.lastAdvertise + ADVERTISE_FLOOR_SECONDS then
        return
    end
    if changed or now >= self.nextAdvertise then
        self:Advertise()
    end
end

-- Reporting -----------------------------------------------------------------

function QuestSync:GetStatus()
    local peers = {}
    local index = 1
    local total = table.getn(self.peerOrder)
    while index <= total do
        local peer = self.peers[self.peerOrder[index]]
        if peer then
            table.insert(peers, { name = peer.name, quests = peer.count })
        end
        index = index + 1
    end
    return {
        available = self:IsAvailable(),
        eventAccepted = self.eventAccepted,
        channel = Client.GetGroupChatChannel(),
        peers = peers,
        peerCount = table.getn(peers),
        sent = self.stats.sent,
        received = self.stats.received,
        refused = self.stats.refused,
        ignored = self.stats.ignored,
    }
end

-- Lifecycle -----------------------------------------------------------------

function QuestSync:OnEnable()
    local state = UQ:GetModule("QuestState")
    local driver = UQ:GetModule("Driver")
    local events = UQ:GetModule("Events")

    self.playerName = Client.GetUnitName("player")
    self.roster = Client.GetGroupMemberNames()
    self:RebuildTokens()

    if state then
        state:AddListener(function(event)
            if event == "QUEST_ADDED" or event == "QUEST_REMOVED"
                or event == "QUEST_LOG_CHANGED" then
                QuestSync.dirty = true
            end
        end)
    end

    if events then
        self.eventAccepted = events:Register("CHAT_MSG_ADDON",
            function(_, prefix, payload, channel, sender)
                QuestSync:OnMessage(prefix, payload, channel, sender)
            end) and true or false

        -- Accelerators only: the roster is polled either way.
        local wake = function()
            local d = UQ:GetModule("Driver")
            if d then
                d:Wake("questsync.tick")
            end
        end
        events:Register("PARTY_MEMBERS_CHANGED", wake)
        events:Register("RAID_ROSTER_UPDATE", wake)
    end

    if driver then
        driver:Schedule("questsync.tick", TICK_INTERVAL, function() QuestSync:Tick() end)
        driver:Schedule("questsync.send", SEND_INTERVAL, function() QuestSync:Flush() end)
    end
end
