--[[
UnrealQuest / Quest/BagItems.lua

The set of item IDs the player is currently carrying.

This exists for one consumer and one question. Some quest objectives are not
"kill this" or "loot that" but "use this item on that object", and the target
of such a step is only worth putting on the map while the item is actually in
the bag -- see Data/Database.lua, GetQuestItemUseTargets. Answering that needs
live player state, which neither the bundled data nor the quest log carries.

Three constraints shape the module:

  * The container API is documented but behaviour-untested on this client
    (bags.container_api_contract_unverified), so every read goes through
    Compatibility/ClientAPI.lua and a nil comes back as *unknown*. Carries()
    returns nil in that case, never false, and the map layer draws nothing for
    an unknown -- the addon does not guess a bag it could not read.
  * Events are accelerators, never the mechanism. BAG_UPDATE does fire here
    (109 observations in the live SavedVariables) and merely wakes the job
    early; the poll alone is the correctness guarantee.
  * A tick allocates as little as possible. Scanning five bags at once is up to
    a hundred guarded calls in one frame, which is exactly the per-tick burst
    this client has been reported to stutter on, so the scan is round-robined
    one bag per tick and only published as a set when a full cycle completes.
    A partially scanned bag list must never be visible: it would read as "the
    player dropped the item" for the rest of the cycle.

The published set carries a token that changes only when membership changes.
The map layer folds that token into its view signature, so looting or using a
quest item repaints the map, and an unrelated bag shuffle does not.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local BagItems = UQ:NewModule("BagItems")

-- Bags scanned per tick. One is deliberate: see the burst note above. At the
-- default 0.5s poll that is a 2.5s worst case between looting a quest item and
-- its use target appearing on the map, which is well inside the time it takes
-- to walk anywhere and is worth trading for a flat per-tick cost.
local BAG_BUDGET = 1

-- Guard against a client that reports an implausible slot count rather than
-- nil. The largest Vanilla bag is 20 slots; this is a fault bound, not a limit
-- the addon expects to reach.
local MAX_SLOTS_PER_BAG = 40

BagItems.carried = {}
BagItems.available = nil
BagItems.token = 0
BagItems.cycles = 0
BagItems.lastCycleAt = nil

local staging = nil
local cursor = nil
local stagingReadable = false

local function SetsDiffer(left, right)
    local key
    for key in pairs(left) do
        if not right[key] then
            return true
        end
    end
    for key in pairs(right) do
        if not left[key] then
            return true
        end
    end
    return false
end

-- Reads one bag into the staging set. Returns true when the bag was readable,
-- which includes an existing bag that is empty; false only when the client
-- gave back nothing at all for a slot count.
local function ScanBag(bag)
    local slots = Client.GetBagSlotCount(bag)
    if not slots then
        return false
    end
    if slots > MAX_SLOTS_PER_BAG then
        slots = MAX_SLOTS_PER_BAG
    end
    local slot = 1
    while slot <= slots do
        local itemId = Client.GetBagItemId(bag, slot)
        if itemId then
            staging[itemId] = true
        end
        slot = slot + 1
    end
    return true
end

-- One tick of the round-robin. A cycle spans Client.FIRST_BAG..LAST_BAG and
-- only publishes at the end, so `carried` is always a whole observation.
function BagItems:ScanSlice()
    if not Client.HasBagScan() then
        self.available = false
        return
    end

    if not staging or cursor == nil then
        staging = {}
        cursor = Client.FIRST_BAG
        stagingReadable = false
    end

    local scanned = 0
    while scanned < BAG_BUDGET and cursor <= Client.LAST_BAG do
        local readable = ScanBag(cursor)
        -- The backpack (bag 0) always exists. The other four are bag slots
        -- that may simply be empty, so an unreadable one is ordinary; only
        -- bag 0 coming back with nothing means the container API itself
        -- produced nothing usable.
        if cursor == Client.FIRST_BAG then
            stagingReadable = readable
        end
        cursor = cursor + 1
        scanned = scanned + 1
    end

    if cursor <= Client.LAST_BAG then
        return
    end

    if stagingReadable then
        if SetsDiffer(self.carried, staging) then
            self.token = self.token + 1
        end
        self.carried = staging
        self.available = true
    else
        -- Bag 0 unreadable means the wrapper resolved but the call produced
        -- nothing usable. Report unknown rather than publishing an empty set,
        -- which would be indistinguishable from genuinely empty bags.
        self.available = false
    end

    self.cycles = self.cycles + 1
    self.lastCycleAt = Client.Now()
    staging = nil
    cursor = nil
    stagingReadable = false
end

-- Restarts the cycle so the next tick reads bag 0 again. Used by the
-- BAG_UPDATE accelerator: a bag that changed halfway through a cycle would
-- otherwise publish a mix of two observations.
function BagItems:Invalidate()
    staging = nil
    cursor = nil
    stagingReadable = false
end

-- true, false, or nil for "the bags could not be read". Callers must handle
-- all three; nil is not false.
function BagItems:Carries(itemId)
    if type(itemId) ~= "number" then
        return nil
    end
    if not self.available then
        return nil
    end
    return self.carried[itemId] and true or false
end

-- Changes only when the carried set's membership changes, so it is safe to
-- fold into a cache key. Includes availability so the first successful scan
-- after a failed one also invalidates.
function BagItems:GetToken()
    return tostring(self.token) .. ":" .. tostring(self.available)
end

function BagItems:GetStatus()
    local count = 0
    local _
    for _ in pairs(self.carried) do
        count = count + 1
    end
    return {
        available = self.available,
        distinctItems = count,
        cycles = self.cycles,
        token = self.token,
    }
end

function BagItems:OnEnable()
    if not Client.HasBagScan() then
        self.available = false
        return
    end

    local driver = UQ:GetModule("Driver")
    local config = UQ:GetModule("Config")

    local interval = 0.5
    if config then
        local configured = config:Get("pollInterval")
        if type(configured) == "number" and configured > 0 then
            interval = configured
        end
    end

    if driver then
        driver:Schedule("bag.scan", interval, function() BagItems:ScanSlice() end)
    end

    local events = UQ:GetModule("Events")
    if events then
        events:Register("BAG_UPDATE", function()
            BagItems:Invalidate()
            local d = UQ:GetModule("Driver")
            if d then
                d:Wake("bag.scan")
            end
        end)
    end
end
