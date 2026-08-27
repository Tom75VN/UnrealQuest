--[[
UnrealQuest / UnrealQuest.lua

Bootstrap. Loads last.

Startup is held to the same rule as everything else in this addon: no client
event is assumed to exist. The candidate load events are registered, but a
timer running off GetTime brings the addon up regardless, so UnrealQuest
initializes correctly on a client where none of them fires.

Two phases:
  Init    saved variables are read and every module's OnInit runs. Safe to do
          as soon as the addon files have loaded.
  Enable  every module's OnEnable runs. Held until the player is in the world,
          because the quest log is not populated before that.
]]

local UQ = UnrealQuest

local INIT_FALLBACK = 2.0
local ENABLE_FALLBACK = 6.0

local frameOk, bootstrap = pcall(CreateFrame, "Frame", "UnrealQuestBootstrap", UIParent)
if not frameOk then
    bootstrap = nil
end

local started = nil
local initialized = false
local enabled = false

local function RunInit()
    if initialized then
        return
    end
    initialized = true

    -- Config first: everything else may read settings during its own OnInit.
    -- Locale immediately after it and before every other module, because a
    -- label is translated once when it is built and never re-read -- so the
    -- language has to be settled before anything can build one. Locale cannot
    -- go first: it reads the stored language through Config.
    --
    -- Both are named here rather than left to registration order. Which of the
    -- two runs first is a correctness property, not a TOC detail.
    local ordered = { "Config", "Locale" }
    local orderedIndex = 1
    local orderedTotal = table.getn(ordered)
    while orderedIndex <= orderedTotal do
        local module = UQ:GetModule(ordered[orderedIndex])
        if module and module.OnInit then
            local ok, err = pcall(module.OnInit, module)
            if not ok then
                UQ:Warn(UQ.L("BOOT_MODULE_INIT_FAILED", module.name, tostring(err)))
            end
        end
        orderedIndex = orderedIndex + 1
    end

    UQ:ForEachModule(function(module)
        if module.name ~= "Config" and module.name ~= "Locale" and module.OnInit then
            local ok, err = pcall(module.OnInit, module)
            if not ok then
                UQ:Warn(UQ.L("BOOT_MODULE_INIT_FAILED", module.name, tostring(err)))
            end
        end
    end)

    UQ:Debug("initialized")
end

local function RunEnable()
    if enabled then
        return
    end
    if not initialized then
        RunInit()
    end
    enabled = true

    UQ:ForEachModule(function(module)
        if module.OnEnable then
            local ok, err = pcall(module.OnEnable, module)
            if not ok then
                UQ:Warn(UQ.L("BOOT_MODULE_ENABLE_FAILED", module.name, tostring(err)))
            else
                module.enabled = true
            end
        end
    end)

    UQ:Print(UQ.L("BOOT_LOADED", UQ.version))
end

local function OnBootstrapUpdate()
    if enabled then
        -- SetScript(type, nil) does not detach a script on this client, so the
        -- handler stays installed and gates itself here instead.
        return
    end

    local now = UQ.Client.Now()
    if not now then
        -- Without GetTime there is no safe timer. Come up immediately rather
        -- than never.
        RunEnable()
        return
    end

    if not started then
        started = now
        return
    end

    local elapsed = now - started
    if elapsed < 0 then
        started = now
        return
    end

    if not initialized and elapsed >= INIT_FALLBACK then
        RunInit()
    end
    if elapsed >= ENABLE_FALLBACK then
        RunEnable()
    end
end

local function OnBootstrapEvent(first, second)
    local event = UQ.Client.ResolveEventName(first, second)
    if not event then
        return
    end
    if event == "VARIABLES_LOADED" then
        RunInit()
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        RunEnable()
    end
end

if bootstrap then
    bootstrap:SetScript("OnEvent", OnBootstrapEvent)
    bootstrap:SetScript("OnUpdate", OnBootstrapUpdate)
    UQ.Client.RegisterEvent(bootstrap, "VARIABLES_LOADED")
    UQ.Client.RegisterEvent(bootstrap, "PLAYER_LOGIN")
    UQ.Client.RegisterEvent(bootstrap, "PLAYER_ENTERING_WORLD")
    UQ.bootstrap = bootstrap
else
    -- No frame means no timer and no events. Bring the addon up synchronously
    -- so it is at least inspectable.
    RunEnable()
end

UQ.RunInit = RunInit
UQ.RunEnable = RunEnable
