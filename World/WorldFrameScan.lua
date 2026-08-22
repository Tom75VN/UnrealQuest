--[[
UnrealQuest / World/WorldFrameScan.lua

A read-only inventory of WorldFrame's children, on demand. It changes nothing
and decides nothing.

WHY IT EXISTS
-------------
One open question blocks every per-creature feature in the 3D world: are this
client's floating nameplates Lua widgets, and if so which children of
WorldFrame are they?

It is open because it was answered wrongly once. A structural classifier of the
kind every Vanilla nameplate addon uses -- regions by type, a value-bearing
child, the texture's own path -- adopted five WorldFrame children here, and
every one of 1204 name reads off them came back as "Item Name". Those five are
not nameplates. The sibling unrealUI adopts five through the same kind of
signature and its overlay visibly works, which is either a different five or
the same wrong five with a coincidence on top. Nobody has looked.

Guessing again is the failure mode this file exists to prevent, so it dumps
what is actually there instead of classifying it:

  /uq worldscan          every WorldFrame child, one line each
  /uq worldscan <n>      one child in full: every region and every child

Run it with a named creature's nameplate visible on screen, then compare
against unrealUI's own /uui np dump taken in the same moment. If the two adopt
different children, the difference names the real plate outright.

The dump is persisted to UnrealQuestDB.worldFrameScan so it survives the
/reload that flushes it, and it is deliberately NOT collected automatically:
this walks every region and child of every WorldFrame child, which is real work
on a client already measured to be sensitive to per-tick allocation.

Texture paths are stored with their backslashes turned into forward slashes.
This client's SavedVariables writer mangles a stored backslash (Core/Config.lua),
and the paths here are evidence to read rather than paths to reuse.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local WorldFrameScan = UQ:NewModule("WorldFrameScan")

-- One line per child is the point; a busy WorldFrame stays inside the config
-- store's per-section cap with room to spare.
local MAX_LINES = 120
-- Long enough to recognize a texture, short enough that a chat line stays one
-- line.
local MAX_TEXT = 40

WorldFrameScan.lines = {}
WorldFrameScan.childCount = 0

local function Clip(text)
    if type(text) ~= "string" then
        return "?"
    end
    if string.len(text) > MAX_TEXT then
        return string.sub(text, 1, MAX_TEXT) .. ".."
    end
    return text
end

-- Never store or print a backslash: the saved-variables writer mangles it.
local function Slashes(path)
    if type(path) ~= "string" then
        return "?"
    end
    return string.gsub(path, "\\", "/")
end

-- Regions and children of one child, summarized. Returns the summary plus the
-- counts a classifier would key on, so the line shows both what the frame is
-- and what a signature would have made of it.
function WorldFrameScan:Describe(child)
    local fontTexts = {}
    local texturePaths = {}
    local fontCount, textureCount, otherRegions = 0, 0, 0

    local regions = Client.GetRegionList(child)
    if regions then
        local index = 1
        local total = table.getn(regions)
        while index <= total do
            local region = regions[index]
            local kind = Client.GetObjectType(region)
            if kind == "FontString" then
                fontCount = fontCount + 1
                local text = Client.GetObjectText(region)
                if text and table.getn(fontTexts) < 3 then
                    table.insert(fontTexts, "'" .. Clip(text) .. "'")
                end
            elseif kind == "Texture" then
                textureCount = textureCount + 1
                local path = Client.GetTexturePath(region)
                if path and table.getn(texturePaths) < 2 then
                    table.insert(texturePaths, Clip(Slashes(path)))
                end
            else
                otherRegions = otherRegions + 1
            end
            index = index + 1
        end
    end

    local kidNames = {}
    local kidCount, barCount = 0, 0
    local children = Client.GetChildList(child)
    if children then
        local index = 1
        local total = table.getn(children)
        while index <= total do
            local kid = children[index]
            kidCount = kidCount + 1
            local kind = Client.GetObjectType(kid) or "?"
            local isBar = Client.HasBarValue(kid)
            if isBar then
                barCount = barCount + 1
            end
            if table.getn(kidNames) < 3 then
                table.insert(kidNames, kind .. (isBar and "(v)" or ""))
            end
            index = index + 1
        end
    end

    return {
        fontTexts = fontTexts,
        texturePaths = texturePaths,
        kidNames = kidNames,
        fontCount = fontCount,
        textureCount = textureCount,
        otherRegions = otherRegions,
        kidCount = kidCount,
        barCount = barCount,
    }
end

local function Join(list, separator)
    local joined = ""
    local index = 1
    local total = table.getn(list)
    while index <= total do
        if index > 1 then
            joined = joined .. separator
        end
        joined = joined .. list[index]
        index = index + 1
    end
    return joined
end

function WorldFrameScan:Scan()
    self.lines = {}
    self.childCount = 0

    local worldFrame = Client.GetWorldFrame()
    if not worldFrame then
        return false, "WorldFrame is not reachable as an object"
    end
    local count = Client.GetChildCount(worldFrame)
    if not count then
        return false, "WorldFrame did not answer GetNumChildren"
    end
    self.childCount = count
    if count == 0 then
        return true
    end

    local children = Client.GetChildList(worldFrame)
    if not children then
        return false, "WorldFrame did not answer GetChildren"
    end

    local index = 1
    while index <= count and table.getn(self.lines) < MAX_LINES do
        local child = children[index]
        if child then
            local shape = self:Describe(child)
            local alpha = Client.GetObjectAlpha(child)
            local line = tostring(index)
                .. " " .. tostring(Client.GetObjectType(child) or "?")
                .. " " .. tostring(Client.GetObjectName(child) or "<unnamed>")
                .. " shown=" .. (Client.IsObjectShown(child) and "1" or "0")
                .. " a=" .. tostring(alpha or "?")
                .. " fs=" .. shape.fontCount
                .. " tex=" .. shape.textureCount
                .. " kids=" .. shape.kidCount
                .. " bars=" .. shape.barCount
            if table.getn(shape.fontTexts) > 0 then
                line = line .. " | " .. Join(shape.fontTexts, " ")
            end
            if table.getn(shape.texturePaths) > 0 then
                line = line .. " | " .. Join(shape.texturePaths, " ")
            end
            if table.getn(shape.kidNames) > 0 then
                line = line .. " | " .. Join(shape.kidNames, " ")
            end
            table.insert(self.lines, line)
        end
        index = index + 1
    end

    self:Record()
    return true
end

-- The whole point of persisting is that the answer survives the /reload that
-- writes SavedVariables to disk, so it can be read from the file rather than
-- from a screenshot of the chat frame.
function WorldFrameScan:Record()
    local config = UQ:GetModule("Config")
    if not config then
        return
    end
    config:ClearSection("worldFrameScan")
    config:SetSectionEntry("worldFrameScan", "children", self.childCount)
    local index = 1
    local total = table.getn(self.lines)
    while index <= total do
        config:SetSectionEntry("worldFrameScan", index, self.lines[index])
        index = index + 1
    end
end

-- One child in full, for when a line above looks like a candidate.
function WorldFrameScan:Detail(childIndex)
    local worldFrame = Client.GetWorldFrame()
    if not worldFrame then
        return nil
    end
    local children = Client.GetChildList(worldFrame)
    local child = children and children[childIndex]
    if not child then
        return nil
    end

    local detail = {}
    table.insert(detail, tostring(childIndex) .. " "
        .. tostring(Client.GetObjectType(child) or "?") .. " "
        .. tostring(Client.GetObjectName(child) or "<unnamed>"))

    local regions = Client.GetRegionList(child)
    if regions then
        local index = 1
        local total = table.getn(regions)
        while index <= total do
            local region = regions[index]
            local kind = Client.GetObjectType(region) or "?"
            local body = ""
            if kind == "FontString" then
                body = "'" .. Clip(Client.GetObjectText(region) or "") .. "'"
            elseif kind == "Texture" then
                body = Clip(Slashes(Client.GetTexturePath(region) or "<no texture>"))
            end
            table.insert(detail, "  region " .. index .. " " .. kind .. " " .. body)
            index = index + 1
        end
    else
        table.insert(detail, "  regions: GetRegions did not answer")
    end

    local children2 = Client.GetChildList(child)
    if children2 then
        local index = 1
        local total = table.getn(children2)
        while index <= total do
            local kid = children2[index]
            table.insert(detail, "  child " .. index .. " "
                .. tostring(Client.GetObjectType(kid) or "?")
                .. " " .. tostring(Client.GetObjectName(kid) or "<unnamed>")
                .. (Client.HasBarValue(kid) and " GetValue" or ""))
            index = index + 1
        end
    end

    return detail
end

function WorldFrameScan:OnEnable()
    if Client.GetWorldFrame() then
        UQ:DeclareCapability("worldFrameScan", "detected",
            "WorldFrame answers GetNumChildren/GetChildren, so its children can be inventoried. This is "
            .. "the reachability of the child list only -- it says NOTHING about whether any of those "
            .. "children is a nameplate, which is the open question /uq worldscan exists to answer and "
            .. "which a structural classifier already got wrong once (docs/CLIENT-COMPATIBILITY.md "
            .. "item 12). Nothing in this addon acts on a WorldFrame child")
    else
        UQ:DeclareCapability("worldFrameScan", "missing",
            "WorldFrame is not reachable as an object with GetNumChildren/GetChildren")
    end
end
